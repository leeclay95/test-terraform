# Import blocks for the 5 "found" PUBLIC PII buckets (bucket + public access
# block + policy) and the "found" RDS instance. Every resource here was created
# by hand with zero security hardening — see GAPS.md for the full NIST 800-53
# gap analysis and the Terraform remediation for each finding. The goal is for
# students to find these gaps themselves and fix them with Terraform.

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

import {
  to = aws_s3_bucket.customer_support
  id = "acme-corp-customer-support"
}
import {
  to = aws_s3_bucket_public_access_block.customer_support
  id = "acme-corp-customer-support"
}
import {
  to = aws_s3_bucket_policy.customer_support
  id = "acme-corp-customer-support"
}

import {
  to = aws_s3_bucket.payroll_exports
  id = "acme-corp-payroll-exports"
}
import {
  to = aws_s3_bucket_public_access_block.payroll_exports
  id = "acme-corp-payroll-exports"
}
import {
  to = aws_s3_bucket_policy.payroll_exports
  id = "acme-corp-payroll-exports"
}

import {
  to = aws_s3_bucket.marketing_leads
  id = "acme-corp-marketing-leads"
}
import {
  to = aws_s3_bucket_public_access_block.marketing_leads
  id = "acme-corp-marketing-leads"
}
import {
  to = aws_s3_bucket_policy.marketing_leads
  id = "acme-corp-marketing-leads"
}

import {
  to = aws_s3_bucket.legacy_backups
  id = "acme-corp-legacy-backups"
}
import {
  to = aws_s3_bucket_public_access_block.legacy_backups
  id = "acme-corp-legacy-backups"
}
import {
  to = aws_s3_bucket_policy.legacy_backups
  id = "acme-corp-legacy-backups"
}
