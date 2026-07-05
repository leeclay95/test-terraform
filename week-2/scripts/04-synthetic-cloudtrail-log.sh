#!/usr/bin/env bash
# Writes SYNTHETIC but format-accurate CloudTrail log files directly to the
# trail's S3 bucket, one real access attempt at a time.
#
# WHY THIS EXISTS: Floci's own docs are explicit — "Floci does not record
# live API activity into trails." Only the trail *management* API
# (CreateTrail/StartLogging/DescribeTrails/etc.) is implemented; there is no
# internal event bus wiring actual API calls to trail delivery, on Floci or
# on real AWS — CloudTrail has no "PutEvent" API on either platform, event
# capture is always automatic and never client-writable. So there is no way
# to make real event capture happen here.
#
# What this script does instead: performs the SAME real access attempts as
# scripts/03-cloudwatch-access-log.sh (real S3 GetObject calls, a real RDS
# describe, and two calls engineered to genuinely fail), then hand-builds a
# CloudTrail-shaped JSON record for each one — matching AWS's actual record
# schema (eventVersion, eventSource, eventName, userIdentity,
# requestParameters, errorCode/errorMessage on failures, etc.) — gzips them,
# and uploads to the trail bucket at the real CloudTrail S3 key convention:
#   AWSLogs/<account-id>/CloudTrail/<region>/<year>/<month>/<day>/<account-id>_CloudTrail_<region>_<timestamp>_<random>.json.gz
#
# This is CLEARLY SYNTHETIC DATA, not real CloudTrail capture — label it as
# such wherever you reference it. It will never appear in
# `aws cloudtrail lookup-events` (that's a separate internal datastore this
# script has no way to write to). Its only purpose is to give you real,
# correctly-shaped log *files* to practice parsing/querying, since Floci
# cannot produce them itself.
set -euo pipefail

: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
export AWS_ENDPOINT_URL
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
unset AWS_PROFILE

ACCOUNT_ID="000000000000"
REGION="us-east-1"
TRAIL_BUCKET="week2-cloudtrail-logs"
BUCKETS=(acme-corp-hr-records acme-corp-customer-support acme-corp-payroll-exports acme-corp-marketing-leads acme-corp-legacy-backups)
DB_ID="acme-corp-users-db"

aws s3 mb "s3://$TRAIL_BUCKET" 2>/dev/null || true

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
RECORDS_FILE="$WORKDIR/records.json"
echo '[]' > "$RECORDS_FILE"

