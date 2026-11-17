output "security_group_id" {
  description = "Shared security group of the observability tasks (allow it to scrape targets)."
  value       = aws_security_group.obs.id
}

output "loki_host" {
  description = "Loki DNS name for log shippers."
  value       = local.dns.loki
}

output "grafana_admin_secret_arn" {
  description = "Secret holding the Grafana admin password."
  value       = aws_secretsmanager_secret.grafana.arn
}

output "service_names" {
  description = "ECS service names of the components."
  value = {
    prometheus   = module.prometheus.service_name
    alertmanager = module.alertmanager.service_name
    loki         = module.loki.service_name
    grafana      = module.grafana.service_name
  }
}
