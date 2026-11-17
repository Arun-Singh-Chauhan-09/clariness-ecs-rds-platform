data "aws_region" "current" {}

locals {
  container_name = "app"

  app_log_configuration = var.firelens != null ? {
    logDriver = "awsfirelens"
    options   = null
    } : {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.this.name
      awslogs-region        = data.aws_region.current.name
      awslogs-stream-prefix = "app"
    }
  }

  app_container = {
    name                   = local.container_name
    image                  = var.image
    essential              = true
    command                = var.command
    readonlyRootFilesystem = var.readonly_root_filesystem
    portMappings = var.container_port == null ? [] : [{
      name          = "http"
      containerPort = var.container_port
      protocol      = "tcp"
    }]
    environment = [for k in sort(keys(var.environment)) : { name = k, value = var.environment[k] }]
    secrets     = [for k in sort(keys(var.secrets)) : { name = k, valueFrom = var.secrets[k] }]
    # init process reaps zombie processes and is required for ECS Exec.
    linuxParameters = { initProcessEnabled = true }
    healthCheck = var.health_check == null ? null : {
      command     = var.health_check.command
      interval    = var.health_check.interval
      timeout     = var.health_check.timeout
      retries     = var.health_check.retries
      startPeriod = var.health_check.start_period
    }
    logConfiguration = local.app_log_configuration
    dependsOn        = var.firelens == null ? null : [{ containerName = "log_router", condition = "START" }]
  }

  log_router_container = var.firelens == null ? null : {
    name              = "log_router"
    image             = var.firelens.image
    essential         = true
    memoryReservation = 64
    environment       = [for k in sort(keys(var.firelens.environment)) : { name = k, value = var.firelens.environment[k] }]
    firelensConfiguration = {
      type = "fluentbit"
      options = {
        "config-file-type"        = "file"
        "config-file-value"       = "/fluent-bit/etc/firelens.conf"
        "enable-ecs-log-metadata" = "true"
      }
    }
    # The router's own logs go to CloudWatch, so a broken Loki is still debuggable.
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "firelens"
      }
    }
  }

  containers = compact([jsonencode(local.app_container), local.log_router_container == null ? "" : jsonencode(local.log_router_container)])
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
}

# --- IAM ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: used by the ECS agent to pull the image, write awslogs and
# fetch secrets before the container starts.
resource "aws_iam_role" "execution" {
  name               = "${var.name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.execution_secret_arns) > 0 ? 1 : 0

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.execution_secret_arns
  }

  dynamic "statement" {
    for_each = length(var.execution_kms_key_arns) > 0 ? [1] : []
    content {
      actions   = ["kms:Decrypt"]
      resources = var.execution_kms_key_arns
    }
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count  = length(var.execution_secret_arns) > 0 ? 1 : 0
  name   = "read-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

# Task role: what the application itself (and the FireLens sidecar) may call.
resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "ecs_exec" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ecs_exec" {
  count  = var.enable_execute_command ? 1 : 0
  name   = "ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.ecs_exec.json
}

resource "aws_iam_role_policy" "task_custom" {
  count  = var.task_role_policy_json == null ? 0 : 1
  name   = "app"
  role   = aws_iam_role.task.id
  policy = var.task_role_policy_json
}

# --- Network -------------------------------------------------------------------------
resource "aws_security_group" "this" {
  name        = var.name
  description = "ECS tasks of ${var.name}"
  vpc_id      = var.vpc_id
  tags        = { Name = var.name }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Outbound: ECR, Secrets Manager, CloudWatch, RDS, peers"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = var.container_port == null ? {} : { for i, r in var.ingress_rules : tostring(i) => r }

  security_group_id            = aws_security_group.this.id
  description                  = each.value.description
  referenced_security_group_id = each.value.source_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}

# --- Task definition ---------------------------------------------------------------
resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = "[${join(",", local.containers)}]"

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # Fargate Spot does not support ARM64
  }
}

# --- Service discovery (Cloud Map) -------------------------------------------------------
resource "aws_service_discovery_service" "this" {
  count = var.create_service && var.service_discovery_namespace_id != null ? 1 : 0
  name  = coalesce(var.service_discovery_name, var.name)

  dns_config {
    namespace_id   = var.service_discovery_namespace_id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

# --- Service -------------------------------------------------------------------------
resource "aws_ecs_service" "this" {
  count = var.create_service ? 1 : 0

  name                    = var.name
  cluster                 = var.cluster_arn
  task_definition         = aws_ecs_task_definition.this.arn
  desired_count           = var.desired_count
  enable_execute_command  = var.enable_execute_command
  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true
  wait_for_steady_state   = var.wait_for_steady_state

  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent
  health_check_grace_period_seconds  = var.target_group_arn == null ? null : var.health_check_grace_period_seconds

  # New tasks that keep failing (crash, failed health checks) stop the
  # deployment, and ECS rolls back to the last task definition that worked.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider
    weight            = 1
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = concat([aws_security_group.this.id], var.additional_security_group_ids)
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [1]
    content {
      target_group_arn = var.target_group_arn
      container_name   = local.container_name
      container_port   = var.container_port
    }
  }

  dynamic "service_registries" {
    for_each = aws_service_discovery_service.this
    content {
      registry_arn = service_registries.value.arn
    }
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}

# --- Autoscaling -----------------------------------------------------------------------
resource "aws_appautoscaling_target" "this" {
  count              = var.create_service && var.autoscaling != null ? 1 : 0
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this[0].name}"
  min_capacity       = var.autoscaling.min_capacity
  max_capacity       = var.autoscaling.max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  count              = length(aws_appautoscaling_target.this)
  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  resource_id        = aws_appautoscaling_target.this[0].resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling.cpu_target_percent
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
