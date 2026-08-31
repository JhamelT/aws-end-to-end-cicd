# CodeDeploy: the deployment controller for ECS blue/green.
#
# Flow per release:
#   1. Register green task set from the new task definition
#   2. Attach green to the TEST listener (8080)
#   3. AfterAllowTestTraffic hook -> validation Lambda hits green through 8080
#   4. Shift production traffic: canary X% for N minutes, then 100%
#   5. Bake: blue stays warm for `blue_termination_wait_minutes`
#   6. Terminate blue
# Any hook failure, deployment failure, or alarm in ALARM state -> automatic rollback.

variable "name" { type = string }
variable "cluster_name" { type = string }
variable "service_name" { type = string }
variable "prod_listener_arn" { type = string }
variable "test_listener_arn" { type = string }
variable "blue_target_group_name" { type = string }
variable "green_target_group_name" { type = string }
variable "test_endpoint" { type = string }
variable "rollback_alarm_names" { type = list(string) }
variable "canary_percentage" { type = number }
variable "canary_interval_minutes" { type = number }
variable "blue_termination_wait_minutes" { type = number }
variable "private_subnet_ids" { type = list(string) }
variable "vpc_id" { type = string }
variable "hook_source_dir" { type = string }
variable "log_retention_days" { type = number }

# --------------------------------------------------------------------------- #
# Validation hook Lambda                                                       #
# --------------------------------------------------------------------------- #
data "archive_file" "hook" {
  type        = "zip"
  source_dir  = var.hook_source_dir
  output_path = "${path.module}/.build/validate_green.zip"
}

resource "aws_security_group" "hook" {
  name        = "${var.name}-validation-hook"
  description = "Validation Lambda egress"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "hook_all" {
  security_group_id = aws_security_group.hook.id
  description       = "Reach the ALB test listener via NAT and AWS APIs"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hook" {
  name               = "${var.name}-validation-hook"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "hook_vpc" {
  role       = aws_iam_role.hook.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "hook" {
  role = aws_iam_role.hook.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReportBackToCodeDeploy"
        Effect   = "Allow"
        Action   = ["codedeploy:PutLifecycleEventHookExecutionStatus", "codedeploy:GetDeployment"]
        Resource = "*"
      },
      {
        Sid      = "ReadTaskSetsAndDefinitions"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition", "ecs:DescribeServices"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "hook" {
  name              = "/aws/lambda/${var.name}-validate-green"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "hook" {
  function_name    = "${var.name}-validate-green"
  description      = "CodeDeploy AfterAllowTestTraffic hook: validates the green task set before any production traffic moves"
  role             = aws_iam_role.hook.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.hook.output_path
  source_code_hash = data.archive_file.hook.output_base64sha256
  timeout          = 120
  memory_size      = 256
  # One deployment validates at a time; this also caps blast radius if the hook misbehaves.
  reserved_concurrent_executions = 1

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.hook.id]
  }

  environment {
    variables = {
      TEST_ENDPOINT    = var.test_endpoint
      CLUSTER_NAME     = var.cluster_name
      SERVICE_NAME     = var.service_name
      MAX_WAIT_SECONDS = "90"
    }
  }

  depends_on = [aws_cloudwatch_log_group.hook, aws_iam_role_policy_attachment.hook_vpc]
}

# --------------------------------------------------------------------------- #
# CodeDeploy                                                                   #
# --------------------------------------------------------------------------- #
data "aws_iam_policy_document" "codedeploy_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "${var.name}-codedeploy"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume.json
}

resource "aws_iam_role_policy_attachment" "codedeploy_ecs" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

resource "aws_codedeploy_app" "this" {
  name             = var.name
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_config" "canary" {
  deployment_config_name = "${var.name}-canary-${var.canary_percentage}pct-${var.canary_interval_minutes}min"
  compute_platform       = "ECS"

  traffic_routing_config {
    type = "TimeBasedCanary"
    time_based_canary {
      interval   = var.canary_interval_minutes
      percentage = var.canary_percentage
    }
  }
}

resource "aws_codedeploy_deployment_group" "this" {
  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = var.name
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = aws_codedeploy_deployment_config.canary.deployment_config_name

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = var.cluster_name
    service_name = var.service_name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [var.prod_listener_arn]
      }
      test_traffic_route {
        listener_arns = [var.test_listener_arn]
      }
      target_group {
        name = var.blue_target_group_name
      }
      target_group {
        name = var.green_target_group_name
      }
    }
  }

  blue_green_deployment_config {
    deployment_ready_option {
      # Production shift proceeds automatically once the hook passes. The human
      # gate is the CodePipeline approval *before* this deployment starts.
      # Alternative: STOP_DEPLOYMENT + wait_time_in_minutes for a second human gate here.
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = var.blue_termination_wait_minutes
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM", "DEPLOYMENT_STOP_ON_REQUEST"]
  }

  alarm_configuration {
    enabled                   = true
    alarms                    = var.rollback_alarm_names
    ignore_poll_alarm_failure = false
  }

  depends_on = [aws_iam_role_policy_attachment.codedeploy_ecs]
}

output "app_name" { value = aws_codedeploy_app.this.name }
output "deployment_group_name" { value = aws_codedeploy_deployment_group.this.deployment_group_name }
output "deployment_config_name" { value = aws_codedeploy_deployment_config.canary.deployment_config_name }
output "hook_function_name" { value = aws_lambda_function.hook.function_name }
output "hook_function_arn" { value = aws_lambda_function.hook.arn }
output "codedeploy_role_arn" { value = aws_iam_role.codedeploy.arn }
