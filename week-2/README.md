# Week 2 — Terraform Import + NIST 800-53 Remediation

Week 1 showed the clean path: write Terraform first, then apply. Week 2 shows
the messier, far more common reality — infrastructure that already exists
(created by hand, actively insecure) that needs to be brought under Terraform
**and** hardened, without downtime, without destroying live data.

**Start here: [`WALKTHROUGH.md`](./WALKTHROUGH.md)** — the full, copy-paste
class script from environment setup through teardown, including real RDS
access commands, real CloudWatch Logs audit logging, and the Terraform import
+ hardening flow.

**The findings: [`GAPS.md`](./GAPS.md)** — every NIST 800-53 control gap on
the 5 "found" S3 buckets and the RDS instance, what was fixed, what's
Terraform-correct but not enforceable in this lab environment (documented
honestly, not glossed over), and why encryption-at-rest was deliberately
*not* applied via a routine `terraform apply` (it would destroy a live
database — see that section for the real migration pattern).

## Folder layout

```
week-2/
  scripts/
    01-create-buckets.sh          — creates the 5 "found" public PII buckets
    02-create-rds.sh              — creates the "found" RDS instance, seeds real data
    03-cloudwatch-access-log.sh   — real audit logging via CloudWatch Logs
  main.tf                          — provider block
  import.tf                        — import blocks for all 16 found resources
  generated.tf                     — resource config, hardened per GAPS.md
  hardening.tf                     — net-new resources (KMS keys, encryption/
                                      versioning/logging configs, RDS parameter
                                      group, CloudWatch log group)
  verify.sh                        — checks every control's actual state
  GAPS.md                          — the NIST 800-53 findings and remediation
  WALKTHROUGH.md                   — full class walkthrough
  evidence/                        — captured output for the write-up
```

## Quickest path to "does it still work"

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
unset AWS_PROFILE

terraform plan     # expect: only the known RDS Floci-limitation drift, 0 destroy
bash verify.sh     # expect: all PASS except documented INFO lines
```
