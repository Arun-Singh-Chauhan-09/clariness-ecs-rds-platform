output "dns_name" {
  description = "Public DNS name of the ALB."
  value       = aws_lb.this.dns_name
}

output "base_url" {
  description = "Base URL of the API."
  value       = "${local.https ? "https" : "http"}://${aws_lb.this.dns_name}"
}

output "security_group_id" {
  description = "ALB security group (allow it into the service)."
  value       = aws_security_group.alb.id
}

output "target_group_arn" {
  description = "Target group for the API service."
  value       = aws_lb_target_group.app.arn
}
