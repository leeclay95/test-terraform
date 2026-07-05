#!/usr/bin/env bash
# Real access-audit logging via CloudWatch Logs — not a local file.
#
# WHY CLOUDWATCH LOGS AND NOT CLOUDTRAIL: tested by hand before writing this
# script. `aws cloudtrail create-trail` / `start-logging` / `describe-trails`
# all work on Floci v1.5.30 (the trail *management* API is real), but even
# with S3 data-event selectors explicitly configured via put-event-selectors,
# generating both a successful and a failed GetObject produced zero entries
# in `lookup-events` and zero objects delivered to the trail's S3 bucket.
# CloudTrail's event-*capture* pipeline isn't implemented here, only its
# configuration API — so it cannot give us real access logging in this
# environment. S3 server access logging has the same problem (accepts
# put-bucket-logging, never delivers). See WALKTHROUGH.md section 4 for the
# full test transcript.
#
# CloudWatch Logs, in contrast, is a genuine working Floci service (verified:
# create-log-group / create-log-stream / put-log-events / get-log-events /
# filter-log-events all round-trip real data). So this script does what a lot
# of real production systems do for events a cloud provider doesn't capture
# automatically: the client performing the access explicitly publishes an
# audit record to CloudWatch Logs itself, rather than relying on the
# provider's own audit trail to notice.
set -euo pipefail

: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
export AWS_ENDPOINT_URL
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
unset AWS_PROFILE

LOG_GROUP="/acme-corp/pii-access-audit"
LOG_STREAM="access-$(date -u +%Y-%m-%d)-$$"

BUCKETS=(
  acme-corp-hr-records
  acme-corp-customer-support
  acme-corp-payroll-exports
  acme-corp-marketing-leads
  acme-corp-legacy-backups
)
DB_ID="acme-corp-users-db"

aws logs create-log-stream --log-group-name "$LOG_GROUP" --log-stream-name "$LOG_STREAM"

log_event() {
  local action=$1 resource=$2 result=$3
  local ts_ms message
  ts_ms=$(date +%s%3N)
  message=$(printf '{"actor":"demo-script","action":"%s","resource":"%s","result":"%s"}' "$action" "$resource" "$result")
  aws logs put-log-events \
    --log-group-name "$LOG_GROUP" \
    --log-stream-name "$LOG_STREAM" \
    --log-events "[{\"timestamp\":$ts_ms,\"message\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$message")}]" \
    >/dev/null
}

# Runs "$@"; logs success or failure based on the REAL exit code. An `if`
# condition is exempt from `set -e`, so a failed access is captured as data
# rather than aborting the script.
attempt_access() {
  local action=$1 resource=$2; shift 2
  if "$@" >/dev/null 2>&1; then
    log_event "$action" "$resource" "success"
  else
    log_event "$action" "$resource" "failure"
  fi
}

echo "== Simulating access to each PII bucket (real objects: success) =="
for bucket in "${BUCKETS[@]}"; do
  key=$(aws s3api list-objects-v2 --bucket "$bucket" --query 'Contents[0].Key' --output text)
  if [ -n "$key" ] && [ "$key" != "None" ]; then
    attempt_access "s3:GetObject" "s3://$bucket/$key" \
      aws s3api get-object --bucket "$bucket" --key "$key" /tmp/week2-access-check.bin
    echo "  read $bucket/$key"
  fi
done

echo "== Simulating a failed access (nonexistent object) =="
attempt_access "s3:GetObject" "s3://${BUCKETS[0]}/does-not-exist.csv" \
  aws s3api get-object --bucket "${BUCKETS[0]}" --key "does-not-exist.csv" /tmp/week2-access-check.bin
echo "  attempted ${BUCKETS[0]}/does-not-exist.csv (expected to fail)"
rm -f /tmp/week2-access-check.bin

echo "== Simulating access to the RDS instance metadata (success) =="
attempt_access "rds:DescribeDBInstances" "$DB_ID" \
  aws rds describe-db-instances --db-instance-identifier "$DB_ID"
echo "  described $DB_ID"

echo "== Simulating a failed RDS access (nonexistent instance) =="
# NOTE: `describe-db-instances` on a bad identifier returns an empty list
# with exit 0 on Floci (a real behavior deviation — real AWS raises
# DBInstanceNotFoundFault here, confirmed by hand), so it can't demonstrate
# a failure in this environment. `reboot-db-instance` does error correctly
# on a nonexistent identifier, so that's used here instead.
attempt_access "rds:RebootDBInstance" "acme-corp-does-not-exist" \
  aws rds reboot-db-instance --db-instance-identifier "acme-corp-does-not-exist"
echo "  attempted acme-corp-does-not-exist (expected to fail)"

echo
echo "== Real CloudWatch Logs entries (log group: $LOG_GROUP, stream: $LOG_STREAM) =="
aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$LOG_STREAM" --query 'events[].message' --output table
