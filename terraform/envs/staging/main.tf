locals {
  name = "referrals-${var.environment}" # IAM role names must start with "referrals-" (CI deploy role scope)
  images = {
    api          = "referrals-api"
    fluent_bit   = "referrals-fluent-bit"
    prometheus   = "referrals-prometheus"
    alertmanager = "referrals-alertmanager"
    loki         = "referrals-loki"
    grafana      = "referrals-grafana"
  }
  image_uri = { for k, repo in local.images : k => "${aws_ecr_repository.this[k].repository_url}:${var.image_tag}" }
}

data "aws_region" "current" {}

# --- Network ---------------------------------------------------------------------------
module "network" {
  source             = "../../modules/network"
  name               = local.name
  single_nat_gateway = var.single_nat_gateway
}

# --- Alerts: one topic for CloudWatch alarms, Alertmanager and the budget -------------------
resource "aws_sns_topic" "alerts" {
  name              = "${local.name}-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = var.alert_email == "" ? [] : [80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value == 100 ? "FORECASTED" : "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}

# --- Container registry ----------------------------------------------------------------------
resource "aws_ecr_repository" "this" {
  for_each             = local.images
  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # a SHA tag always means the same image
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 20 most recent images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# --- ECS cluster ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = var.discovery_namespace
  description = "Service discovery for ${local.name}"
  vpc         = module.network.vpc_id
}

# --- Load balancer ------------------------------------------------------------------------
module "alb" {
  source              = "../../modules/alb"
  name                = local.name
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  target_port         = 8000
  certificate_arn     = var.certificate_arn
  alarm_sns_topic_arn = aws_sns_topic.alerts.arn
}

# --- Database ------------------------------------------------------------------------------
module "rds" {
  source = "../../modules/rds-postgres"
  providers = {
    aws    = aws
    aws.dr = aws.dr
  }

  identifier                  = local.name
  vpc_id                      = module.network.vpc_id
  subnet_ids                  = module.network.private_subnet_ids
  instance_class              = var.db_instance_class
  multi_az                    = var.db_multi_az
  cross_region_backup_enabled = var.db_cross_region_backup
  alarm_sns_topic_arn         = aws_sns_topic.alerts.arn

  # Staging: allow `terraform destroy` to clean up. Production keeps the defaults
  # (deletion protection on, final snapshot taken).
  deletion_protection = false
  skip_final_snapshot = true
  apply_immediately   = true
}

locals {
  db_environment = {
    DB_HOST     = module.rds.address
    DB_PORT     = tostring(module.rds.port)
    DB_NAME     = module.rds.db_name
    DB_USER     = module.rds.master_username
    DB_SSLMODE  = "require"
    ENVIRONMENT = var.environment
  }
  # RDS stores the master secret as JSON; ECS extracts the "password" key.
  db_secrets = { DB_PASSWORD = "${module.rds.master_user_secret_arn}:password::" }
}

# --- API service ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "api_app" {
  name              = "/ecs/${local.name}-api/app"
  retention_in_days = 14
}

data "aws_iam_policy_document" "api_task" {
  # FireLens sidecar ships app logs to this log group (as well as to Loki).
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.api_app.arn}:*"]
  }
}

module "api" {
  source = "../../modules/ecs-service"

  name           = "${local.name}-api"
  cluster_arn    = aws_ecs_cluster.this.arn
  cluster_name   = aws_ecs_cluster.this.name
  vpc_id         = module.network.vpc_id
  subnet_ids     = module.network.private_subnet_ids
  image          = local.image_uri.api
  container_port = 8000
  cpu            = 256
  memory         = 512

  environment = merge(local.db_environment, {
    APP_VERSION  = var.image_tag
    DB_POOL_SIZE = tostring(var.api_db_pool_size)
  })
  secrets                = local.db_secrets
  execution_secret_arns  = [module.rds.master_user_secret_arn]
  execution_kms_key_arns = [module.rds.kms_key_arn]
  task_role_policy_json  = data.aws_iam_policy_document.api_task.json

  health_check = {
    command = ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2).status == 200 else 1)\""]
  }

  firelens = {
    image = local.image_uri.fluent_bit
    environment = {
      LOKI_HOST     = module.observability.loki_host
      APP_LOG_GROUP = aws_cloudwatch_log_group.api_app.name
      AWS_REGION    = data.aws_region.current.name
      ENVIRONMENT   = var.environment
    }
  }

  target_group_arn = module.alb.target_group_arn
  ingress_rules = [
    { source_security_group_id = module.alb.security_group_id, description = "ALB" },
    { source_security_group_id = module.observability.security_group_id, description = "Prometheus scrape" },
  ]
  service_discovery_namespace_id = aws_service_discovery_private_dns_namespace.this.id
  service_discovery_name         = "api"

  desired_count = var.api_min_tasks
  autoscaling = {
    min_capacity = var.api_min_tasks
    max_capacity = var.api_max_tasks
  }
  # Fail `terraform apply` (and so the pipeline) if the circuit breaker rolls back.
  wait_for_steady_state = true

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

# --- Migration task (no service; started by scripts/run-migration.sh) -------------------------
module "migrate" {
  source = "../../modules/ecs-service"

  name           = "${local.name}-migrate"
  create_service = false
  cluster_arn    = aws_ecs_cluster.this.arn
  cluster_name   = aws_ecs_cluster.this.name
  vpc_id         = module.network.vpc_id
  subnet_ids     = module.network.private_subnet_ids
  image          = local.image_uri.api
  command        = ["alembic", "upgrade", "head"]

  environment            = merge(local.db_environment, { STARTUP_DB_CHECK = "false" })
  secrets                = local.db_secrets
  execution_secret_arns  = [module.rds.master_user_secret_arn]
  execution_kms_key_arns = [module.rds.kms_key_arn]
}

# --- Database access rules -------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "db_from_api" {
  security_group_id            = module.rds.security_group_id
  description                  = "API tasks"
  referenced_security_group_id = module.api.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "db_from_migrate" {
  security_group_id            = module.rds.security_group_id
  description                  = "Migration and DR-verification tasks"
  referenced_security_group_id = module.migrate.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# --- Observability --------------------------------------------------------------------------
module "observability" {
  source = "../../modules/observability"

  name           = local.name
  cluster_arn    = aws_ecs_cluster.this.arn
  cluster_name   = aws_ecs_cluster.this.name
  vpc_id         = module.network.vpc_id
  subnet_ids     = module.network.private_subnet_ids
  namespace_id   = aws_service_discovery_private_dns_namespace.this.id
  namespace_name = aws_service_discovery_private_dns_namespace.this.name
  images = {
    prometheus   = local.image_uri.prometheus
    alertmanager = local.image_uri.alertmanager
    loki         = local.image_uri.loki
    grafana      = local.image_uri.grafana
  }
  alarm_sns_topic_arn = aws_sns_topic.alerts.arn

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

# Loki accepts pushes from the API's FireLens sidecar. Declared here (not via
# the module input) to avoid a dependency cycle between module.api and module.observability.
resource "aws_vpc_security_group_ingress_rule" "loki_from_api" {
  security_group_id            = module.observability.security_group_id
  description                  = "FireLens in API tasks pushes logs to Loki"
  referenced_security_group_id = module.api.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3100
  to_port                      = 3100
}
