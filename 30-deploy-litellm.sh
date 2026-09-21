#!/usr/bin/env bash
# Renders the manifests with real values from terraform, runs the schema
# migration Job, then rolls out the proxy and the ALB ingress.
source "$(dirname "$0")/lib.sh"

need kubectl

REGION="$(tf_out region)"
DATABASE_URL="$(tf_out database_url)"
MASTER_KEY="$(tf_out litellm_master_key)"
SALT_KEY="$(tf_out litellm_salt_key)"
VALKEY_HOST="$(tf_out valkey_endpoint)"
IRSA_ROLE_ARN="$(tf_out litellm_irsa_role_arn)"
ACM_ARN="$(terraform -chdir="$TF_DIR" output -raw acm_certificate_arn 2>/dev/null || true)"
INBOUND_CIDRS="$(tf_out_json ingress_allowed_cidrs | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)))')"

# Provider keys are read from your shell (or a .env file) and land only in the
# Kubernetes Secret. The database stores os.environ/ references, never the key.
[[ -f "$ROOT_DIR/.env" ]] && source "$ROOT_DIR/.env"
GEMINI_API_KEY="${GEMINI_API_KEY:-}"
HUGGINGFACE_API_KEY="${HUGGINGFACE_API_KEY:-}"

# A model row seeded while its key is empty is stored with no key at all and
# every call through it fails on the provider's auth check. Fail loudly here
# instead of leaving that to be discovered at smoke-test time.
for v in GEMINI_API_KEY HUGGINGFACE_API_KEY; do
  [[ -n "${!v}" ]] || warn "$v is empty. Set it in $ROOT_DIR/.env before running 40-seed-providers.sh."
done

if [[ -n "$ACM_ARN" ]]; then
  ALB_LISTEN_PORTS='[{"HTTP": 80}, {"HTTPS": 443}]'
else
  ALB_LISTEN_PORTS='[{"HTTP": 80}]'
fi

rm -rf "$RENDER_DIR" && mkdir -p "$RENDER_DIR"

log "Rendering manifests into k8s/rendered/"
export LITELLM_IMAGE AWS_REGION="$REGION" LITELLM_IRSA_ROLE_ARN="$IRSA_ROLE_ARN" \
       ALB_LISTEN_PORTS ALB_INBOUND_CIDRS="$INBOUND_CIDRS" ACM_CERTIFICATE_ARN="$ACM_ARN"

for f in "$K8S_DIR"/*.yaml; do
  base="$(basename "$f")"
  [[ "$base" == "02-secret.example.yaml" ]] && continue
  python3 - "$f" > "$RENDER_DIR/$base" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
sys.stdout.write(re.sub(r'\$\{(\w+)\}', lambda m: os.environ.get(m.group(1), ''), src))
PY
done

# Drop the TLS annotations when no certificate was supplied, otherwise the
# controller rejects an ingress that claims HTTPS without a cert.
if [[ -z "$ACM_ARN" ]]; then
  grep -v -e 'certificate-arn' -e 'ssl-redirect' "$RENDER_DIR/07-ingress.yaml" > "$RENDER_DIR/07-ingress.tmp"
  mv "$RENDER_DIR/07-ingress.tmp" "$RENDER_DIR/07-ingress.yaml"
fi

log "Writing the Secret (never rendered to disk in plaintext)"
kubectl apply -f "$RENDER_DIR/00-namespace.yaml"
kubectl -n litellm create secret generic litellm-secrets \
  --from-literal=DATABASE_URL="$DATABASE_URL" \
  --from-literal=LITELLM_MASTER_KEY="$MASTER_KEY" \
  --from-literal=LITELLM_SALT_KEY="$SALT_KEY" \
  --from-literal=REDIS_HOST="$VALKEY_HOST" \
  --from-literal=REDIS_PORT="6379" \
  --from-literal=UI_USERNAME="admin" \
  --from-literal=UI_PASSWORD="$MASTER_KEY" \
  --from-literal=GEMINI_API_KEY="$GEMINI_API_KEY" \
  --from-literal=HUGGINGFACE_API_KEY="$HUGGINGFACE_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Applying service account and config"
kubectl apply -f "$RENDER_DIR/01-serviceaccount.yaml" -f "$RENDER_DIR/03-configmap.yaml"

log "Running schema migrations"
kubectl -n litellm delete job litellm-migrations --ignore-not-found
kubectl apply -f "$RENDER_DIR/04-migrations-job.yaml"
kubectl -n litellm wait --for=condition=complete job/litellm-migrations --timeout=10m \
  || { kubectl -n litellm logs job/litellm-migrations --tail=100; die "migrations failed"; }

log "Rolling out the proxy"
kubectl apply -f "$RENDER_DIR/05-deployment.yaml" \
              -f "$RENDER_DIR/06-service.yaml" \
              -f "$RENDER_DIR/07-ingress.yaml" \
              -f "$RENDER_DIR/08-hpa.yaml" \
              -f "$RENDER_DIR/09-pdb.yaml"
kubectl -n litellm rollout status deploy/litellm --timeout=10m

log "Waiting for the ALB to be provisioned (takes 2-4 minutes)"
for _ in $(seq 1 60); do
  HOST="$(kubectl -n litellm get ingress litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$HOST" ]] && break
  sleep 10
done
[[ -n "${HOST:-}" ]] || die "ALB hostname never appeared. Check: kubectl -n kube-system logs deploy/aws-load-balancer-controller"

SCHEME="http"; [[ -n "$ACM_ARN" ]] && SCHEME="https"
cat <<INFO

LiteLLM is deployed.

  Proxy base URL : $SCHEME://$HOST
  Admin UI       : $SCHEME://$HOST/ui
  UI login       : admin / (the master key)
  Master key     : terraform -chdir=terraform output -raw litellm_master_key

The ALB target group can take another minute to report healthy.
Next: scripts/40-seed-providers.sh to load the provider list into Postgres.
INFO
