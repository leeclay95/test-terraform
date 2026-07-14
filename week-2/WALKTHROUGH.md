# Week 2 Class Walkthrough — Terraform Import + Real Security Hardening

Full, copy-paste-in-order script: stand up "found infrastructure" that's
actively insecure (public S3 buckets full of PII, an unhardened RDS
instance), bring it under Terraform via import, find every NIST 800-53 gap,
fix what can be fixed without downtime, and set up **real** access-audit
logging via CloudWatch Logs — with an honest accounting of what actually
works in this local environment and what doesn't.

---

## 0. Environment setup

Everything runs against **Floci**, a local AWS-API-compatible emulator
(v1.5.30+ — CloudTrail's trail-management API and RDS's real Docker-backed
Postgres both depend on a reasonably current version).

```bash
cd /home/kali/floci
docker compose pull
docker compose up -d --force-recreate
docker compose ps
```

`--force-recreate` matters if you're on an old image — see the "Version
matters" note at the end of this section.

Export credentials for every shell you run `aws`/`terraform` from:
```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
unset AWS_PROFILE
```
`unset AWS_PROFILE` matters if you have other named profiles configured (SSO,
IAM users) — a leftover `AWS_PROFILE` overrides the static creds above.

**Version matters:** this walkthrough depends on Floci v1.5.30+. On an older
image, CloudTrail returns `UnknownOperationException` for every operation,
and this was fixed between versions.

**Persistent storage matters too.** By default `FLOCI_STORAGE_MODE=hybrid`
with no volume mount means a container recreate wipes everything. Add this to
`docker-compose.yml` once, so future restarts don't cost you the lab state:
```yaml
services:
  floci:
    environment:
      - FLOCI_STORAGE_MODE=hybrid
      - FLOCI_STORAGE_PERSISTENT_PATH=/data
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./floci-data:/data
```
Create the host data dir **owned by the Floci app user before you start the
container**. The process inside runs as UID 1001 / GID 0, so the mount has to
be writable by that UID — otherwise every persist write fails with
`Permission denied` and S3 API calls return 500 even though the health
endpoint shows `s3` "running":
```bash
mkdir -p floci-data
sudo chown -R 1001:0 floci-data && sudo chmod -R 775 floci-data
```
Run these before `docker compose up`. If the container is already up, run them
now — the next persist flush picks up the change, no restart needed.

---

## 1. Scaffold the project

```bash
cd /home/kali/floci/terraform-lesson-project/demo-test-2
mkdir -p week-2/scripts week-2/evidence
cd week-2
```

### `main.tf` — provider config

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
}
```
No `endpoints {}` block needed — AWS provider v5 reads `AWS_ENDPOINT_URL` from
the environment automatically.

---

## 2. Phase 1 — create the "found" infrastructure (bash, not Terraform)

This simulates infrastructure that existed before Terraform ever touched it:
5 S3 buckets made **actively public** (not just under-configured), and an RDS
instance with no hardening.

### `scripts/01-create-buckets.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
export AWS_ENDPOINT_URL
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
unset AWS_PROFILE

BUCKETS=(
  acme-corp-hr-records
  acme-corp-customer-support
  acme-corp-payroll-exports
  acme-corp-marketing-leads
  acme-corp-legacy-backups
)

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

generate_fake_pii() {
  local out=$1 rows=$2
  {
    echo "id,full_name,email,ssn,dob,notes"
    for ((i = 1; i <= rows; i++)); do
      printf 'FAKE-%04d,Test Testerson %d,fake.user%d@example.com,000-%02d-%04d,1990-01-%02d,synthetic-demo-record\n' \
        "$i" "$i" "$i" "$((i % 99))" "$((RANDOM % 9999))" "$(((i % 28) + 1))"
    done
  } > "$out"
}

for bucket in "${BUCKETS[@]}"; do
  aws s3 mb "s3://$bucket"

  aws s3api put-public-access-block \
    --bucket "$bucket" \
    --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

  policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicReadGetObject", "Effect": "Allow", "Principal": "*",
    "Action": "s3:GetObject", "Resource": "arn:aws:s3:::$bucket/*"
  }]
}
EOF
)
  aws s3api put-bucket-policy --bucket "$bucket" --policy "$policy"

  csv="$WORKDIR/${bucket}.csv"
  generate_fake_pii "$csv" 25
  aws s3 cp "$csv" "s3://$bucket/export-$(date +%Y%m%d).csv"
