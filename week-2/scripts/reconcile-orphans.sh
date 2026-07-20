#!/usr/bin/env bash
# Reconcile Terraform-managed resources that Floci retains across a state reset.
#
# The CloudWatch audit log group and the force_ssl RDS parameter group are
# CREATED by hardening.tf (they are remediations we add), NOT by the setup
# scripts — so they deliberately have no import{} block in import.tf. But Floci
# keeps the cloud objects after Terraform's state loses track of them (e.g. an
# RDS replacement, or a state reset), so a plain `terraform apply` then tries to
# CREATE them again and fails with:
#   ResourceAlreadyExistsException / DBParameterGroupAlreadyExists
#
# Importing them if-and-only-if they are orphaned (present in Floci, absent from
# state) makes `apply` idempotent. This is a no-op once they're in state, and a
# no-op on a clean Floci where they don't exist yet — so it is safe to run
# before every apply.
set -euo pipefail

export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

in_state() { terraform state list 2>/dev/null | grep -qx "$1"; }

# Audit CloudWatch Logs group (hardening.tf: aws_cloudwatch_log_group.pii_access_audit)
if ! in_state aws_cloudwatch_log_group.pii_access_audit; then
  found=$(aws logs describe-log-groups --log-group-name-prefix /acme-corp/pii-access-audit --query 'logGroups[0].logGroupName' --output text 2>/dev/null || true)
  if [ "$found" = "/acme-corp/pii-access-audit" ]; then
    echo "== Adopting orphaned log group /acme-corp/pii-access-audit =="
    terraform import aws_cloudwatch_log_group.pii_access_audit /acme-corp/pii-access-audit
  fi
fi

# FIPS RDS parameter group (hardening.tf: aws_db_parameter_group.users_db_fips)
if ! in_state aws_db_parameter_group.users_db_fips; then
  found=$(aws rds describe-db-parameter-groups --db-parameter-group-name acme-corp-users-db-fips --query 'DBParameterGroups[0].DBParameterGroupName' --output text 2>/dev/null || true)
  if [ "$found" = "acme-corp-users-db-fips" ]; then
    echo "== Adopting orphaned parameter group acme-corp-users-db-fips =="
    terraform import aws_db_parameter_group.users_db_fips acme-corp-users-db-fips
  fi
fi

echo "== Reconcile complete — safe to run 'terraform apply' =="
