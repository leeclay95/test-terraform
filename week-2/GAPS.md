# GAPS.md — NIST 800-53 Gaps on the As-Built Infrastructure

Findings against the 5 S3 buckets and the RDS instance immediately after
`scripts/01-create-buckets.sh` and `scripts/02-create-rds.sh` were run — the
raw "found infrastructure" state, before any remediation. Every row was
verified against the live resources, not assumed.

## S3 Buckets (`acme-corp-hr-records`, `acme-corp-customer-support`, `acme-corp-payroll-exports`, `acme-corp-marketing-leads`, `acme-corp-legacy-backups`)

| Control(s) | Gap | Evidence |
|---|---|---|
| AC-3, AC-6 | Actively public — all 4 Public Access Block flags `false`, plus a bucket policy granting `s3:GetObject` to `Principal: "*"` | `get-public-access-block` → all `false`; `get-bucket-policy` → public-read statement present |
| SC-8, SC-23 | No TLS enforcement — the only policy statement is the public grant; nothing denies plaintext HTTP | policy has 1 statement, no `aws:SecureTransport` condition |
| SC-28, SC-13 | No encryption at rest | `get-bucket-encryption` → `ServerSideEncryptionConfigurationNotFoundError` |
| CM-6 | No versioning — accidental/malicious overwrite or delete is unrecoverable | `get-bucket-versioning` → empty |
| AU-2, AU-3, AU-12 | No access logging — no record of who read/wrote/deleted objects | `get-bucket-logging` → empty |
| CM-8, RA-2 | No tags — no data classification, no owner, no way to discover which buckets hold PII | `get-bucket-tagging` → `TagSet: []` |

## RDS Instance (`acme-corp-users-db`)

| Control(s) | Gap | Evidence |
|---|---|---|
| SC-28, SC-13 | No encryption at rest | `StorageEncrypted` → `false` |
| SC-13, SC-8, SC-23 (FIPS) | No transport encryption enforced — SSL is off on the engine itself, plaintext connections succeed | `SHOW ssl;` → `off`; `sslmode=disable` connection succeeds |
| IA-5, AC-17 | No IAM database authentication — password-only auth, no short-lived centrally-revocable credentials | `IAMDatabaseAuthenticationEnabled` → `false` |
| CM-6, SI-2 | No automatic minor version patching | `AutoMinorVersionUpgrade` → `false` |
| CM-6, CP-9 | No deletion protection, no automated backups | `DeletionProtection` → `false`; `BackupRetentionPeriod` → `0` |
| AU-2, AU-12 | No audit log export — Postgres connection/statement logs go nowhere centralized | `EnabledCloudwatchLogsExports` → empty |

**Already compliant, not a gap:** `PubliclyAccessible` → `false`.