done
```
Data is synthetic on purpose: `example.com` emails (RFC 2606 reserved) and
`000-xx-xxxx` SSNs (an invalid prefix never issued to a real person).

Run it: `bash scripts/01-create-buckets.sh`

Confirm the gaps yourself:
```bash
aws s3 ls
aws s3api get-bucket-policy --bucket acme-corp-hr-records --query Policy --output text
aws s3api get-public-access-block --bucket acme-corp-hr-records
```

### `scripts/02-create-rds.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
export AWS_ENDPOINT_URL
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
unset AWS_PROFILE

DB_ID="acme-corp-users-db"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE_DIR="$SCRIPT_DIR/../evidence"
mkdir -p "$EVIDENCE_DIR"

aws rds create-db-instance \
  --db-instance-identifier "$DB_ID" --db-instance-class db.t3.micro \
  --engine postgres --engine-version 16.3 \
  --master-username appadmin --master-user-password "DemoPass123!" \
  --allocated-storage 20 --db-name appdb --no-multi-az \
  --tags Key=data-classification,Value=pii Key=owner,Value=acme-corp-app-team Key=demo,Value=week-2-import \
  > "$EVIDENCE_DIR/rds_create_response.json"

aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
aws rds describe-db-instances --db-instance-identifier "$DB_ID" > "$EVIDENCE_DIR/rds_describe.json"

DB_HOST=$(python3 -c "import json; print(json.load(open('$EVIDENCE_DIR/rds_describe.json'))['DBInstances'][0]['Endpoint']['Address'])")
DB_PORT=$(python3 -c "import json; print(json.load(open('$EVIDENCE_DIR/rds_describe.json'))['DBInstances'][0]['Endpoint']['Port'])")

cat > "$EVIDENCE_DIR/simulated_users.csv" <<'CSV'
id,username,email,ssn,signup_date
1,ttesterson1,fake.user1@example.com,000-01-0001,2023-01-04
2,ttesterson2,fake.user2@example.com,000-02-0002,2023-02-11
3,ttesterson3,fake.user3@example.com,000-03-0003,2023-03-22
4,ttesterson4,fake.user4@example.com,000-04-0004,2023-05-09
5,ttesterson5,fake.user5@example.com,000-05-0005,2023-07-17
CSV

# aws rds wait only confirms the control-plane status flipped to "available" —
# the postgres process inside the container can lag a few seconds behind
# that, so retry rather than treating one failed connection as "unreachable".
ready=""
for i in $(seq 1 20); do
  if PGPASSWORD="DemoPass123!" psql -h "$DB_HOST" -p "$DB_PORT" -U appadmin -d appdb -c '\q' 2>/dev/null; then
    ready=1; break
  fi
  sleep 3
done
[ -n "$ready" ] || { echo "Postgres never came up" >&2; exit 1; }

PGPASSWORD="DemoPass123!" psql -h "$DB_HOST" -p "$DB_PORT" -U appadmin -d appdb <<SQL
CREATE TABLE IF NOT EXISTS users (
  id integer PRIMARY KEY, username text NOT NULL, email text NOT NULL,
  ssn text NOT NULL, signup_date date NOT NULL
);
SQL
PGPASSWORD="DemoPass123!" psql -h "$DB_HOST" -p "$DB_PORT" -U appadmin -d appdb \
  -c "\copy users FROM '$EVIDENCE_DIR/simulated_users.csv' WITH (FORMAT csv, HEADER true)"
```

Run it: `bash scripts/02-create-rds.sh`

---

## 3. Accessing the RDS instance

Floci backs RDS with a **real `postgres:16-alpine` Docker container** — RDS is
"Real Docker" per Floci's own docs, not a shallow mock, same as Lambda,
ElastiCache, Neptune, DocumentDB, MSK, ECS, EC2, EKS, OpenSearch.

### Get connection details
```bash
aws rds describe-db-instances --db-instance-identifier acme-corp-users-db \
  --query 'DBInstances[0].{Address:Endpoint.Address,Port:Endpoint.Port,Status:DBInstanceStatus}' \
  --output table
