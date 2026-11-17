variable "name" {
  description = "Name prefix (ALB names are limited to 32 characters)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets in at least two AZs."
  type        = list(string)
}

variable "target_port" {
  description = "Container port the target group forwards to."
  type        = number
}

variable "health_check_path" {
  description = "Liveness path for target health checks."
  type        = string
  default     = "/healthz"
}

variable "certificate_arn" {
  description = "ACM certificate. Set it to serve HTTPS and redirect HTTP; empty = HTTP only (demo)."
  type        = string
  default     = ""
}

variable "allowed_cidrs" {
  description = "Who may reach the ALB."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "deletion_protection" {
  description = "Protect the ALB from deletion."
  type        = bool
  default     = false
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic for alarms. Empty disables alarms."
  type        = string
  default     = ""
}
