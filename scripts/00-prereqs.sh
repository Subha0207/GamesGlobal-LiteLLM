#!/usr/bin/env bash
# Verifies the local toolchain and AWS credentials before anything is created.
source "$(dirname "$0")/lib.sh"

log "Checking local tools"
for t in terraform aws kubectl helm python3 curl; do
  need "$t"
  printf '  ok  %-10s %s\n' "$t" "$(command -v "$t")"
done

log "Checking AWS credentials"
aws sts get-caller-identity --output table || die "no usable AWS credentials"

log "Checking python yaml module (used by the provider seeder)"
python3 -c 'import yaml' 2>/dev/null || warn "PyYAML not installed. Run: python3 -m pip install pyyaml"

log "Prerequisites look good."