```
This lab's instance: `172.18.0.2:7001`.

### Connect and query the seeded data
```bash
PGPASSWORD='DemoPass123!' psql -h 172.18.0.2 -p 7001 -U appadmin -d appdb -c "SELECT * FROM users;"
```

### List all buckets and read their contents
```bash
aws s3 ls
for b in acme-corp-hr-records acme-corp-customer-support acme-corp-payroll-exports acme-corp-marketing-leads acme-corp-legacy-backups; do
  echo "--- $b ---"; aws s3 ls "s3://$b/"
done

# view a file's contents without downloading it (dash = stdout)
aws s3 cp s3://acme-corp-hr-records/export-20260705.csv -
```

---

## 4. Real access-audit logging (not a simulated file)

### 4a. What we tried first, and why it doesn't work here

**S3 server access logging** — real command:
```bash
aws s3api put-bucket-logging --bucket acme-corp-hr-records --bucket-logging-status '{
  "LoggingEnabled": {"TargetBucket": "acme-corp-access-logs", "TargetPrefix": "logs/"}
}'
```
Confirmed by hand: Floci accepts this with no error, but never delivers log
objects to the target bucket, even after generating real traffic and waiting.

**CloudTrail** — real commands:
```bash
aws cloudtrail create-trail --name week2-trail --s3-bucket-name week2-cloudtrail-logs
aws cloudtrail start-logging --name week2-trail
aws cloudtrail put-event-selectors --trail-name week2-trail --event-selectors \
  '[{"ReadWriteType":"All","IncludeManagementEvents":true,"DataResources":[{"Type":"AWS::S3::Object","Values":["arn:aws:s3:::acme-corp-hr-records/"]}]}]'
```
All of these succeed on Floci v1.5.30 (the trail *management* API is real —
confirmed: `describe-trails`, `create-trail`, `start-logging`,
`get-trail-status` all work correctly, unlike on older images). **But event
capture doesn't work.** After configuring S3 data-event selectors and
generating both a successful and a failed `GetObject`:
```bash
aws cloudtrail lookup-events --max-results 10
# {"Events": []}          <- every time, no matter how long you wait

aws s3 ls s3://week2-cloudtrail-logs/ --recursive
# (nothing delivered)
```
The container's own logs confirm why — you can see the CloudTrail
*configuration* API calls being logged (`PutEventSelectors`, `LookupEvents`),
but nothing resembling an event being recorded for the S3 calls themselves.
CloudTrail's event-capture pipeline isn't implemented in this Floci version;
only its configuration surface is.

### 4b. What actually works: real CloudWatch Logs

CloudWatch Logs is a genuinely working Floci service — confirmed by hand:
```bash
aws logs create-log-group --log-group-name /test
aws logs create-log-stream --log-group-name /test --log-stream-name s1
aws logs put-log-events --log-group-name /test --log-stream-name s1 \
  --log-events '[{"timestamp":1234567890000,"message":"hello"}]'
aws logs get-log-events --log-group-name /test --log-stream-name s1
# real event comes back, round-trips correctly
```

So instead of relying on CloudTrail to *notice* access to the PII buckets and
the RDS instance (it can't, here), `scripts/03-cloudwatch-access-log.sh`
**explicitly publishes an audit record to CloudWatch Logs** every time it
performs an access. This is a real, common production pattern for events a
cloud provider's own audit trail doesn't capture automatically — not a lesser
substitute.

The log group itself is Terraform-managed (see Part 6, AU-2/AU-3/AU-12):
```hcl
resource "aws_cloudwatch_log_group" "pii_access_audit" {
  name              = "/acme-corp/pii-access-audit"
  retention_in_days = 90
}
```

### `scripts/03-cloudwatch-access-log.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
export AWS_ENDPOINT_URL
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
unset AWS_PROFILE

LOG_GROUP="/acme-corp/pii-access-audit"
LOG_STREAM="access-$(date -u +%Y-%m-%d)-$$"
BUCKETS=(acme-corp-hr-records acme-corp-customer-support acme-corp-payroll-exports acme-corp-marketing-leads acme-corp-legacy-backups)
DB_ID="acme-corp-users-db"

aws logs create-log-stream --log-group-name "$LOG_GROUP" --log-stream-name "$LOG_STREAM"

