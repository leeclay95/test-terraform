# __generated__ by Terraform
# Please review these resources and move them into your main configuration files.

# __generated__ by Terraform from "acme-corp-customer-support"
resource "aws_s3_bucket_public_access_block" "customer_support" {
  block_public_acls       = false
  block_public_policy     = false
  bucket                  = "acme-corp-customer-support"
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# __generated__ by Terraform from "acme-corp-customer-support"
resource "aws_s3_bucket_policy" "customer_support" {
  bucket = "acme-corp-customer-support"
  policy = jsonencode({
    Statement = [{
      Action    = "s3:GetObject"
      Effect    = "Allow"
      Principal = "*"
      Resource  = "arn:aws:s3:::acme-corp-customer-support/*"
      Sid       = "PublicReadGetObject"
    }]
    Version = "2012-10-17"
  })
}

# __generated__ by Terraform from "acme-corp-legacy-backups"
resource "aws_s3_bucket_public_access_block" "legacy_backups" {
  block_public_acls       = false
  block_public_policy     = false
  bucket                  = "acme-corp-legacy-backups"
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# __generated__ by Terraform from "acme-corp-marketing-leads"
resource "aws_s3_bucket_public_access_block" "marketing_leads" {
  block_public_acls       = false
  block_public_policy     = false
  bucket                  = "acme-corp-marketing-leads"
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# __generated__ by Terraform from "acme-corp-legacy-backups"
resource "aws_s3_bucket_policy" "legacy_backups" {
  bucket = "acme-corp-legacy-backups"
  policy = jsonencode({
    Statement = [{
      Action    = "s3:GetObject"
      Effect    = "Allow"
      Principal = "*"
      Resource  = "arn:aws:s3:::acme-corp-legacy-backups/*"
      Sid       = "PublicReadGetObject"
    }]
    Version = "2012-10-17"
  })
}

# __generated__ by Terraform from "acme-corp-hr-records"
resource "aws_s3_bucket_public_access_block" "hr_records" {
  block_public_acls       = true
  block_public_policy     = true
  bucket                  = "acme-corp-hr-records"
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# __generated__ by Terraform from "acme-corp-hr-records"
resource "aws_s3_bucket_policy" "hr_records" {
  bucket = "acme-corp-hr-records"
  policy = jsonencode({
    Statement = [{
      Action    = "s3:GetObject"
      Effect    = "Allow"
      Principal = "*"
      Resource  = "arn:aws:s3:::acme-corp-hr-records/*"
      Sid       = "PublicReadGetObject"
    }]
    Version = "2012-10-17"
  })
}

# __generated__ by Terraform from "acme-corp-payroll-exports"
resource "aws_s3_bucket_public_access_block" "payroll_exports" {
  block_public_acls       = false
  block_public_policy     = false
  bucket                  = "acme-corp-payroll-exports"
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# __generated__ by Terraform from "acme-corp-marketing-leads"
resource "aws_s3_bucket_policy" "marketing_leads" {
  bucket = "acme-corp-marketing-leads"
  policy = jsonencode({
    Statement = [{
      Action    = "s3:GetObject"
      Effect    = "Allow"
      Principal = "*"
      Resource  = "arn:aws:s3:::acme-corp-marketing-leads/*"
      Sid       = "PublicReadGetObject"
    }]
    Version = "2012-10-17"
  })
}

# __generated__ by Terraform from "acme-corp-payroll-exports"
resource "aws_s3_bucket_policy" "payroll_exports" {
  bucket = "acme-corp-payroll-exports"
  policy = jsonencode({
    Statement = [{
      Action    = "s3:GetObject"
      Effect    = "Allow"
      Principal = "*"
      Resource  = "arn:aws:s3:::acme-corp-payroll-exports/*"
      Sid       = "PublicReadGetObject"
    }]
    Version = "2012-10-17"
  })
}

# __generated__ by Terraform from "acme-corp-hr-records"
resource "aws_s3_bucket" "hr_records" {
  bucket              = "acme-corp-hr-records"
  force_destroy       = null
  object_lock_enabled = false
  tags                = {}
  tags_all            = {}
}

# __generated__ by Terraform from "acme-corp-marketing-leads"
resource "aws_s3_bucket" "marketing_leads" {
  bucket              = "acme-corp-marketing-leads"
  force_destroy       = null
  object_lock_enabled = false
  tags                = {}
  tags_all            = {}
}

# __generated__ by Terraform from "acme-corp-customer-support"
resource "aws_s3_bucket" "customer_support" {
  bucket              = "acme-corp-customer-support"
  force_destroy       = null
  object_lock_enabled = false
  tags                = {}
  tags_all            = {}
}

# __generated__ by Terraform from "acme-corp-payroll-exports"
resource "aws_s3_bucket" "payroll_exports" {
  bucket              = "acme-corp-payroll-exports"
  force_destroy       = null
  object_lock_enabled = false
  tags                = {}
  tags_all            = {}
}

# __generated__ by Terraform
resource "aws_db_instance" "users_db" {
  allocated_storage           = 20
  allow_major_version_upgrade = null
  apply_immediately           = null
  auto_minor_version_upgrade  = false
  availability_zone           = "us-east-1c"
  backup_retention_period     = 0
  backup_window               = "04:00-06:00"
  copy_tags_to_snapshot       = false
  custom_iam_instance_profile = null
  customer_owned_ip_enabled   = false
  db_name                     = "appdb"
  db_subnet_group_name        = "default"
  dedicated_log_volume        = false
  delete_automated_backups    = true
  deletion_protection         = false
  domain                      = null
  domain_auth_secret_arn      = null
  # domain_dns_ips                        = []
  domain_iam_role_name                  = null
  domain_ou                             = null
  enabled_cloudwatch_logs_exports       = []
  engine                                = "postgres"
  engine_version                        = "16.3"
  final_snapshot_identifier             = null
  iam_database_authentication_enabled   = false
  identifier                            = "acme-corp-users-db"
  instance_class                        = "db.t3.micro"
  iops                                  = 0
  maintenance_window                    = "mon:00:00-mon:03:00"
  manage_master_user_password           = null
  max_allocated_storage                 = 0
  monitoring_interval                   = 0
  multi_az                              = false
  parameter_group_name                  = "default.postgres16"
  password                              = null # sensitive
  password_wo                           = null # sensitive
  password_wo_version                   = null
  performance_insights_enabled          = false
  performance_insights_retention_period = 0
  port                                  = 7002
  publicly_accessible                   = false
  replicate_source_db                   = null
  skip_final_snapshot                   = true
  storage_encrypted                     = false
  storage_throughput                    = 0
  storage_type                          = "gp2"
  tags = {
    data-classification = "pii"
    demo                = "week-2-import"
    owner               = "acme-corp-app-team"
  }
  tags_all = {
    data-classification = "pii"
    demo                = "week-2-import"
    owner               = "acme-corp-app-team"
  }
  upgrade_storage_config = null
  username               = "appadmin"
  vpc_security_group_ids = ["sg-00000000"]

  # Floci assigns the RDS AZ at random (usually us-east-1a), so a pinned AZ
  # here reads as drift every apply and forces a destroy/recreate — which wipes
  # the backing container's volume (and the seeded users table). Ignore AZ drift
  # so applies leave the instance, and its data, in place.
  lifecycle {
    ignore_changes = [availability_zone]
  }
}

# __generated__ by Terraform from "acme-corp-legacy-backups"
resource "aws_s3_bucket" "legacy_backups" {
  bucket              = "acme-corp-legacy-backups"
  force_destroy       = null
  object_lock_enabled = false
  tags                = {}
  tags_all            = {}
}
