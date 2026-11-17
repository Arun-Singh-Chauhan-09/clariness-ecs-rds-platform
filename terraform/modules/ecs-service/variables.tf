variable "name" {
  description = "Name of the service, task definition family, roles and log group. Must start with \"referrals-\" (the CI deploy role can only manage IAM roles with that prefix)."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name (used by autoscaling)."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the service's security group."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the tasks."
  type        = list(string)
}

variable "image" {
  description = "Container image including tag."
  type        = string
}

variable "container_port" {
  description = "Port the container listens on. Null for task-only definitions without a port (e.g. migrations)."
  type        = number
  default     = null
}

variable "cpu" {
  description = "Task CPU units (256 = 0.25 vCPU)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Task memory in MiB."
  type        = number
  default     = 512
}

variable "command" {
  description = "Overrides the image CMD."
  type        = list(string)
  default     = null
}

variable "environment" {
  description = "Plain environment variables."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Environment variables injected from Secrets Manager/SSM: NAME => valueFrom (e.g. \"<secret-arn>:password::\")."
  type        = map(string)
  default     = {}
}

variable "execution_secret_arns" {
  description = "Secret ARNs the execution role may read to inject `secrets`."
  type        = list(string)
  default     = []
}

variable "execution_kms_key_arns" {
  description = "KMS keys the execution role may use to decrypt those secrets."
  type        = list(string)
  default     = []
}

variable "task_role_policy_json" {
  description = "Extra IAM policy for the task role (what the application itself may call)."
  type        = string
  default     = null
}

variable "health_check" {
  description = "Container health check. Null = rely on the load balancer health check only."
  type = object({
    command      = list(string)
    interval     = optional(number, 15)
    timeout      = optional(number, 5)
    retries      = optional(number, 3)
    start_period = optional(number, 30)
  })
  default = null
}

variable "readonly_root_filesystem" {
  description = "Mount the container's root filesystem read-only."
  type        = bool
  default     = false
}

variable "firelens" {
  description = "Ship container logs through a FireLens (Fluent Bit) sidecar instead of awslogs."
  type = object({
    image       = string
    environment = map(string)
  })
  default = null
}

variable "create_service" {
  description = "False = only the task definition (for one-off tasks started with `aws ecs run-task`)."
  type        = bool
  default     = true
}

variable "desired_count" {
  description = "Initial task count. Ignored after creation (autoscaling or operators own it)."
  type        = number
  default     = 1
}

variable "capacity_provider" {
  description = "FARGATE or FARGATE_SPOT (about 70% cheaper; tasks can be interrupted with 2 minutes' notice)."
  type        = string
  default     = "FARGATE"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT"], var.capacity_provider)
    error_message = "capacity_provider must be FARGATE or FARGATE_SPOT."
  }
}

variable "target_group_arn" {
  description = "ALB target group to register tasks in. Null = no load balancer."
  type        = string
  default     = null
}

variable "health_check_grace_period_seconds" {
  description = "Seconds the ALB health check is ignored after a task starts."
  type        = number
  default     = 30
}

variable "ingress_rules" {
  description = "Security groups allowed to reach container_port."
  type = list(object({
    source_security_group_id = string
    description              = string
  }))
  default = []
}

variable "additional_security_group_ids" {
  description = "Extra security groups to attach to the tasks."
  type        = list(string)
  default     = []
}

variable "service_discovery_namespace_id" {
  description = "Cloud Map private DNS namespace. Null = no service discovery."
  type        = string
  default     = null
}

variable "service_discovery_name" {
  description = "DNS label in the namespace, e.g. \"api\" -> api.<namespace>."
  type        = string
  default     = null
}

variable "autoscaling" {
  description = "CPU target-tracking autoscaling. Null = fixed task count."
  type = object({
    min_capacity       = number
    max_capacity       = number
    cpu_target_percent = optional(number, 60)
  })
  default = null
}

variable "deployment_minimum_healthy_percent" {
  description = "Lower bound of running tasks during a deployment (100 = never below desired count)."
  type        = number
  default     = 100
}

variable "deployment_maximum_percent" {
  description = "Upper bound during a deployment (200 = start a full new set first)."
  type        = number
  default     = 200
}

variable "wait_for_steady_state" {
  description = "Make `terraform apply` wait until the deployment finishes, and fail if the circuit breaker rolls it back."
  type        = bool
  default     = false
}

variable "enable_execute_command" {
  description = "Allow ECS Exec (shell / port forwarding through SSM, no inbound ports needed)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 14
}