log_event() {
  local action=$1 resource=$2 result=$3 ts_ms message
  ts_ms=$(date +%s%3N)
  message=$(printf '{"actor":"demo-script","action":"%s","resource":"%s","result":"%s"}' "$action" "$resource" "$result")
  aws logs put-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$LOG_STREAM" \
    --log-events "[{\"timestamp\":$ts_ms,\"message\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$message")}]" >/dev/null
}

# An `if` condition is exempt from `set -e` — this is what lets a failed
# access be captured as data instead of aborting the script.
attempt_access() {
  local action=$1 resource=$2; shift 2
  if "$@" >/dev/null 2>&1; then log_event "$action" "$resource" "success"
  else log_event "$action" "$resource" "failure"; fi
}

for bucket in "${BUCKETS[@]}"; do
  key=$(aws s3api list-objects-v2 --bucket "$bucket" --query 'Contents[0].Key' --output text)
  [ -n "$key" ] && [ "$key" != "None" ] && attempt_access "s3:GetObject" "s3://$bucket/$key" \
    aws s3api get-object --bucket "$bucket" --key "$key" /tmp/week2-access-check.bin
done

# Deliberate failure: an object that was never uploaded
attempt_access "s3:GetObject" "s3://${BUCKETS[0]}/does-not-exist.csv" \
  aws s3api get-object --bucket "${BUCKETS[0]}" --key "does-not-exist.csv" /tmp/week2-access-check.bin
rm -f /tmp/week2-access-check.bin

attempt_access "rds:DescribeDBInstances" "$DB_ID" \
  aws rds describe-db-instances --db-instance-identifier "$DB_ID"

# NOTE: describe-db-instances on a bad identifier returns an empty list with
# exit 0 on Floci (real AWS raises DBInstanceNotFoundFault here — a confirmed
# behavior deviation), so it can't demonstrate a failure. reboot-db-instance
# does error correctly on a nonexistent identifier.
attempt_access "rds:RebootDBInstance" "acme-corp-does-not-exist" \
  aws rds reboot-db-instance --db-instance-identifier "acme-corp-does-not-exist"

aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$LOG_STREAM" --query 'events[].message' --output table
```

Run it: `bash scripts/03-cloudwatch-access-log.sh`

### 4c. Verifying the log — commands you can run yourself

```bash
# list streams, find the most recent
aws logs describe-log-streams --log-group-name /acme-corp/pii-access-audit \
  --order-by LastEventTime --descending --query 'logStreams[0].logStreamName' --output text

# read every event in a stream
aws logs get-log-events --log-group-name /acme-corp/pii-access-audit \
  --log-stream-name <stream-name-from-above>

# search across ALL streams for failures specifically
aws logs filter-log-events --log-group-name /acme-corp/pii-access-audit \
  --filter-pattern '"result\":\"failure\"'

# search for successes
aws logs filter-log-events --log-group-name /acme-corp/pii-access-audit \
  --filter-pattern '"result\":\"success\"'

# count events in the last hour
aws logs filter-log-events --log-group-name /acme-corp/pii-access-audit \
  --start-time "$(($(date +%s%3N) - 3600000))" --query 'length(events)'
