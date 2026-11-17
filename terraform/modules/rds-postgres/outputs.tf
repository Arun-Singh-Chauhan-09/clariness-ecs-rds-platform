output "instance_id" {
  description = "RDS instance identifier."
  value       = aws_db_instance.this.identifier
}

output "instance_arn" {
  description = "RDS instance ARN."
  value       = aws_db_instance.this.arn
}

output "address" {
  description = "DNS name of the instance. It does not change on Multi-AZ failover."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "PostgreSQL port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Database name."
  value       = aws_db_instance.this.db_name
}

output "master_username" {
  description = "Master user name."
  value       = aws_db_instance.this.username
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret (JSON with username/password) managed by RDS."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "kms_key_arn" {
  description = "KMS key encrypting storage and the master secret; readers of the secret need kms:Decrypt."
  value       = aws_kms_key.rds.arn
}

output "security_group_id" {
  description = "Database security group; add ingress rules for clients."
  value       = aws_security_group.db.id
}

output "subnet_group_name" {
  description = "DB subnet group (used when restoring for DR drills)."
  value       = aws_db_subnet_group.this.name
}

output "dr_region" {
  description = "Region holding replicated backups, or null."
  value       = var.cross_region_backup_enabled ? data.aws_region.dr.name : null
}

output "parameter_group_name" {
  description = "DB parameter group (applied to restored instances in DR drills)."
  value       = aws_db_parameter_group.this.name
}
