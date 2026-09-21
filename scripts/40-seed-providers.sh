#!/usr/bin/env bash
# Loads providers/models.yaml into Postgres via the LiteLLM admin API.
# This is the supported way to manage the provider list without the UI.
#
#   ./40-seed-providers.sh            # add/replace what the file defines
#   ./40-seed-providers.sh --prune    # also delete anything not in the file
#   ./40-seed-providers.sh --dry-run
source "$(dirname "$0")/lib.sh"

need kubectl; need python3

# seed_providers.py resolves os.environ/NAME references from THIS shell before
# POSTing, so the provider keys have to be present here - not just in the pods.
# set -a exports what .env defines: a plain source makes the values visible to
# this script but not to the python3 child process that actually reads them.
if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  source "$ROOT_DIR/.env"
  set +a
fi

MASTER_KEY="$(tf_out litellm_master_key)"
ACM_ARN="$(terraform -chdir="$TF_DIR" output -raw acm_certificate_arn 2>/dev/null || true)"
HOST="$(kubectl -n litellm get ingress litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
[[ -n "$HOST" ]] || die "ingress has no ALB hostname yet"

SCHEME="http"; [[ -n "$ACM_ARN" ]] && SCHEME="https"
BASE_URL="$SCHEME://$HOST"

log "Seeding providers into Postgres via $BASE_URL"
python3 "$ROOT_DIR/scripts/seed_providers.py" \
  --base-url "$BASE_URL" \
  --master-key "$MASTER_KEY" \
  --file "$ROOT_DIR/providers/models.yaml" \
  "$@"

log "Models now stored in the database"
curl -sS -H "Authorization: Bearer $MASTER_KEY" "$BASE_URL/v1/models" | python3 -m json.tool
