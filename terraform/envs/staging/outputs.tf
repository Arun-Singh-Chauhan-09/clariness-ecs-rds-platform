# Consumed by the pipeline and the scripts in scripts/ (terraform output -raw <name>).

output "api_base_url" {
  description = "Public URL of the API."
  value       = module.alb.base_url
}

output "cluster_name" {
  description = "ECS cluster."
  value       = aws_ecs_cluster.this.name
}

output "api_service_name" {
  description = "ECS service of the API."
  value       = module.api.service_name
}

output "migrate_task_family" {
  description = "Task definition family used for migrations and DR verification."
  value       = module.migrate.task_definition_family
}

output "migrate_security_group_id" {
  description = "Security group for one-off migration/verification tasks."
  value       = module.migrate.security_group_id
}

output "private_subnet_ids" {
  description = "Subnets for one-off tasks (comma-separated for the AWS CLI)."
  value       = join(",", module.network.private_subnet_ids)
}

output "db_instance_id" {
  description = "RDS instance identifier."
  value       = module.rds.instance_id
}

output "db_subnet_group" {
  description = "DB subnet group (DR restore target)."
  value       = module.rds.subnet_group_name
}

output "db_security_group_id" {
  description = "DB security group (DR restore target)."
  value       = module.rds.security_group_id
}

output "db_parameter_group" {
  description = "DB parameter group (DR restore target)."
  value       = module.rds.parameter_group_name
}

output "ecr_registry" {
  description = "ECR registry host."
  value       = split("/", aws_ecr_repository.this["api"].repository_url)[0]
}

output "observability_services" {
  description = "ECS services of Prometheus, Alertmanager, Loki and Grafana (for scripts/port-forward.sh)."
  value       = module.observability.service_names
}

output "grafana_admin_secret_arn" {
  description = "aws secretsmanager get-secret-value --secret-id <this> to log in as admin."
  value       = module.observability.grafana_admin_secret_arn
}

output "api_keys_secret_arn" {
  description = "Secret with the API key(s). Smoke test and drills read it: aws secretsmanager get-secret-value --secret-id <this>."
  value       = aws_secretsmanager_secret.api_keys.arn
}
