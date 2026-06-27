# Terraform Lesson Project

A hands-on demo that walks through the full lifecycle of an AWS S3 bucket — first managing it manually with the AWS CLI, then codifying it with Terraform, then scanning and hardening the configuration with tfsec. All AWS calls run locally against **Floci**, a local AWS cloud emulator, so no real AWS account is needed.

A starter kit zip (`starter-kit.zip`) is included with the base files to get going immediately.

---

## Prerequisites

Install all of the following before starting.

### Docker + Docker Compose
Used to run the Floci emulator container.
```bash
docker --version
docker compose version
```
Install: https://docs.docker.com/get-docker/

### Terraform
Used to write and apply infrastructure as code.
```bash
terraform -version
```
Install: https://developer.hashicorp.com/terraform/install

### AWS CLI
Used to interact with the local Floci environment just like real AWS.
```bash
aws --version
```
Install: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html

### tfsec
Used to scan Terraform files for security misconfigurations.
```bash
tfsec --version
```
Install:
```bash
curl -s https://raw.githubusercontent.com/aquasecurity/tfsec/master/scripts/install_linux.sh | bash
```

### jq
Used to pretty print JSON output from Terraform and the AWS CLI.
```bash
jq --version
```
Install:
```bash
sudo apt install jq -y
```

---

## Getting Help on Any Command

Every tool used in this demo supports a `--help` flag. Use it to see all available options.

```bash
aws s3 help
aws s3api get-bucket-encryption help
terraform --help
terraform plan --help
tfsec --help
gh --help
```

---

## Environment Setup

### 1. Set your shell environment variables

These tell the AWS CLI where to send requests and what credentials to use. Floci accepts any non-empty value for the key/secret.

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
```

To make these permanent, add them to your `~/.bashrc` or `~/.zshrc`.

### 2. Start Floci

This pulls and starts the Floci container in the background. It listens on port `4566` and emulates AWS APIs.

```bash
docker compose up -d
```

- `up` — creates and starts containers defined in `docker-compose.yml`
- `-d` — detached mode, runs in the background

Verify it is running:
```bash
docker compose ps
```

---

## Phase 1 — Manual Bucket Lifecycle (AWS CLI)

This phase shows how to create and destroy a bucket by hand before letting Terraform manage it. This is the "before" state the demo is comparing against.

### Create the bucket

```bash
aws s3 mb s3://demo-bucket
```

- `mb` — make bucket
- `s3://demo-bucket` — the bucket name prefixed with the S3 URI scheme

### Confirm it exists

```bash
aws s3 ls


aws s3api get-bucket-location --bucket <bucket-name>

For more complete config info:

# Encryption
aws s3api get-bucket-encryption --bucket <bucket-name>

# Versioning
aws s3api get-bucket-versioning --bucket <bucket-name>

# Public access block
aws s3api get-public-access-block --bucket <bucket-name>

# ACL
aws s3api get-bucket-acl --bucket <bucket-name>

```

Lists all buckets in the account. You should see `demo-bucket` in the output.

### Delete the bucket

```bash
aws s3 rb s3://demo-bucket
```

- `rb` — remove bucket

The bucket must be empty to delete it. If it has objects, add `--force` to delete contents first.

---

## Phase 2 — Terraform Managed Bucket

### What the files do

| File | Purpose |
|------|---------|
| `s3.tf` | Terraform provider config + all S3 resources |
| `outputs.tf` | Prints the bucket name and ARN after apply |
| `verify.sh` | Post-apply compliance checks against live bucket |
| `s3_insecure_original.txt` | The original insecure version for comparison |

### Initialize Terraform

Downloads the AWS provider plugin defined in the `terraform` block.

```bash
terraform init
```

### Preview the changes

Shows what Terraform will create, modify, or destroy without making any changes. Always run this before apply.

```bash
terraform plan
```

### Apply the configuration

Creates all resources defined in the `.tf` files. Terraform will prompt for confirmation — type `yes`.

```bash
terraform apply
```

### View current state

Shows the current state of all managed resources in a human-readable format.

```bash
terraform show
```

---

## Phase 3 — Security Scan with tfsec

tfsec scans your Terraform files for security misconfigurations before you ever apply them.

### Run the scan

```bash
tfsec .
```

The `.` tells tfsec to scan all `.tf` files in the current directory.

### Original insecure configuration

`s3_insecure_original.txt` shows what the bucket looked like before hardening — a single resource block with no encryption, no public access block, and no versioning. tfsec flagged 6 HIGH findings against it.

### Findings fixed

