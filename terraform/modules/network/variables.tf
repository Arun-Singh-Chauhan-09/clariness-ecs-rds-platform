variable "name" {
  description = "Name prefix for all resources."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. /16 recommended; subnets are /24."
  type        = string
  default     = "10.40.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones (2 is the minimum for RDS Multi-AZ and the ALB)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "single_nat_gateway" {
  description = "One NAT gateway for all AZs (cheaper, but an AZ outage cuts egress for the others). False = one per AZ."
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  description = "Retention of VPC flow logs in CloudWatch. 0 disables flow logs."
  type        = number
  default     = 14
}
