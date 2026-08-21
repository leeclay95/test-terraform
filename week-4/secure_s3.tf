# ============================================================================
# SECURE EXAMPLE — the "after" half of the week-4 lesson.
#
# THIS IS THE FILE THE PIPELINE SCANS. .github/workflows/tfsec.yml runs
#
#     tfsec week-4 --minimum-severity HIGH
#
# on every pull request into main, and week-4 holds exactly one *.tf: this one.
# A single HIGH finding here fails the check, and once the check is required in
# branch protection, that failure blocks the merge.
#
# Same bucket as insecure_s3.tf.example, with every HIGH finding remediated:
#
#   encryption      SSE-KMS with a customer-managed key, rotation enabled
#   public access   all four public access block switches on, ACLs disabled
#   versioning      on, so an overwrite or delete is recoverable
#   access logging  writes to a separate log bucket
#
# tfsec reports 0 findings here at ANY severity.
# ============================================================================

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

# --- Customer-managed key ---------------------------------------------------
# A CMK rather than the AWS-managed aws/s3 key: we control the key policy, we
# can revoke it, and rotation is provable.
resource "aws_kms_key" "s3" {
  description             = "CMK for demo-bucket encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "s3" {
  name          = "alias/demo-bucket-s3"
  target_key_id = aws_kms_key.s3.key_id
}

# --- Data bucket ------------------------------------------------------------
resource "aws_s3_bucket" "demo" {
  bucket = "demo-bucket"
}

resource "aws_s3_bucket_ownership_controls" "demo" {
  bucket = aws_s3_bucket.demo.id

  rule {
    object_ownership = "BucketOwnerEnforced" # disables ACLs entirely
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "demo" {
  bucket = aws_s3_bucket.demo.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    # Cuts KMS API calls (and cost) without weakening the encryption.
    bucket_key_enabled = true
  }
}

# All four switches on. This is what tfsec's four public-access HIGH checks want.
resource "aws_s3_bucket_public_access_block" "demo" {
  bucket = aws_s3_bucket.demo.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "demo" {
  bucket = aws_s3_bucket.demo.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_logging" "demo" {
  bucket        = aws_s3_bucket.demo.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access/demo-bucket/"
}

# --- Log bucket -------------------------------------------------------------
# Hardened the same way as the data bucket, minus access logging on itself.
#
# Documented exception: a log bucket that logs to itself is an infinite loop, so
# the accepted pattern is to leave the final sink unlogged. The suppression must
# sit on the line immediately above the resource or tfsec ignores the ignore.
#tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "logs" {
  bucket = "demo-bucket-logs"
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    object_ownership = "BucketOwnerPreferred" # log delivery still writes ACLs
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}
