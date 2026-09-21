# Shared helpers. Sourced by the numbered scripts, not run directly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
K8S_DIR="$ROOT_DIR/k8s"
RENDER_DIR="$K8S_DIR/rendered"

# Pin the image. "latest" on a proxy that owns your credential store is a bad trade.
LITELLM_IMAGE="${LITELLM_IMAGE:-ghcr.io/berriai/litellm:v1.90.2}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARN: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

tf_out() {
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || die "terraform output '$1' not found. Run scripts/10-deploy-infra.sh first."
}

tf_out_json() {
  terraform -chdir="$TF_DIR" output -json "$1" 2>/dev/null || die "terraform output '$1' not found."
}
