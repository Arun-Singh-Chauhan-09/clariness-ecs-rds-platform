# Self-hosted Prometheus, Alertmanager, Loki and Grafana on ECS Fargate.
# Each is a single task registered in Cloud Map (<component>.<namespace>).
# None is exposed publicly: reach the UIs with scripts/port-forward.sh (ECS Exec).
# Trade-offs: see docs/adr/0002-self-hosted-observability-on-ecs.md.

data "aws_region" "current" {}

locals {
  dns = { for c in ["prometheus", "alertmanager", "loki", "grafana"] : c => "${c}.${var.namespace_name}" }
}

# One shared security group: the components talk to each other freely.
resource "aws_security_group" "obs" {
  name        = "${var.name}-obs"
  description = "Observability stack ${var.name}"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-obs" }
}

resource "aws_vpc_security_group_ingress_rule" "self" {
  security_group_id            = aws_security_group.obs.id
  description                  = "Components of the observability stack"
  referenced_security_group_id = aws_security_group.obs.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 9093
}

resource "aws_vpc_security_group_ingress_rule" "loki_push" {
  for_each                     = { for i, id in var.log_shipper_security_group_ids : tostring(i) => id }
  security_group_id            = aws_security_group.obs.id
  description                  = "Log shippers push to Loki"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 3100
  to_port                      = 3100
}

# --- Loki storage --------------------------------------------------------------------
resource "aws_s3_bucket" "loki" {
  bucket_prefix = "${var.name}-loki-"
  force_destroy = true # log chunks only; allows `terraform destroy` of the demo
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    id     = "expire-chunks"
    status = "Enabled"
    filter {}
    expiration {
      days = var.loki_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --- Grafana admin password -------------------------------------------------------------
resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "grafana" {
  name_prefix             = "${var.name}-grafana-admin-"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id     = aws_secretsmanager_secret.grafana.id
  secret_string = random_password.grafana.result
}

# --- Components -----------------------------------------------------------------------
locals {
  common = {
    cluster_arn                        = var.cluster_arn
    cluster_name                       = var.cluster_name
    vpc_id                             = var.vpc_id
    subnet_ids                         = var.subnet_ids
    namespace_id                       = var.namespace_id
    additional_security_group_ids      = [aws_security_group.obs.id]
    capacity_provider                  = var.capacity_provider
    deployment_minimum_healthy_percent = 0 # single stateful instance: stop old before starting new
    deployment_maximum_percent         = 100
  }
}

module "prometheus" {
  source = "../ecs-service"

  name                               = "${var.name}-prometheus"
  image                              = var.images.prometheus
  container_port                     = 9090
  cpu                                = 512
  memory                             = 1024
  command                            = ["--config.file=/etc/prometheus/prometheus.aws.yml", "--storage.tsdb.path=/prometheus", "--storage.tsdb.retention.time=3d", "--web.enable-lifecycle"]
  cluster_arn                        = local.common.cluster_arn
  cluster_name                       = local.common.cluster_name
  vpc_id                             = local.common.vpc_id
  subnet_ids                         = local.common.subnet_ids
  additional_security_group_ids      = local.common.additional_security_group_ids
  capacity_provider                  = local.common.capacity_provider
  deployment_minimum_healthy_percent = local.common.deployment_minimum_healthy_percent
  deployment_maximum_percent         = local.common.deployment_maximum_percent
  service_discovery_namespace_id     = local.common.namespace_id
  service_discovery_name             = "prometheus"
}

data "aws_iam_policy_document" "alertmanager" {
  statement {
    actions   = ["sns:Publish"]
    resources = [var.alarm_sns_topic_arn]
  }
}

module "alertmanager" {
  source = "../ecs-service"

  name           = "${var.name}-alertmanager"
  image          = var.images.alertmanager
  container_port = 9093
  environment = {
    ALERTMANAGER_MODE = "aws"
    SNS_TOPIC_ARN     = var.alarm_sns_topic_arn
    AWS_REGION        = data.aws_region.current.name
  }
  task_role_policy_json              = data.aws_iam_policy_document.alertmanager.json
  cluster_arn                        = local.common.cluster_arn
  cluster_name                       = local.common.cluster_name
  vpc_id                             = local.common.vpc_id
  subnet_ids                         = local.common.subnet_ids
  additional_security_group_ids      = local.common.additional_security_group_ids
  capacity_provider                  = local.common.capacity_provider
  deployment_minimum_healthy_percent = local.common.deployment_minimum_healthy_percent
  deployment_maximum_percent         = local.common.deployment_maximum_percent
  service_discovery_namespace_id     = local.common.namespace_id
  service_discovery_name             = "alertmanager"
}

data "aws_iam_policy_document" "loki" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.loki.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.loki.arn}/*"]
  }
}

module "loki" {
  source = "../ecs-service"

  name           = "${var.name}-loki"
  image          = var.images.loki
  container_port = 3100
  cpu            = 512
  memory         = 1024
  command        = ["-config.file=/etc/loki/loki.aws.yaml", "-config.expand-env=true"]
  environment = {
    LOKI_S3_BUCKET = aws_s3_bucket.loki.id
    AWS_REGION     = data.aws_region.current.name
  }
  task_role_policy_json              = data.aws_iam_policy_document.loki.json
  cluster_arn                        = local.common.cluster_arn
  cluster_name                       = local.common.cluster_name
  vpc_id                             = local.common.vpc_id
  subnet_ids                         = local.common.subnet_ids
  additional_security_group_ids      = local.common.additional_security_group_ids
  capacity_provider                  = local.common.capacity_provider
  deployment_minimum_healthy_percent = local.common.deployment_minimum_healthy_percent
  deployment_maximum_percent         = local.common.deployment_maximum_percent
  service_discovery_namespace_id     = local.common.namespace_id
  service_discovery_name             = "loki"
}

module "grafana" {
  source = "../ecs-service"

  name           = "${var.name}-grafana"
  image          = var.images.grafana
  container_port = 3000
  environment = {
    PROMETHEUS_URL                 = "http://${local.dns.prometheus}:9090"
    LOKI_URL                       = "http://${local.dns.loki}:3100"
    ALERTMANAGER_URL               = "http://${local.dns.alertmanager}:9093"
    GF_ANALYTICS_REPORTING_ENABLED = "false"
    GF_USERS_ALLOW_SIGN_UP         = "false"
  }
  secrets                            = { GF_SECURITY_ADMIN_PASSWORD = aws_secretsmanager_secret.grafana.arn }
  execution_secret_arns              = [aws_secretsmanager_secret.grafana.arn]
  cluster_arn                        = local.common.cluster_arn
  cluster_name                       = local.common.cluster_name
  vpc_id                             = local.common.vpc_id
  subnet_ids                         = local.common.subnet_ids
  additional_security_group_ids      = local.common.additional_security_group_ids
  capacity_provider                  = local.common.capacity_provider
  deployment_minimum_healthy_percent = local.common.deployment_minimum_healthy_percent
  deployment_maximum_percent         = local.common.deployment_maximum_percent
  service_discovery_namespace_id     = local.common.namespace_id
  service_discovery_name             = "grafana"
}
