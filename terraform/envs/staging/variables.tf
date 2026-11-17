variable "region" {
  description = "Primary region."
  type        = string
  default     = "eu-central-1"
}

variable "dr_region" {
  description = "Region for replicated RDS backups."
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "staging"
}

variable "image_tag" {
  description = "Image tag to deploy (the git commit SHA). Set by the deploy pipeline; git is the source of truth."
  type        = string
}

variable "alert_email" {
  description = "E-mail subscribed to the alerts SNS topic (confirm the subscription mail). Empty = no subscription."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "AWS Budget alert threshold for this account."
  type        = number
  default     = 150
}

variable "discovery_namespace" {
  description = "Cloud Map namespace. Must match observability/prometheus/prometheus.aws.yml."
  type        = string
  default     = "referrals.internal"
}

variable "db_multi_az" {
  description = "RDS Multi-AZ. Needed for drill 03 (failover); turn off to halve DB cost while idle."
  type        = bool
  default     = true
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_cross_region_backup" {
  description = "Replicate automated backups to dr_region."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway (cheaper) instead of one per AZ."
  type        = bool
  default     = true
}

variable "api_min_tasks" {
  description = "Minimum API tasks (2 = one per AZ)."
  type        = number
  default     = 2
}

variable "api_max_tasks" {
  description = "Maximum API tasks."
  type        = number
  default     = 4
}

variable "api_db_pool_size" {
  description = "SQLAlchemy pool size per API task. Keep api_max_tasks x pool + 2 below max_connections."
  type        = number
  default     = 5
}

variable "certificate_arn" {
  description = "ACM certificate for HTTPS. Empty = HTTP only."
  type        = string
  default     = ""
}