```
Expected from one run of the script: 6 `success` entries (5 bucket reads + 1
RDS describe) and 2 `failure` entries (1 bad object key, 1 bad RDS
identifier).

### 4d. If you want CloudTrail-shaped log files anyway: synthetic records

CloudTrail itself has no "write an event" API — on real AWS *or* Floci,
events are always generated internally, never pushed in by a client. Floci's
own docs confirm it further: **"Floci does not record live API activity into
trails."** Only the trail management API (create/start/describe/etc.) is
implemented — there's no way to make real event capture happen here, full
stop.

What you *can* do instead: `scripts/04-synthetic-cloudtrail-log.sh` performs
the same real access attempts as the CloudWatch script above, then hand-builds
a real AWS CloudTrail-schema JSON record for each one and uploads it to the
trail's S3 bucket at the actual CloudTrail key convention. This is clearly
**synthetic data** — it will never appear in `aws cloudtrail lookup-events`
— but the log *files* themselves are correctly shaped, so you get something
real to practice parsing against.

**Just run it — after `terraform apply` has run at least once:**
```bash
bash scripts/04-synthetic-cloudtrail-log.sh
```
`week2-cloudtrail-logs` is Terraform-managed (`aws_s3_bucket.cloudtrail_logs`
in `hardening.tf`, with the same PAB + SSE-KMS hardening as `access_logs`,
plus the real bucket policy a CloudTrail trail requires). The script checks
for the bucket with `head-bucket` and exits with an error telling you to run
`terraform apply` first if it doesn't exist yet — it no longer creates the
bucket itself. Each run then performs:
- 5 successful `s3:GetObject` calls (one real object per PII bucket)
- 1 deliberately failed `s3:GetObject` (a key that was never uploaded)
- 1 successful `rds:DescribeDBInstances`
- 1 deliberately failed `rds:RebootDBInstance` (a nonexistent instance ID —
  `describe-db-instances` on a bad ID returns an empty list with exit 0 on
  Floci instead of erroring, a confirmed behavior deviation from real AWS, so
  it can't demonstrate a failure; `reboot-db-instance` does error correctly)

...then gzips all 8 records into one file and uploads it to:
```
s3://week2-cloudtrail-logs/AWSLogs/000000000000/CloudTrail/us-east-1/<year>/<month>/<day>/000000000000_CloudTrail_us-east-1_<timestamp>_<random>.json.gz
```

### Verifying the generated logs

```bash
# find the most recently uploaded log file
LATEST=$(aws s3 ls s3://week2-cloudtrail-logs/AWSLogs/000000000000/CloudTrail/us-east-1/ --recursive | sort | tail -1 | awk '{print $4}')
echo "$LATEST"

# pretty-print every record
aws s3 cp "s3://week2-cloudtrail-logs/$LATEST" - | zcat | jq .

# just the outcome of each event (eventName + errorCode, if any)
aws s3 cp "s3://week2-cloudtrail-logs/$LATEST" - | zcat | jq '.Records[] | {eventName, errorCode, errorMessage}'

# count successes vs failures in that file
aws s3 cp "s3://week2-cloudtrail-logs/$LATEST" - | zcat | jq '[.Records[] | select(.errorCode == null)] | length'   # successes
aws s3 cp "s3://week2-cloudtrail-logs/$LATEST" - | zcat | jq '[.Records[] | select(.errorCode != null)] | length'   # failures

# list every log file ever generated, across all runs
aws s3 ls s3://week2-cloudtrail-logs/AWSLogs/000000000000/CloudTrail/us-east-1/ --recursive
```
Expected from one run: 6 records with `errorCode: null` (successes), 2 with a
real `errorCode` set (`NoSuchKey` and `DBInstanceNotFound`).

Reminder: `aws cloudtrail lookup-events` will stay empty no matter how many
times you run this — that command reads Floci's (nonexistent) internal event
datastore, completely separate from the S3 files this script writes directly.

---

## 5. Terraform import

### How to figure out the resource type and ID yourself (without already knowing the answer)

`import.tf` in this repo already has the right resource types and IDs, but
the useful skill is knowing how to work that out from scratch against *any*
found resource, since you won't always have someone else's answer key.

**Step 1 — find out what actually exists, in plain AWS terms.**
```bash
aws s3 ls                                              # bucket names
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'   # instance identifiers
```
Terraform import IDs are almost always built from the same natural
identifiers the AWS CLI already shows you — a bucket name, an instance
identifier, an ARN. You're not inventing anything new here, just noting what
the resource is called.

**Step 2 — find the matching Terraform resource *type*.** Search the
Terraform Registry (`registry.terraform.io/providers/hashicorp/aws/latest/docs`)
for the AWS service name. The gotcha: one logical S3 bucket is modeled as
**many separate resource types** in the AWS provider, not one resource with
nested blocks — `aws_s3_bucket` (the bucket itself), `aws_s3_bucket_policy`,
`aws_s3_bucket_public_access_block`, `aws_s3_bucket_versioning`,
`aws_s3_bucket_server_side_encryption_configuration`,
`aws_s3_bucket_logging`, and more. Each one needs its **own** `import` block
— this is exactly why 5 buckets in this lab needed 15 import blocks (3 per
bucket), not 5.

**Step 3 — check that resource type's own "Import" section in the docs.**
Every resource page on the Registry has an Import section near the bottom
showing the exact ID format, e.g.:
```
% terraform import aws_s3_bucket.bucket bucket-name
% terraform import aws_db_instance.default mydb-rds-instance
```
The ID format is **not consistent across resource types** — don't assume.
Some are just a name (`aws_s3_bucket`, `aws_db_instance`,
`aws_db_parameter_group`, `aws_cloudwatch_log_group` — all of these happen to
use a plain name/identifier, which is why every `id` in this lab's
`import.tf` looks similar). Others need composite IDs
(`bucket,key` for some S3 sub-resources in older provider versions;
`account-id/thing-name` patterns elsewhere) — always check the specific
resource's docs page, never assume the pattern from a different resource
type carries over.

**Step 4 — verify the ID format before committing to it.** The fastest way
to check you got it right is a throwaway classic import:
```bash
terraform import aws_s3_bucket.test_only acme-corp-hr-records
```
If the ID is wrong, Terraform errors immediately and clearly (e.g.,
`Cannot import non-existent remote object` — the exact error this lab hit
early on for the RDS/bucket sub-resources, which was actually correct
behavior telling us the resource genuinely didn't exist yet, not a wrong ID
format). A successful import here confirms the ID before you write the
permanent `import { }` block and remove the throwaway one
(`terraform state rm aws_s3_bucket.test_only` if you don't want to keep it).

### `import.tf`

16 blocks: 5 buckets × (`aws_s3_bucket` + `aws_s3_bucket_public_access_block`
+ `aws_s3_bucket_policy`) + 1 `aws_db_instance`:
```hcl
import {
  to = aws_db_instance.users_db
  id = "acme-corp-users-db"
}
import {
  to = aws_s3_bucket.hr_records
  id = "acme-corp-hr-records"
}
import {
  to = aws_s3_bucket_public_access_block.hr_records
  id = "acme-corp-hr-records"
}
import {
  to = aws_s3_bucket_policy.hr_records
  id = "acme-corp-hr-records"
}
# ...repeat for customer_support, payroll_exports, marketing_leads, legacy_backups
```

### Init and generate config

```bash
terraform init
terraform plan -generate-config-out=generated.tf
```

**A real quirk you'll hit:** the RDS resource fails generation with
```
Error: Not enough list items
Attribute domain_dns_ips requires 2 item minimum, but config has only 0 declared.
```
The generator writes `domain_dns_ips = []` (irrelevant since `domain = null`),
but the schema requires ≥2 items for that attribute whenever it's present at
all, empty or not. Fix: delete the `domain_dns_ips = []` line from
`generated.tf` entirely — omitting it satisfies the schema. Re-run the plan.

### Apply

```bash
terraform apply
```
Expected: `Apply complete! Resources: 16 imported, 0 added, 0 changed, 0 destroyed.`

```bash
terraform plan   # confirm: "No changes. Your infrastructure matches the configuration."
```

---

## 6. Remediate every GAPS.md finding — without destroying anything live

See `GAPS.md` for the full analysis. Summary of what `hardening.tf` /
`generated.tf` actually apply:

**S3 (all 5 buckets, zero downtime):**
- `aws_s3_bucket_public_access_block` — all 4 flags flipped to `true`
- `aws_s3_bucket_policy` — public-read statement **replaced** with a
  `Deny`/`aws:SecureTransport` statement
- `aws_s3_bucket_server_side_encryption_configuration` + a customer-managed
  `aws_kms_key` — SSE-KMS encryption
- `aws_s3_bucket_versioning` — enabled
- `aws_s3_bucket_logging` — configured (Floci won't deliver the objects, but
  this is still the correct real-AWS remediation)
- `tags` on each `aws_s3_bucket` — `data-classification = "pii"`

**RDS (no destructive changes):**
- `iam_database_authentication_enabled = true` — genuinely persists, verified
- `aws_db_parameter_group` with `rds.force_ssl = 1`, plus
  `auto_minor_version_upgrade`, `deletion_protection`,
  `backup_retention_period = 7`, `enabled_cloudwatch_logs_exports =
  ["postgresql"]` — all textbook-correct, but **confirmed by direct testing
  not to persist on this Floci version** (a `modify-db-instance` call
  reports success, then `describe-db-instances` shows every field reverted).
  Not a config mistake — a proven emulator limitation.
- `storage_encrypted` / `kms_key_id` — **intentionally left `false`/unset.**
  Both are `ForceNew`: setting them destroys and recreates a live database.
  We made this mistake once in building this lab (watched
  `terraform destroy` a live RDS instance for over a minute to "fix"
  encryption) before correcting course. The real remediation is a
  snapshot → encrypted-copy → restore → cutover migration, kept as its own
  reviewed change — see GAPS.md's SC-28 section for the exact resources.

```bash
terraform plan    # review every change
terraform apply
```
Expect `0 destroyed` for this apply. If you ever see `-/+ destroy and then
create replacement` on `aws_db_instance.users_db`, stop and check what
attribute is forcing it — `storage_encrypted`/`kms_key_id` should never be
part of a routine apply against a live instance.

---

## 7. Scan with tfsec — and remediate what it finds

`verify.sh` checks that the specific GAPS.md findings got fixed; tfsec is a
second opinion that scans the whole config for anything GAPS.md didn't
already catch.

### Running it without HCL parse errors

```bash
tfsec -m HIGH --ignore-hcl-errors
```

Without `--ignore-hcl-errors`, tfsec v1.28.14 aborts the entire scan:
```
Error: scan failed: .../import.tf:7,1-7: Unsupported block type; Blocks of type "import" are not expected here., and 15 other diagnostic(s)
```
This is a tfsec parser limitation, not a real problem — its HCL parser
predates Terraform's native `import {}` block (a 1.5+ feature) and doesn't
recognize the syntax at all. `--ignore-hcl-errors` tells tfsec to skip files
it can't parse instead of failing the whole run. `import.tf` has no
security-relevant content anyway (it's just resource-to-ID mappings), so
skipping it costs nothing.

### What it found here, and how each was fixed

First run (right after Part 6's hardening) turned up 7 HIGH findings:

| Rule ID | Resource | Fix |
|---|---|---|
| `aws-s3-block-public-acls` | `aws_s3_bucket.access_logs` | Added `aws_s3_bucket_public_access_block` (all 4 flags `true`) |
| `aws-s3-block-public-policy` | `aws_s3_bucket.access_logs` | Same resource, same fix |
| `aws-s3-ignore-public-acls` | `aws_s3_bucket.access_logs` | Same resource, same fix |
| `aws-s3-no-public-buckets` | `aws_s3_bucket.access_logs` | Same resource, same fix |
| `aws-s3-encryption-customer-key` | `aws_s3_bucket.access_logs` | Added `aws_s3_bucket_server_side_encryption_configuration` reusing the existing `aws_kms_key.pii` CMK |
| `aws-rds-encrypt-instance-storage-data` | `aws_db_instance.users_db` | **Not fixed, on purpose** — this is the same SC-28 finding from Part 6/GAPS.md; `storage_encrypted` is `ForceNew` and fixing it here would destroy the live database |

The pattern: all 6 S3 findings were about `acme-corp-access-logs` — the log
destination bucket added in `hardening.tf` for AU-2/AU-3/AU-12 never got the
same baseline hardening as the 5 PII buckets it logs for. Applied fix:

```hcl
resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.pii.arn
    }
  }
}
```

```bash
terraform apply   # 2 added, 2 changed, 0 destroyed
tfsec -m HIGH --ignore-hcl-errors   # 44 passed, 1 potential problem (the RDS one, expected)
```

**Rule of thumb going forward:** any time hardening is added to some buckets
but not others (a new log-destination bucket, a new artifacts bucket, etc.),
re-run tfsec — it catches exactly this kind of "we hardened the buckets we
were thinking about, not the one we just created as a side effect."

---

## 8. Validate everything

```bash
bash verify.sh
```
Checks, in order: Terraform state completeness, zero unexpected drift, every
S3 control (PAB, policy, encryption, versioning, logging, tags) on all 5
buckets, and the two verifiable RDS controls (IAM auth, public accessibility)
— with the 5 Floci-unenforceable RDS fields and the intentionally-skipped
encryption reported as `INFO`, not `FAIL`.

---

## 9. Evidence

Every command below was tested to actually produce a file — run any subset,
in any order, as many times as you like.

### Terraform state

```bash
terraform show -json | jq . > evidence/full_state.json
terraform state list > evidence/state_list.txt
```

### tfsec scan results

```bash
tfsec -m HIGH --ignore-hcl-errors --format json -O evidence/tfsec_results.json
tfsec -m HIGH --ignore-hcl-errors > evidence/tfsec_summary.txt 2>&1
```

### Per-bucket security config (proves the hardening, not just the intent)

```bash
for b in acme-corp-hr-records acme-corp-customer-support acme-corp-payroll-exports acme-corp-marketing-leads acme-corp-legacy-backups; do
  aws s3api get-bucket-policy --bucket "$b" --query Policy --output text > "evidence/${b}_policy.json"
  aws s3api get-public-access-block --bucket "$b" > "evidence/${b}_pab.json"
  aws s3api get-bucket-encryption --bucket "$b" > "evidence/${b}_encryption.json"
  aws s3api get-bucket-versioning --bucket "$b" > "evidence/${b}_versioning.json"
  aws s3api get-bucket-tagging --bucket "$b" > "evidence/${b}_tags.json"
