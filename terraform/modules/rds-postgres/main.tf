data "aws_region" "dr" {
  provider = aws.dr
}

data "aws_caller_identity" "current" {}

# Explicit key policy (same effect as the AWS default: the account administers
# the key through IAM; RDS and Secrets Manager use it via grants).
data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "rds" {
  description             = "${var.identifier}: storage, snapshots and master secret"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.identifier}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

resource "aws_db_subnet_group" "this" {
  name       = var.identifier
  subnet_ids = var.subnet_ids
}

# Ingress rules are added by the caller (one rule per client security group),
# so this module does not need to know who connects.
resource "aws_security_group" "db" {
  name        = "${var.identifier}-db"
  description = "PostgreSQL ${var.identifier}"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.identifier}-db" }
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.identifier}-pg${split(".", var.engine_version)[0]}"
  family = "postgres${split(".", var.engine_version)[0]}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "500" # log queries slower than 500 ms
  }
  parameter {
    name  = "log_lock_waits"
    value = "1" # makes migrations stuck behind locks visible
  }
  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "60000" # 60 s: a forgotten open transaction cannot block migrations forever
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = var.identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name                       = var.db_name
  username                      = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.rds.arn

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.this.name

  backup_retention_period  = var.backup_retention_days
  backup_window            = var.backup_window
  maintenance_window       = var.maintenance_window
  copy_tags_to_snapshot    = true
  delete_automated_backups = false
  deletion_protection      = var.deletion_protection
  skip_final_snapshot      = var.skip_final_snapshot

  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.identifier}-final"

  auto_minor_version_upgrade          = true
  allow_major_version_upgrade         = false
  apply_immediately                   = var.apply_immediately
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]

  # OS-level metrics (CPU steal, memory, I/O per process) every 60 s.
  monitoring_interval = var.enhanced_monitoring_interval
  monitoring_role_arn = var.enhanced_monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null

  tags = { Name = var.identifier }
}

# --- Cross-region DR copy of automated backups --------------------------------------
# Keeps snapshots and transaction logs in a second region, so a point-in-time
# restore is possible even if the primary region is unavailable.
resource "aws_kms_key" "dr" {
  count                   = var.cross_region_backup_enabled ? 1 : 0
  provider                = aws.dr
  description             = "${var.identifier}: replicated backups"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_db_instance_automated_backups_replication" "dr" {
  count                  = var.cross_region_backup_enabled ? 1 : 0
  provider               = aws.dr
  source_db_instance_arn = aws_db_instance.this.arn
  retention_period       = var.backup_retention_days
  kms_key_id             = aws_kms_key.dr[0].arn
}

# --- Alarms ------------------------------------------------------------------------
locals {
  alarms = var.alarm_sns_topic_arn == "" ? {} : {
    cpu = {
      metric      = "CPUUtilization"
      comparison  = "GreaterThanThreshold"
      threshold   = 80
      description = "CPU above 80% for 10 minutes"
    }
    storage = {
      metric      = "FreeStorageSpace"
      comparison  = "LessThanThreshold"
      threshold   = 2 * 1024 * 1024 * 1024
      description = "Less than 2 GiB free storage"
    }
    connections = {
      metric      = "DatabaseConnections"
      comparison  = "GreaterThanThreshold"
      threshold   = var.max_connections_alarm_threshold
      description = "Connection count close to max_connections"
    }
    memory = {
      metric      = "FreeableMemory"
      comparison  = "LessThanThreshold"
      threshold   = 64 * 1024 * 1024
      description = "Less than 64 MiB freeable memory"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "db" {
  for_each = local.alarms

  alarm_name          = "${var.identifier}-${each.key}"
  alarm_description   = each.value.description
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  treat_missing_data  = "missing"
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]
}

# --- Enhanced monitoring --------------------------------------------------------------
data "aws_iam_policy_document" "monitoring_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  count              = var.enhanced_monitoring_interval > 0 ? 1 : 0
  name               = "${var.identifier}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_trust.json
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count      = var.enhanced_monitoring_interval > 0 ? 1 : 0
  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
