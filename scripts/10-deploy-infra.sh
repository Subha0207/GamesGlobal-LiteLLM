#!/usr/bin/env bash
# Creates the VPC, EKS cluster, RDS Postgres, ElastiCache Valkey and IAM roles.
# Takes roughly 20-25 minutes, most of it EKS and RDS.
source "$(dirname "$0")/lib.sh"

need terraform

if [[ ! -f "$TF_DIR/terraform.tfvars" ]]; then
  log "No terraform.tfvars found, copying the example"
  cp "$TF_DIR/terraform.tfvars.example" "$TF_DIR/terraform.tfvars"
  warn "Review $TF_DIR/terraform.tfvars before a real deployment (especially ingress_allowed_cidrs)."
fi

log "terraform init"
terraform -chdir="$TF_DIR" init -upgrade

log "terraform apply"
terraform -chdir="$TF_DIR" apply "$@"

log "Infrastructure ready"
terraform -chdir="$TF_DIR" output
