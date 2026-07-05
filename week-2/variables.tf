# The AWS provider never returns the RDS master password on refresh (write-
# only, even in Floci) — the live config's own `password` argument is `null`
# after import, so it can't be read back out of the resource itself. This
# variable exists solely so outputs.tf can build a real, working psql
# command; the default matches what scripts/02-create-rds.sh actually sets.
variable "rds_master_password" {
  description = "acme-corp-users-db master password — must match scripts/02-create-rds.sh"
  type        = string
  default     = "DemoPass123!"
  sensitive   = true
}
