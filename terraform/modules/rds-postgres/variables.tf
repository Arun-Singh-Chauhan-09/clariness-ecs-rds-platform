variable "identifier" {
  description = "RDS instance identifier and name prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC for the database security group."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets in at least two AZs."
  type        = list(string)
}

variable "engine_version" {
  description = "PostgreSQL major version; minor versions are upgraded automatically in the maintenance window."
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "Instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage_gb" {
  description = "Initial gp3 storage."
  type        = number
  default     = 20
}

variable "max_allocated_storage_gb" {
  description = "Storage autoscaling ceiling."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "referrals"
}

variable "master_username" {
  description = "Master user. The password is generated and rotated by RDS in Secrets Manager."
  type        = string
  default     = "referrals_admin"
}

variable "multi_az" {
  description = "Synchronous standby in a second AZ with automatic failover (~2x cost)."
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Automated backup retention; this is also the point-in-time-restore window."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "Must be 1-35 days (0 would disable backups and PITR)."
  }
}

variable "backup_window" {
  description = "Daily backup window (UTC). Must not overlap the maintenance window."
  type        = string
  default     = "01:00-02:00"
}

variable "maintenance_window" {
  description = "Weekly maintenance window (UTC)."
  type        = string
  default     = "sun:02:30-sun:03:30"
}

variable "deletion_protection" {
  description = "Block deletion of the instance."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Keep false outside throwaway environments."
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "Apply modifications now instead of in the maintenance window."
  type        = bool
  default     = false
}

variable "cross_region_backup_enabled" {
  description = "Replicate automated backups (and PITR ability) to the aws.dr provider's region."
  type        = bool
  default     = true
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic for CloudWatch alarms. Empty disables alarms."
  type        = string
  default     = ""
}

variable "max_connections_alarm_threshold" {
  description = "Alarm when DatabaseConnections exceeds this (db.t4g.micro allows ~80 by default)."
  type        = number
  default     = 60
}

variable "enhanced_monitoring_interval" {
  description = "Seconds between Enhanced Monitoring samples (0 disables). 60 is the cheapest non-zero option."
  type        = number
  default     = 60
}
