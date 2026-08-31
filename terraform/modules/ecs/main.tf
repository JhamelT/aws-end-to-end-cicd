# ECS Fargate service under CodeDeploy's control.
#
# Two IAM roles, on purpose:
#   task execution role -> what ECS itself needs to *start* the task
#                          (pull from ECR, read the secret, write logs)
#   task role           -> what the *application* is allowed to call (nothing, today)
# Collapsing them into one "ecs role" is the most common IAM smell in ECS setups.

variable "name" { type = string }
variable "container_name" { type = string }
variable "container_port" { type = number }
variable "private_subnet_ids" { type = list(string) }
variable "service_security_group_id" { type = string }
variable "blue_target_group_arn" { type = string }
variable "ecr_repository_arn" { type = string }
variable "kms_key_arn" { type = string }
variable "task_cpu" { type = number }
variable "task_memory" { type = number }
variable "desired_count" { type = number }
variable "min_capacity" { type = number }
variable "max_capacity" { type = number }
variable "cpu_target_utilization" { type = number }
variable "log_retention_days" { type = number }
variable "environment" { type = string }

data "aws_region" "current" {}

# --------------------------------------------------------------------------- #
# Cluster + logs                                                               #
# --------------------------------------------------------------------------- #
resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enhanced"
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

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
}

# --------------------------------------------------------------------------- #
# Application secret (generated here, rotated in AWS, never in git)            #
# --------------------------------------------------------------------------- #
resource "random_password" "app_api_key" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.name}/${var.environment}/app-api-key"
  description             = "Injected into the container as APP_API_KEY"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 0 # portfolio env: allow immediate re-create after destroy
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = random_password.app_api_key.result
}

# --------------------------------------------------------------------------- #
# IAM                                                                          #
# --------------------------------------------------------------------------- #
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [var.ecr_repository_arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
  statement {
    sid       = "ReadAppSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app.arn]
  }
  statement {
    sid       = "DecryptWithProjectKey"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "execution" {
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}
# Intentionally no policy attached: the app calls no AWS APIs. When it does,
# grant exactly that here — never on the execution role.

# --------------------------------------------------------------------------- #
# Bootstrap task definition                                                    #
# --------------------------------------------------------------------------- #
# The ECR repository is empty at first apply, so the service starts on a
# public placeholder that answers /health. The pipeline's first run performs a
# real blue/green deployment from this placeholder to the first built image.
# After that, Terraform never touches the task definition again (see ignore_changes).
resource "aws_ecs_task_definition" "bootstrap" {
  family                   = var.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = var.container_name
    image     = "public.ecr.aws/docker/library/python:3.12-slim"
    essential = true
    command = ["sh", "-c",
      "mkdir -p /srv && cd /srv && printf '{\"status\":\"bootstrap\"}' > health && printf '{\"version\":\"bootstrap\",\"commit\":\"none\"}' > version && exec python -m http.server ${var.container_port}"
    ]
    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
    environment  = [{ name = "APP_VERSION", value = "bootstrap" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "bootstrap"
      }
    }
  }])
}

# --------------------------------------------------------------------------- #
# Service                                                                      #
# --------------------------------------------------------------------------- #
resource "aws_ecs_service" "this" {
  name             = var.name
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.bootstrap.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  health_check_grace_period_seconds = 60
  enable_execute_command            = false

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.service_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.blue_target_group_arn
    container_name   = var.container_name
    container_port   = var.container_port
  }

  # CodeDeploy owns the task definition and the target-group binding after the
  # first deployment; autoscaling owns desired_count. Terraform must not fight them.
  lifecycle {
    ignore_changes = [task_definition, load_balancer, desired_count]
  }
}

# --------------------------------------------------------------------------- #
# Auto scaling                                                                 #
# --------------------------------------------------------------------------- #
resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_utilization
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.name}-memory-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 75
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}

output "cluster_name" { value = aws_ecs_cluster.this.name }
output "cluster_arn" { value = aws_ecs_cluster.this.arn }
output "service_name" { value = aws_ecs_service.this.name }
output "task_family" { value = aws_ecs_task_definition.bootstrap.family }
output "execution_role_arn" { value = aws_iam_role.execution.arn }
output "task_role_arn" { value = aws_iam_role.task.arn }
output "log_group_name" { value = aws_cloudwatch_log_group.app.name }
output "log_group_arn" { value = aws_cloudwatch_log_group.app.arn }
output "app_secret_arn" { value = aws_secretsmanager_secret.app.arn }
