variable "name" {
  description = "Name prefix (must start with \"referrals-\")."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets."
  type        = list(string)
}

variable "namespace_id" {
  description = "Cloud Map private DNS namespace ID."
  type        = string
}

variable "namespace_name" {
  description = "Cloud Map namespace name. Must match observability/prometheus/prometheus.aws.yml."
  type        = string
}

variable "images" {
  description = "Image URIs (with tag) for prometheus, alertmanager, loki and grafana."
  type = object({
    prometheus   = string
    alertmanager = string
    loki         = string
    grafana      = string
  })
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic Alertmanager publishes to."
  type        = string
}

variable "log_shipper_security_group_ids" {
  description = "Security groups whose tasks push logs to Loki (FireLens sidecars)."
  type        = list(string)
  default     = []
}

variable "capacity_provider" {
  description = "FARGATE_SPOT by default: the observability stack tolerates short interruptions."
  type        = string
  default     = "FARGATE_SPOT"
}

variable "loki_retention_days" {
  description = "Days of log chunks kept in S3."
  type        = number
  default     = 30
}
