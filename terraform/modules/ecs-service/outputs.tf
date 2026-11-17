output "service_name" {
  description = "ECS service name, or null for task-only definitions."
  value       = var.create_service ? aws_ecs_service.this[0].name : null
}

output "task_definition_arn" {
  description = "Task definition ARN (this revision)."
  value       = aws_ecs_task_definition.this.arn
}

output "task_definition_family" {
  description = "Task definition family (run-task picks the latest revision)."
  value       = aws_ecs_task_definition.this.family
}

output "security_group_id" {
  description = "Security group of the tasks."
  value       = aws_security_group.this.id
}

output "task_role_arn" {
  description = "Task role ARN."
  value       = aws_iam_role.task.arn
}

output "log_group_name" {
  description = "CloudWatch log group."
  value       = aws_cloudwatch_log_group.this.name
}

output "container_name" {
  description = "Name of the main container (for run-task overrides)."
  value       = local.container_name
}
