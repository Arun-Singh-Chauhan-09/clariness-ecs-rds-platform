variable "region" {
  description = "AWS region for the state bucket and IAM resources."
  type        = string
  default     = "eu-central-1"
}

variable "state_bucket_name" {
  description = "Globally unique name of the S3 bucket that stores Terraform state."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the CI roles, as owner/name."
  type        = string
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the GitHub OIDC provider."
  type        = bool
  default     = true
}

variable "dr_region" {
  description = "DR region (backup replication). The deploy role may act only in region and dr_region."
  type        = string
  default     = "eu-west-1"
}

variable "enable_account_security_baseline" {
  description = "Create a multi-region CloudTrail trail and enable GuardDuty (turn off if your AWS Organization already does this)."
  type        = bool
  default     = true
}