done
```

### RDS state and seeded data

```bash
aws rds describe-db-instances --db-instance-identifier acme-corp-users-db > evidence/rds_describe.json
PGPASSWORD='DemoPass123!' psql -h 172.18.0.2 -p 7001 -U appadmin -d appdb -c "SELECT * FROM users;" > evidence/rds_seeded_rows.txt
```
(swap in the current endpoint from `rds_describe.json` if it's changed)

### Access-audit logs (both real CloudWatch and synthetic CloudTrail)

```bash
# most recent CloudWatch Logs stream
STREAM=$(aws logs describe-log-streams --log-group-name /acme-corp/pii-access-audit \
  --order-by LastEventTime --descending --query 'logStreams[0].logStreamName' --output text)
aws logs get-log-events --log-group-name /acme-corp/pii-access-audit \
  --log-stream-name "$STREAM" > evidence/cloudwatch_access_log.json

# list every synthetic CloudTrail file generated so far
aws s3 ls s3://week2-cloudtrail-logs/AWSLogs/000000000000/CloudTrail/us-east-1/ \
  --recursive > evidence/cloudtrail_files.txt

# pull the most recent one down decompressed
LATEST=$(sort evidence/cloudtrail_files.txt | tail -1 | awk '{print $4}')
aws s3 cp "s3://week2-cloudtrail-logs/$LATEST" - | zcat > evidence/cloudtrail_latest.json
```

### `verify.sh` output

```bash
bash verify.sh > evidence/verify_output.txt 2>&1
```

---

## 10. Teardown

```bash
terraform destroy
```
Since this exercise starts from resources that predate Terraform, `destroy`
here removes the *original* found resources too — expected, not a bug.
`deletion_protection` on the RDS instance may block this if it actually took
effect; if so, disable it first (`terraform apply` after setting
`deletion_protection = false`, or `aws rds modify-db-instance
--no-deletion-protection --apply-immediately` directly).

---

## 11. Commit and push to GitHub

`week-2/` lives inside the `demo-test-2` repo — no separate `git init` here.
```bash
cd /home/kali/floci/terraform-lesson-project/demo-test-2
git add week-2/
git commit -m "Add week-2: terraform import + NIST 800-53 remediation demo"
git push   # or: gh repo create ... --push, if this needs its own remote
```
`.gitignore` at the repo root already excludes `*.tfstate`, `*.tfstate.*`,
`*.terraform/`, and `*.hcl`.

---

## Summary of what this class demonstrated

1. Infrastructure can exist without ever touching Terraform — `import` blocks
   + `-generate-config-out` bring it under management without recreate/destroy.
2. A clean import means `terraform plan` shows zero changes immediately after
   — that's the pass/fail signal, not just "did apply succeed."
3. Not every remediation is safe to apply the same way: 6 of 7 RDS findings
   are safe in-place fixes; encryption-at-rest is `ForceNew` and requires a
   deliberate snapshot/restore migration, never a routine `apply`. We made
   that mistake once, on purpose, so you don't have to.
4. Not every AWS feature is emulated equally, and don't take a single quick
   test as proof — CloudTrail's trail *management* API works but capture
   doesn't; a single early psql test wrongly suggested RDS wasn't real; a
   single early `describe-db-instances` call wrongly suggested a nonexistent
   RDS instance was a valid, successful lookup. Verify twice before writing
   it down.
