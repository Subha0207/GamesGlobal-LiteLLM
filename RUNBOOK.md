# Runbook

## 0. Prep

```bash
aws sts get-caller-identity

curl -s https://checkip.amazonaws.com
# put that IP as a /32 in ingress_allowed_cidrs in terraform/terraform.tfvars

cat > .env <<'ENV'
GEMINI_API_KEY=AIza...
HUGGINGFACE_API_KEY=hf_...
ENV
```

## 1. Deploy

```bash
./scripts/00-prereqs.sh
./scripts/10-deploy-infra.sh        # 20-25 min
./scripts/20-bootstrap-cluster.sh
./scripts/30-deploy-litellm.sh      # 5-10 min
```

```bash
kubectl -n litellm exec deploy/litellm -- printenv GEMINI_API_KEY
# must print the key before seeding
```

## 2. Seed

```bash
./scripts/40-seed-providers.sh --prune
sleep 35
```

```bash
BASE=http://$(kubectl -n litellm get ingress litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
MK=$(terraform -chdir=terraform output -raw litellm_master_key)

curl -sS -H "Authorization: Bearer $MK" "$BASE/model/info" \
  | python3 -c 'import json,sys; [print(m["model_name"], "api_key" in m.get("litellm_params",{})) for m in json.load(sys.stdin)["data"]]'
# every row must print True
```

## 3. Verify

```bash
./scripts/50-smoke-test.sh              # every model in providers/models.yaml
./scripts/50-smoke-test.sh gemini-flash # or just the ones you name
# step 5 must end with "Smoke test passed": each model answers, and its second
# identical request comes back with the same completion id (a Valkey cache hit)

curl -sS -H "Authorization: Bearer $MK" "$BASE/cache/ping" | python3 -m json.tool

echo "$BASE/ui"    # login: admin / $MK
```

Cache probe - run both within the 600s TTL, second call should be much faster:

```bash
for i in 1 2; do
  time curl -sS -X POST "$BASE/v1/chat/completions" \
    -H "Authorization: Bearer $MK" -H "Content-Type: application/json" \
    -d '{"model":"gemini-flash","messages":[{"role":"user","content":"cache probe 42"}],"max_tokens":512}' \
    -o /dev/null
done
```

Valkey from inside a pod (ElastiCache is VPC-only):

```bash
kubectl -n litellm exec deploy/litellm -- python3 -c "
import os, redis
r = redis.Redis(host=os.environ['REDIS_HOST'], port=int(os.environ['REDIS_PORT']))
print('ping:', r.ping(), 'keys:', r.dbsize())
i = r.info(); print('clients:', i.get('connected_clients'), 'hits/misses:', i.get('keyspace_hits'), '/', i.get('keyspace_misses'))
"
```

## 4. Destroy

```bash
./scripts/99-destroy.sh             # type: destroy

aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName, `litellm`)].LoadBalancerName'
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=litellm-poc-vpc" --query 'Vpcs[].VpcId'
# both must return empty
```

---

## Fixes

Rollout stuck, pod Pending, `Insufficient cpu`:

```bash
kubectl -n litellm patch deploy litellm \
  -p '{"spec":{"strategy":{"rollingUpdate":{"maxUnavailable":1}}}}'
```

Migrations Job `OOMKilled`:

```bash
kubectl -n litellm delete job litellm-migrations
./scripts/30-deploy-litellm.sh
```

ALB never appears:

```bash
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50
```

Provider 401 but the key works locally: keyless DB row, re-run step 2.
Provider 404 naming another model: update `providers/models.yaml`, re-run step 2.
UI or smoke test hangs: your IP changed, redo step 0.

---

## Cost

~$10/day running, same idle as busy. Destroy between sessions.
EKS 2.40 | nodes 3.99 | RDS 1.75 | NAT 1.08 | ALB 0.54 | Valkey 0.31 | EBS 0.26
