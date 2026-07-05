# Originally written by `terraform plan -generate-config-out=generated.tf` from
# the as-found (public, unencrypted) resources — see git history for that
# original state. Rewritten here with every non-destructive GAPS.md remediation
# applied. New supporting resources (KMS key, encryption/versioning/logging
# configs, the RDS parameter group) live in hardening.tf.

resource "aws_s3_bucket" "hr_records" {
  bucket              = "acme-corp-hr-records"
  force_destroy       = null
  object_lock_enabled = false
  tags = {
    "data-classification" = "pii"
    "owner"                = "acme-corp-app-team"
  }
  tags_all = {
    "data-classification" = "pii"
    "owner"                = "acme-corp-app-team"
  }
}

resource "aws_s3_bucket" "customer_support" {
  bucket              = "acme-corp-customer-support"
  force_destroy       = null
  object_lock_enabled = false
  tags = {
    "data-classification" = "pii"
    "owner"                = "acme-corp-app-team"
  }
  tags_all = {
    "data-classification" = "pii"
    "owner"                = "acme-corp-app-team"
  }
}

resource "aws_s3_bucket" "payroll_exports" {
  bucket              = "acme-corp-payroll-exports"
  force_destroy       = null
  object_lock_enabled = false
  tags = {
    "data-classification" = "pii"
    "owner"                = "acme-corp-app-team"
  }
  tags_all = {
    "data-classification" = "pii"
    "owner"                = "acme-corp-app-team"
  }
}

resource "aws_s3_bucket" "marketing_leads" {
  bucket              = "acme-corp-marketing-leads"
  force_destroy       = null
  object_lock_enabled = false
  tags = {
    "data-classification" = "pii"
    "owner"                = "acme-corp-app-team"
  }
  tags_all = {
    "data-classification" = "pii"
    "owner"                = "acme-corp-app-team"
  }
}

resource "aws_s3_bucket" "legacy_backups" {
  bucket              = "acme-corp-legacy-backups"
  force_destroy       = null
  object_lock_enabled = false
  tags = {
    "data-classification" = "pii"
    "owner"                = "acme-corp-app-team"
  }
  tags_all = {
    "data-classification" = "pii"
    "owner"                = "acme-corp-app-team"
  }
}

# --- AC-3 / AC-6: public access block, all 4 flags flipped true ---

resource "aws_s3_bucket_public_access_block" "hr_records" {
  bucket                  = aws_s3_bucket.hr_records.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "customer_support" {
  bucket                  = aws_s3_bucket.customer_support.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "payroll_exports" {
  bucket                  = aws_s3_bucket.payroll_exports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "marketing_leads" {
  bucket                  = aws_s3_bucket.marketing_leads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "legacy_backups" {
  bucket                  = aws_s3_bucket.legacy_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- SC-8 / SC-23: public-read policy replaced with a TLS-enforcing deny ---

resource "aws_s3_bucket_policy" "hr_records" {
  bucket     = aws_s3_bucket.hr_records.id
  depends_on = [aws_s3_bucket_public_access_block.hr_records]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.hr_records.arn, "${aws_s3_bucket.hr_records.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_policy" "customer_support" {
  bucket     = aws_s3_bucket.customer_support.id
  depends_on = [aws_s3_bucket_public_access_block.customer_support]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.customer_support.arn, "${aws_s3_bucket.customer_support.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_policy" "payroll_exports" {
  bucket     = aws_s3_bucket.payroll_exports.id
  depends_on = [aws_s3_bucket_public_access_block.payroll_exports]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.payroll_exports.arn, "${aws_s3_bucket.payroll_exports.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_policy" "marketing_leads" {
  bucket     = aws_s3_bucket.marketing_leads.id
  depends_on = [aws_s3_bucket_public_access_block.marketing_leads]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.marketing_leads.arn, "${aws_s3_bucket.marketing_leads.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_policy" "legacy_backups" {
  bucket     = aws_s3_bucket.legacy_backups.id
  depends_on = [aws_s3_bucket_public_access_block.legacy_backups]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.legacy_backups.arn, "${aws_s3_bucket.legacy_backups.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# --- RDS: the 6 GAPS.md findings that can be fixed WITHOUT destroying the
# instance. storage_encrypted/kms_key_id are intentionally left false/unset —
# both are ForceNew on this resource, so setting them destroys and recreates
# a live database. That finding (SC-28) is tracked in GAPS.md but requires a
# snapshot -> encrypted copy -> restore -> cutover migration, not a routine
# `terraform apply`. See GAPS.md for details.

resource "aws_db_instance" "users_db" {
  allocated_storage                    = 20
  apply_immediately                    = true
  auto_minor_version_upgrade           = true
  availability_zone                    = "us-east-1c"
  backup_retention_period              = 7
  backup_window                        = "04:00-06:00"
  copy_tags_to_snapshot                = false
  customer_owned_ip_enabled            = false
  db_name                              = "appdb"
  db_subnet_group_name                 = "default"
  dedicated_log_volume                 = false
  delete_automated_backups              = true
  deletion_protection                   = true
  enabled_cloudwatch_logs_exports       = ["postgresql"]
  engine                                = "postgres"
  engine_version                        = "16.3"
  iam_database_authentication_enabled   = true
  identifier                            = "acme-corp-users-db"
  instance_class                        = "db.t3.micro"
  iops                                   = 0
  maintenance_window                    = "mon:00:00-mon:03:00"
  max_allocated_storage                 = 0
  monitoring_interval                   = 0
  multi_az                              = false
  parameter_group_name                  = aws_db_parameter_group.users_db_fips.name
  password                              = "DemoPass123!" # sensitive; matches scripts/02-create-rds.sh
  performance_insights_enabled          = false
  performance_insights_retention_period = 0
  publicly_accessible                   = false
  skip_final_snapshot                   = true
  # storage_encrypted / kms_key_id intentionally NOT set to true here: both are
  # ForceNew on this resource, so setting them forces a destroy+recreate of a
  # live database. See GAPS.md SC-28 for why this finding is tracked but not
  # applied via a routine `terraform apply` — it needs a snapshot -> encrypted
  # copy -> restore -> cutover migration instead, kept as its own reviewed change.
  storage_encrypted                     = false
  storage_throughput                    = 0
  storage_type                          = "gp2"
  tags = {
    "data-classification" = "pii"
    "owner"                = "acme-corp-app-team"
    "demo"                 = "week-2-import"
  }
  tags_all = {
    "data-classification" = "pii"
    "owner"                = "acme-corp-app-team"
    "demo"                 = "week-2-import"
  }
  username               = "appadmin"
  vpc_security_group_ids = ["sg-00000000"]
}
