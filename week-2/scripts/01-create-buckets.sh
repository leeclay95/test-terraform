#!/usr/bin/env bash
# Simulates "found infrastructure" — 5 S3 buckets created by hand (not by Terraform),
# each holding a synthetic PII export, made PUBLICLY READABLE (public access block
# disabled + a public-read bucket policy) with no other security configuration:
# no encryption, no versioning, no TLS enforcement, no logging, no tags. This is
# the deliberately-bad "someone needed to share a file and made the whole bucket
# public to do it" starting state — every finding it leaves is documented in
# GAPS.md, for students to find and fix with Terraform.
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

# Generate one synthetic (clearly fake) PII CSV per bucket — fake names, example.com
# emails, and 000-xx-xxxx SSNs (an invalid/reserved SSN prefix, never issued to a
# real person) so nothing here can be mistaken for real data.
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

echo "== Creating ${#BUCKETS[@]} PUBLIC S3 buckets with simulated PII =="
for bucket in "${BUCKETS[@]}"; do
  echo "--- $bucket ---"

  aws s3 mb "s3://$bucket"

  # Public access block must be disabled before a public bucket policy is allowed to apply
  aws s3api put-public-access-block \
    --bucket "$bucket" \
    --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

  policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicReadGetObject",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::$bucket/*"
  }]
}
EOF
)
  aws s3api put-bucket-policy --bucket "$bucket" --policy "$policy"

  csv="$WORKDIR/${bucket}.csv"
  generate_fake_pii "$csv" 25
  aws s3 cp "$csv" "s3://$bucket/export-$(date +%Y%m%d).csv"

  echo "  public access block: disabled (all 4 flags false)"
  echo "  bucket policy: public-read (Principal: *)"
  echo "  object uploaded: export-$(date +%Y%m%d).csv (25 synthetic rows)"
  echo "  no encryption, no versioning, no TLS enforcement, no logging, no tags set"
done

echo
echo "== Done. Verify the gaps yourself: =="
echo "  aws s3api get-bucket-policy --bucket acme-corp-hr-records --query Policy --output text | jq .   # -> public-read policy exists"
echo "  aws s3api get-public-access-block --bucket acme-corp-hr-records                                  # -> all 4 flags false"
echo "  aws s3api get-bucket-encryption --bucket acme-corp-hr-records                                     # -> ServerSideEncryptionConfigurationNotFoundError"
echo "  aws s3api get-bucket-versioning --bucket acme-corp-hr-records                                     # -> empty (not enabled)"
echo "  aws s3api get-bucket-logging --bucket acme-corp-hr-records                                        # -> empty (not enabled)"
