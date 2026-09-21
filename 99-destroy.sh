#!/usr/bin/env bash
# Tears the POC down. Deletes the Ingress first so the load balancer controller
# removes the ALB while it still has permissions - otherwise terraform destroy
# hangs on the VPC because of an orphaned ALB and its security group.
source "$(dirname "$0")/lib.sh"

need terraform

read -r -p "This destroys the EKS cluster, the Postgres database and the Valkey cache. Type 'destroy' to continue: " confirm
[[ "$confirm" == "destroy" ]] || die "aborted"

if kubectl -n litellm get ingress litellm >/dev/null 2>&1; then
  log "Deleting the ingress and waiting for the ALB to go away"
  kubectl -n litellm delete ingress litellm --wait
  sleep 45
fi

kubectl delete namespace litellm --ignore-not-found --wait || true

log "terraform destroy"
terraform -chdir="$TF_DIR" destroy "$@"
