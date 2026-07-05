# Dynamic outputs: adding a 6th bucket only means adding one line to each
# local map below — the `for` expressions build the actual output values,
# no new output block needed per bucket.

locals {
  s3_buckets = {
    hr_records       = aws_s3_bucket.hr_records
    customer_support = aws_s3_bucket.customer_support
    payroll_exports  = aws_s3_bucket.payroll_exports
    marketing_leads  = aws_s3_bucket.marketing_leads
    legacy_backups   = aws_s3_bucket.legacy_backups
  }

  s3_bucket_pabs = {
    hr_records       = aws_s3_bucket_public_access_block.hr_records
    customer_support = aws_s3_bucket_public_access_block.customer_support
    payroll_exports  = aws_s3_bucket_public_access_block.payroll_exports
    marketing_leads  = aws_s3_bucket_public_access_block.marketing_leads
    legacy_backups   = aws_s3_bucket_public_access_block.legacy_backups
  }

  s3_bucket_policies = {
    hr_records       = aws_s3_bucket_policy.hr_records
    customer_support = aws_s3_bucket_policy.customer_support
    payroll_exports  = aws_s3_bucket_policy.payroll_exports
    marketing_leads  = aws_s3_bucket_policy.marketing_leads
    legacy_backups   = aws_s3_bucket_policy.legacy_backups
  }
}

output "s3_buckets" {
  description = "Every PII bucket's id/arn/domain/tags, public access block, and policy — keyed by logical name"
  value = {
    for name, bucket in local.s3_buckets : name => {
      bucket_name          = bucket.id
      arn                  = bucket.arn
      bucket_domain_name   = bucket.bucket_domain_name
      region               = bucket.region
      tags                 = bucket.tags_all
      public_access_block = {
        block_public_acls       = local.s3_bucket_pabs[name].block_public_acls
        block_public_policy     = local.s3_bucket_pabs[name].block_public_policy
        ignore_public_acls      = local.s3_bucket_pabs[name].ignore_public_acls
        restrict_public_buckets = local.s3_bucket_pabs[name].restrict_public_buckets
      }
      policy = local.s3_bucket_policies[name].policy
    }
  }
}

output "s3_bucket_names" {
  description = "Just the bucket names, as a flat list — handy for shell loops (for b in $(terraform output -json s3_bucket_names | jq -r '.[]'); do ...)"
  value       = [for b in local.s3_buckets : b.id]
}

output "rds_instance" {
  description = "acme-corp-users-db connection details and security-relevant configuration"
  value = {
    identifier                          = aws_db_instance.users_db.identifier
    arn                                  = aws_db_instance.users_db.arn
    endpoint                             = aws_db_instance.users_db.endpoint
    address                              = aws_db_instance.users_db.address
    port                                 = aws_db_instance.users_db.port
    engine                               = aws_db_instance.users_db.engine
    engine_version                       = aws_db_instance.users_db.engine_version
    instance_class                       = aws_db_instance.users_db.instance_class
    db_name                              = aws_db_instance.users_db.db_name
    username                             = aws_db_instance.users_db.username
    allocated_storage                    = aws_db_instance.users_db.allocated_storage
    storage_encrypted                    = aws_db_instance.users_db.storage_encrypted
    iam_database_authentication_enabled = aws_db_instance.users_db.iam_database_authentication_enabled
    deletion_protection                  = aws_db_instance.users_db.deletion_protection
    backup_retention_period              = aws_db_instance.users_db.backup_retention_period
    auto_minor_version_upgrade           = aws_db_instance.users_db.auto_minor_version_upgrade
    publicly_accessible                  = aws_db_instance.users_db.publicly_accessible
    parameter_group_name                 = aws_db_instance.users_db.parameter_group_name
    tags                                 = aws_db_instance.users_db.tags_all
  }
}

output "rds_psql_connection_string" {
  description = "Ready-to-run psql command against the seeded 'users' table. Marked sensitive since it embeds the password — run `terraform output rds_psql_connection_string` (without -json) to reveal it."
  value       = "PGPASSWORD=${var.rds_master_password} psql -h ${aws_db_instance.users_db.address} -p ${aws_db_instance.users_db.port} -U ${aws_db_instance.users_db.username} -d ${aws_db_instance.users_db.db_name} -c 'SELECT * FROM users;'"
  sensitive   = true
}
