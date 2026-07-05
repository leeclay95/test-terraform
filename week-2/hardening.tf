# New resources needed to remediate GAPS.md findings that aren't just field
# changes on an already-imported resource (see generated.tf for those).

# --- SC-28 / SC-13: encryption at rest, S3 ---

resource "aws_kms_key" "pii" {
  description             = "CMK for PII bucket encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "hr_records" {
  bucket = aws_s3_bucket.hr_records.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.pii.arn
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "customer_support" {
  bucket = aws_s3_bucket.customer_support.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.pii.arn
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "payroll_exports" {
  bucket = aws_s3_bucket.payroll_exports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.pii.arn
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "marketing_leads" {
  bucket = aws_s3_bucket.marketing_leads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.pii.arn
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "legacy_backups" {
  bucket = aws_s3_bucket.legacy_backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.pii.arn
    }
  }
}

# --- CM-6: versioning ---

resource "aws_s3_bucket_versioning" "hr_records" {
  bucket = aws_s3_bucket.hr_records.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "customer_support" {
  bucket = aws_s3_bucket.customer_support.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "payroll_exports" {
  bucket = aws_s3_bucket.payroll_exports.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "marketing_leads" {
  bucket = aws_s3_bucket.marketing_leads.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "legacy_backups" {
  bucket = aws_s3_bucket.legacy_backups.id
  versioning_configuration { status = "Enabled" }
}

# --- AU-2 / AU-3 / AU-12: access logging ---
# NOTE: Floci accepts put-bucket-logging but doesn't deliver log objects
# (confirmed by hand, see WALKTHROUGH.md 4b) — this is still the textbook
# remediation for real AWS, applied and documented regardless.

resource "aws_s3_bucket" "access_logs" {
  bucket = "acme-corp-access-logs"
}

# The log destination bucket itself needs the same baseline hardening as the
# buckets it's logging for — tfsec correctly flagged this as missing
# (aws-s3-block-public-acls, aws-s3-block-public-policy,
# aws-s3-ignore-public-acls, aws-s3-no-public-buckets,
# aws-s3-encryption-customer-key).
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

# Real audit trail: since neither S3 access logging nor CloudTrail data events
# are actually deliverable in this environment (both confirmed by hand — see
# WALKTHROUGH.md section 4), scripts/03-cloudwatch-access-log.sh publishes
# every access attempt directly to this real CloudWatch Logs group via
# `aws logs put-log-events`. This is a genuine, verifiable AWS service (not a
# local file) — a common real-world pattern for audit events that aren't
# captured automatically by CloudTrail.
resource "aws_cloudwatch_log_group" "pii_access_audit" {
  name              = "/acme-corp/pii-access-audit"
  retention_in_days = 90
}

resource "aws_s3_bucket_logging" "hr_records" {
  bucket        = aws_s3_bucket.hr_records.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "hr-records/"
}

resource "aws_s3_bucket_logging" "customer_support" {
  bucket        = aws_s3_bucket.customer_support.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "customer-support/"
}

resource "aws_s3_bucket_logging" "payroll_exports" {
  bucket        = aws_s3_bucket.payroll_exports.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "payroll-exports/"
}

resource "aws_s3_bucket_logging" "marketing_leads" {
  bucket        = aws_s3_bucket.marketing_leads.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "marketing-leads/"
}

resource "aws_s3_bucket_logging" "legacy_backups" {
  bucket        = aws_s3_bucket.legacy_backups.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "legacy-backups/"
}

# --- RDS: SC-13/SC-8/SC-23 (FIPS) parameter group ---
# NOTE: no aws_kms_key here for RDS (SC-28) — storage_encrypted/kms_key_id are
# ForceNew, so applying them would destroy and recreate a live database. That
# finding is intentionally NOT remediated by this file; see GAPS.md SC-28 for
# the real migration path (snapshot -> encrypted copy -> restore -> cutover).

resource "aws_db_parameter_group" "users_db_fips" {
  name   = "acme-corp-users-db-fips"
  family = "postgres16"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
}
