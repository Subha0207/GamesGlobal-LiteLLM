#!/usr/bin/env bash
# End-to-end check: health, DB-backed model list, a key minted through the
# admin API, then for every model a chat completion and a cache check against
# Valkey.
#
# Usage: 50-smoke-test.sh [model ...]
# With no arguments it tests every model_name in providers/models.yaml.
source "$(dirname "$0")/lib.sh"

need kubectl; need curl; need python3

MASTER_KEY="$(tf_out litellm_master_key)"
ACM_ARN="$(terraform -chdir="$TF_DIR" output -raw acm_certificate_arn 2>/dev/null || true)"
HOST="$(kubectl -n litellm get ingress litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
SCHEME="http"; [[ -n "$ACM_ARN" ]] && SCHEME="https"
BASE_URL="$SCHEME://$HOST"

MODELS=()
if [[ $# -gt 0 ]]; then
  MODELS=("$@")
else
  while read -r m; do MODELS+=("$m"); done < \
    <(awk '/^[[:space:]]*-[[:space:]]*model_name:/ {print $NF}' "$ROOT_DIR/providers/models.yaml")
fi
[[ ${#MODELS[@]} -gt 0 ]] || die "no models to test"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Sends one chat completion: chat MODEL PROMPT OUTFILE. Body goes to OUTFILE and
# curl's total time is printed.
#
# No -f: on a 4xx/5xx the provider's error body is the whole diagnosis, and -f
# discards it in favour of "curl: (22) ... error: 500".
#
# max_tokens is deliberately generous. Reasoning models (Gemini 3.x among them)
# spend the budget on reasoning_tokens first, so a small cap returns
# finish_reason "length" with content: null - a pass that proved nothing.
chat() {
  curl -sS -o "$3" -w '%{time_total}' -X POST "$BASE_URL/v1/chat/completions" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"model\": \"$1\", \"messages\": [{\"role\": \"user\", \"content\": \"$2\"}], \"max_tokens\": 512}"
}

# Prints the completion id when the response is a real answer, otherwise prints
# why it is not and exits 1.
completion_id() {
  python3 - "$1" <<'PY'
import json, sys

raw = open(sys.argv[1]).read()
try:
    d = json.loads(raw)
except ValueError:
    print("not JSON: " + raw[:300])
    sys.exit(1)
if "choices" not in d:
    print(json.dumps(d.get("error", d))[:300])
    sys.exit(1)
c = d["choices"][0]
content = c["message"].get("content")
if c.get("finish_reason") != "stop" or not (content or "").strip():
    print("finish_reason=%s content=%r" % (c.get("finish_reason"), content))
    sys.exit(1)
print(d["id"])
PY
}

# Prints "<key count> <keyspace_hits>" read from Valkey inside a pod
# (ElastiCache is VPC-only, so it cannot be reached from here).
valkey_stats() {
  kubectl -n litellm exec deploy/litellm -- python3 -c "
import os, redis
r = redis.Redis(host=os.environ['REDIS_HOST'], port=int(os.environ['REDIS_PORT']), socket_timeout=5)
print(r.dbsize(), r.info('stats')['keyspace_hits'])
"
}

# Two identical requests with a prompt nobody has sent before. The first proves
# the model answers; the second must come back as the cached response, which
# has the same completion id, and Valkey's own hit counter must move.
test_model() {
  local model="$1" prompt f1 f2 t1 t2 id1 id2 stats keys0 hits0 keys1 hits1
  prompt="Reply with the single word: ok. Cache probe $RANDOM$RANDOM."
  f1="$WORK_DIR/$model.1.json"
  f2="$WORK_DIR/$model.2.json"

  if ! stats="$(valkey_stats)"; then
    echo "  FAIL: cannot read Valkey from the litellm pod"
    return 1
  fi
  read -r keys0 hits0 <<<"$stats"

  if ! t1="$(chat "$model" "$prompt" "$f1")"; then
    echo "  FAIL: request 1 did not complete"
    return 1
  fi
  if ! id1="$(completion_id "$f1")"; then
    echo "  FAIL: request 1: $id1"
    return 1
  fi
  echo "  request 1: answered in ${t1}s (id $id1)"

  # LiteLLM writes the cache entry after it has returned the response.
  sleep 2

  if ! t2="$(chat "$model" "$prompt" "$f2")"; then
    echo "  FAIL: request 2 did not complete"
    return 1
  fi
  if ! id2="$(completion_id "$f2")"; then
    echo "  FAIL: request 2: $id2"
    return 1
  fi
  echo "  request 2: answered in ${t2}s (id $id2)"

  if [[ "$id1" != "$id2" ]]; then
    echo "  FAIL: request 2 was not served from cache (different completion id)"
    return 1
  fi

  if ! stats="$(valkey_stats)"; then
    echo "  FAIL: cannot read Valkey from the litellm pod"
    return 1
  fi
  read -r keys1 hits1 <<<"$stats"
  if (( hits1 <= hits0 )); then
    echo "  FAIL: same completion id, but Valkey recorded no reads (hits $hits0 -> $hits1)"
    return 1
  fi
  echo "  cache hit confirmed: Valkey keys $keys0 -> $keys1, hits $hits0 -> $hits1"
}

log "1/5 liveness"
curl -fsS "$BASE_URL/health/liveliness" && echo

log "2/5 readiness (fails if Postgres is unreachable)"
curl -fsS "$BASE_URL/health/readiness" | python3 -m json.tool

log "3/5 models served from the database (expecting: ${MODELS[*]})"
curl -fsS -H "Authorization: Bearer $MASTER_KEY" "$BASE_URL/v1/models" | python3 -c '
import json, sys

ids = sorted(m["id"] for m in json.load(sys.stdin)["data"])
print("  served: " + ", ".join(ids))
missing = [m for m in sys.argv[1:] if m not in ids]
if missing:
    print("  missing: " + ", ".join(missing))
    sys.exit(1)
' "${MODELS[@]}" || die "model list is incomplete. Run scripts/40-seed-providers.sh; a fresh seed takes up to 30s to appear."

log "4/5 minting a virtual key (writes to Postgres)"
KEY="$(curl -fsS -X POST "$BASE_URL/key/generate" \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"models": [], "max_budget": 1, "key_alias": "smoke-test-'"$RANDOM"'"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')"
echo "  minted ${KEY:0:12}..."

log "5/5 completion and Valkey cache, per model"
FAILED=""
for model in "${MODELS[@]}"; do
  echo "$model"
  if ! test_model "$model"; then FAILED="$FAILED $model"; fi
done

[[ -z "$FAILED" ]] || die "smoke test failed for:$FAILED"

log "Smoke test passed: ${MODELS[*]}"