| tfsec ID | Finding | Fix Applied |
|----------|---------|-------------|
| `aws-s3-block-public-acls` | PUT calls could set public ACLs | `block_public_acls = true` |
| `aws-s3-block-public-policy` | Public bucket policies could be applied | `block_public_policy = true` |
| `aws-s3-ignore-public-acls` | Existing public ACLs not ignored | `ignore_public_acls = true` |
| `aws-s3-no-public-buckets` | Bucket accessible to public | `restrict_public_buckets = true` |
| `aws-s3-enable-bucket-encryption` | No encryption at rest | SSE with `aws:kms` |
| `aws-s3-encryption-customer-key` | AWS-managed key, no fine-grained control | Customer-managed KMS key |

---

## Phase 4 — Compliance Verification

`verify.sh` checks three NIST 800-53 controls against the live bucket by calling the AWS API directly.

```bash
bash verify.sh
```

| Control | API Call | Expected Result |
|---------|----------|-----------------|
| SC-28 (encryption at rest) | `get-bucket-encryption` | `aws:kms` |
| CM-6 (configuration management) | `get-bucket-versioning` | `Enabled` |
| AC-3 (access enforcement) | `get-public-access-block` | All four flags `true` |

All three must return clean output with no errors.

---

## Phase 5 — Capture Evidence

Save proof of the applied configuration to the `evidence/` directory.

### Full bucket resource output

```bash
terraform show -json | jq '.values.root_module.resources[] | select(.type == "aws_s3_bucket")' > evidence/bucket.json
```

- `terraform show -json` — outputs the entire state as JSON
- `jq '.values.root_module.resources[] | select(.type == "aws_s3_bucket")'` — filters to just the S3 bucket resource

### Full state (all resources)

```bash
terraform show -json | jq . > evidence/full_state.json
```

---

## Phase 6 — Teardown

Destroys all resources Terraform created. Terraform prompts for confirmation — type `yes`.

```bash
terraform destroy
```

---

## Publishing to GitHub

### Set your Git identity (required before first commit)

```bash
git config --global user.email "you@example.com"
git config --global user.name "Your Name"
```

Only needs to be done once per machine. Omit `--global` to set it for the current repo only.

### Initialize and create the repo

```bash
git init -b main
git add .
git commit -m "initial commit"
gh repo create <repo-name> --public --description "Your description here" --source=. --remote=origin --push
```

- `-b main` — sets the initial branch name to `main` instead of the default `master`
- `--public` — makes the repo publicly visible
- `--description` — sets the repo description
- `--source=.` — uses the current directory as the source
- `--remote=origin` — names the remote `origin`
- `--push` — pushes the current branch immediately after creation

### Remove files from a commit before pushing

If you committed files you didn't mean to include, remove them and amend the commit before pushing:

```bash
git rm --cached <file1> <file2>
git commit --amend --no-edit
```

- `git rm --cached` — removes files from the commit but keeps them on disk
- `--amend --no-edit` — rewrites the last commit without changing the message

Then add a `.gitignore` to keep them out going forward:

```bash
echo "<file1>" >> .gitignore
echo "<file2>" >> .gitignore
git add .gitignore
git commit -m "add gitignore"
```

### Remove large files baked into commit history

If a file exceeds GitHub's 100 MB limit and is already in commit history, `git rm --cached` is not enough — you must rewrite history to purge it.

Using `git filter-repo` (recommended):

```bash
pip install git-filter-repo
git filter-repo --path .terraform/ --invert-paths
git push origin main --force
```

Using `git filter-branch` (built-in fallback):

```bash
git filter-branch --force --index-filter "git rm -rf --cached --ignore-unmatch .terraform/" --prune-empty --tag-name-filter cat -- --all
git push origin main --force
```

- `--invert-paths` — removes the specified path instead of keeping it
- `--force` push — required after rewriting history

### List your GitHub repos

```bash
gh repo list
```

### Delete a GitHub repo

```bash
gh repo delete <repo-name> --yes
```

- `--yes` — skips the confirmation prompt

### If the repo already exists on GitHub

```bash
git remote add origin https://github.com/<username>/<repo-name>.git
git branch -M main
git push -u origin main
```

---

## Starter Kit

`starter-kit.zip` contains the base files to follow along:

```
docker-compose.yml        — Floci container definition
s3.tf                     — Hardened Terraform config
outputs.tf                — Terraform outputs
verify.sh                 — Compliance verification script
s3_insecure_original.txt  — Original insecure config for comparison
```

Extract with:
```bash
unzip starter-kit.zip
```