uuid() { python3 -c "import uuid; print(uuid.uuid4())"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Builds one CloudTrail record and appends it to $RECORDS_FILE. Takes the
# real exit code of "$@" to decide success vs failure — the record's
# errorCode/errorMessage are only present when the access genuinely failed.
add_record() {
  local event_source=$1 event_name=$2 event_category=$3 request_params=$4
  shift 4
  local err_code="" err_msg="" real_err rc=0
  real_err=$("$@" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    err_code=$(echo "$real_err" | grep -oE '\([A-Za-z]+\)' | head -1 | tr -d '()')
    [ -n "$err_code" ] || err_code="AccessDenied"
    err_msg=$(echo "$real_err" | sed -n 's/.*aws: \[ERROR\]: //p')
    [ -n "$err_msg" ] || err_msg="$real_err"
  fi

  python3 - "$event_source" "$event_name" "$event_category" "$request_params" "$err_code" "$err_msg" "$ACCOUNT_ID" "$REGION" "$RECORDS_FILE" <<'PYEOF'
import json, sys, uuid, datetime
event_source, event_name, event_category, request_params, err_code, err_msg, account_id, region, records_file = sys.argv[1:10]
record = {
    "eventVersion": "1.08",
    "eventTime": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "eventSource": event_source,
    "eventName": event_name,
    "awsRegion": region,
    "sourceIPAddress": "127.0.0.1",
    "userAgent": "aws-cli/2.x demo-script",
    "requestParameters": json.loads(request_params),
    "responseElements": None,
    "requestID": str(uuid.uuid4()),
    "eventID": str(uuid.uuid4()),
    "eventType": "AwsApiCall",
    "managementEvent": event_category == "Management",
    "recipientAccountId": account_id,
    "eventCategory": event_category,
    "userIdentity": {
        "type": "IAMUser", "principalId": "AIDADEMO", "accountId": account_id,
        "accessKeyId": "test", "userName": "demo-script",
        "arn": f"arn:aws:iam::{account_id}:user/demo-script",
    },
}
if err_code:
    record["errorCode"] = err_code
    record["errorMessage"] = err_msg

with open(records_file) as f:
    records = json.load(f)
records.append(record)
with open(records_file, "w") as f:
    json.dump(records, f)
PYEOF
}

echo "== Recording real bucket access attempts as synthetic CloudTrail data events =="
for bucket in "${BUCKETS[@]}"; do
  key=$(aws s3api list-objects-v2 --bucket "$bucket" --query 'Contents[0].Key' --output text)
  if [ -n "$key" ] && [ "$key" != "None" ]; then
    add_record "s3.amazonaws.com" "GetObject" "Data" \
      "{\"bucketName\":\"$bucket\",\"key\":\"$key\"}" \
      aws s3api get-object --bucket "$bucket" --key "$key" /tmp/week2-ct-check.bin
    echo "  recorded: GetObject $bucket/$key"
  fi
done

echo "== Recording a genuinely failed bucket access =="
add_record "s3.amazonaws.com" "GetObject" "Data" \
  "{\"bucketName\":\"${BUCKETS[0]}\",\"key\":\"does-not-exist.csv\"}" \
  aws s3api get-object --bucket "${BUCKETS[0]}" --key "does-not-exist.csv" /tmp/week2-ct-check.bin
rm -f /tmp/week2-ct-check.bin
echo "  recorded: GetObject failure"

echo "== Recording a real RDS management event =="
add_record "rds.amazonaws.com" "DescribeDBInstances" "Management" \
  "{\"dBInstanceIdentifier\":\"$DB_ID\"}" \
  aws rds describe-db-instances --db-instance-identifier "$DB_ID"
echo "  recorded: DescribeDBInstances success"

echo "== Recording a genuinely failed RDS management event =="
add_record "rds.amazonaws.com" "RebootDBInstance" "Management" \
  '{"dBInstanceIdentifier":"acme-corp-does-not-exist"}' \
  aws rds reboot-db-instance --db-instance-identifier "acme-corp-does-not-exist"
echo "  recorded: RebootDBInstance failure"

echo "== Assembling and uploading the CloudTrail-formatted log file =="
python3 -c "
import json
with open('$RECORDS_FILE') as f:
    records = json.load(f)
with open('$WORKDIR/final.json', 'w') as f:
    json.dump({'Records': records}, f)
"
gzip -c "$WORKDIR/final.json" > "$WORKDIR/final.json.gz"

TS=$(date -u +%Y%m%dT%H%MZ)
RAND=$(python3 -c "import uuid; print(uuid.uuid4().hex[:16])")
YEAR=$(date -u +%Y); MONTH=$(date -u +%m); DAY=$(date -u +%d)
KEY="AWSLogs/$ACCOUNT_ID/CloudTrail/$REGION/$YEAR/$MONTH/$DAY/${ACCOUNT_ID}_CloudTrail_${REGION}_${TS}_${RAND}.json.gz"

aws s3 cp "$WORKDIR/final.json.gz" "s3://$TRAIL_BUCKET/$KEY"

echo
echo "== Done (SYNTHETIC data — see script header) =="
echo "  Uploaded: s3://$TRAIL_BUCKET/$KEY"
echo "  Inspect:  aws s3 cp s3://$TRAIL_BUCKET/$KEY - | zcat | jq ."
