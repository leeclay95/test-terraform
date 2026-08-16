# ============================================================================
# INSECURE EXAMPLE — do not copy this into anything real.
#
# The "before" half of the week-4 lesson. Every problem below is deliberate and
# is caught by tfsec at HIGH severity:
#
#   aws-s3-enable-bucket-encryption   no server-side encryption at all
#   aws-s3-encryption-customer-key    no customer-managed KMS key
#   aws-s3-block-public-acls          public access block lets public ACLs through
#   aws-s3-block-public-policy        public access block lets public policies through
#   aws-s3-ignore-public-acls         existing public ACLs are honoured
#   aws-s3-no-public-buckets          the bucket can be made fully public
#   aws-s3-no-public-access-with-acl  the ACL itself is public-read
#
# WHY THE .example SUFFIX: the pipeline runs `tfsec week-4`, and tfsec parses
# every *.tf in a directory as one module. Named insecure_s3.tf this would be
# scanned alongside secure_s3.tf, both would declare aws_s3_bucket.demo, and the
# collision would fail every PR for reasons unrelated to the change under review.
# A gate that is red by default gets switched off within a week.
#
# That is worth sitting with: in Terraform there is no such thing as a .tf file
# that is "only an example". If it is in the directory, it is the config.
#
# The exercise in WALKTHROUGH.md is to copy this over week-4/secure_s3.tf on a
# branch and watch CI block the merge.
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

resource "aws_s3_bucket" "demo" {
  bucket = "demo-bucket"
}

# Anyone on the internet can list and read this bucket.
resource "aws_s3_bucket_acl" "demo" {
  bucket = aws_s3_bucket.demo.id
  acl    = "public-read"
}

# A public access block that blocks nothing is worse than none at all — it
# looks like a control in a review, but every switch is off.
resource "aws_s3_bucket_public_access_block" "demo" {
  bucket = aws_s3_bucket.demo.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# No aws_s3_bucket_server_side_encryption_configuration anywhere: objects land
# unencrypted, and there is no CMK, so no key rotation and no key-level audit.
