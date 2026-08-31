# Alarms, notifications and a dashboard.
#
# Rollback alarms are deliberately measured at the *load balancer* level, not
# per target group. After every blue/green deployment the production target
# group flips; an alarm pinned to "the blue TG" would spend half its life
# watching an idle target group. Per-TG alarms are still created for host health.

variable "name" { type = string }
variable "alb_arn_suffix" { type = string }
variable "blue_target_group_arn_suffix" { type = string }
variable "green_target_group_arn_suffix" { type = string }
variable "cluster_name" { type = string }
variable "service_name" { type = string }
variable "notification_email" { type = string }
variable "kms_key_arn" { type = string }

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# --------------------------------------------------------------------------- #
# Notifications                                                                #
# --------------------------------------------------------------------------- #
resource "aws_sns_topic" "ops" {
  name              = "${var.name}-ops"
  kms_master_key_id = var.kms_key_arn # key policy grants events/cloudwatch the right to use it
}

resource "aws_sns_topic_policy" "ops" {
  arn = aws_sns_topic.ops.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgeAndCloudWatch"
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "cloudwatch.amazonaws.com"] }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.ops.arn
      },
      {
        Sid       = "AccountOwner"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes"]
        Resource  = aws_sns_topic.ops.arn
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.ops.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# --------------------------------------------------------------------------- #
# Rollback alarms (attached to the CodeDeploy deployment group)                #
# --------------------------------------------------------------------------- #
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name}-alb-target-5xx"
  alarm_description   = "Targets returned >= 5 5XX responses in a minute (either color)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  alarm_actions       = [aws_sns_topic.ops.arn]
  ok_actions          = [aws_sns_topic.ops.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  alarm_name          = "${var.name}-alb-p95-latency"
  alarm_description   = "p95 target response time above 1s"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  alarm_actions       = [aws_sns_topic.ops.arn]
  ok_actions          = [aws_sns_topic.ops.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  for_each = {
    blue  = var.blue_target_group_arn_suffix
    green = var.green_target_group_arn_suffix
  }
  alarm_name          = "${var.name}-${each.key}-unhealthy-hosts"
  alarm_description   = "Unhealthy targets in the ${each.key} target group"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = each.value
  }
  alarm_actions = [aws_sns_topic.ops.arn]
  ok_actions    = [aws_sns_topic.ops.arn]
}

# --------------------------------------------------------------------------- #
# Operational alarms (paging, not rollback)                                    #
# --------------------------------------------------------------------------- #
resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name          = "${var.name}-ecs-cpu-high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  alarm_actions       = [aws_sns_topic.ops.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  alarm_name          = "${var.name}-ecs-memory-high"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  alarm_actions       = [aws_sns_topic.ops.arn]
}

# --------------------------------------------------------------------------- #
# Pipeline + deployment events -> email                                        #
# --------------------------------------------------------------------------- #
resource "aws_cloudwatch_event_rule" "pipeline" {
  name        = "${var.name}-pipeline-state"
  description = "CodePipeline execution state changes"
  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    detail-type = ["CodePipeline Pipeline Execution State Change"]
    detail = {
      pipeline = [var.name]
      state    = ["STARTED", "SUCCEEDED", "FAILED", "CANCELED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "pipeline" {
  rule = aws_cloudwatch_event_rule.pipeline.name
  arn  = aws_sns_topic.ops.arn
  input_transformer {
    input_paths    = { pipeline = "$.detail.pipeline", state = "$.detail.state", id = "$.detail.execution-id" }
    input_template = "\"[<pipeline>] pipeline execution <state> (execution <id>)\""
  }
}

resource "aws_cloudwatch_event_rule" "deployment" {
  name        = "${var.name}-deployment-state"
  description = "CodeDeploy deployment state changes"
  event_pattern = jsonencode({
    source      = ["aws.codedeploy"]
    detail-type = ["CodeDeploy Deployment State-change Notification"]
    detail = {
      application = [var.name]
    }
  })
}

resource "aws_cloudwatch_event_target" "deployment" {
  rule = aws_cloudwatch_event_rule.deployment.name
  arn  = aws_sns_topic.ops.arn
  input_transformer {
    input_paths    = { app = "$.detail.application", state = "$.detail.state", id = "$.detail.deploymentId", group = "$.detail.deploymentGroup" }
    input_template = "\"[<app>/<group>] deployment <id> <state>\""
  }
}

# --------------------------------------------------------------------------- #
# Dashboard                                                                    #
# --------------------------------------------------------------------------- #
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Requests & errors (ALB)"
          region = data.aws_region.current.name
          stat   = "Sum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", { color = "#d62728" }],
            [".", "HTTPCode_Target_4XX_Count", ".", ".", { color = "#ff7f0e" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Latency p50 / p95 / p99"
          region = data.aws_region.current.name
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50" }],
            ["...", { stat = "p95" }],
            ["...", { stat = "p99" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Healthy hosts by target group (watch the swap during a deploy)"
          region = data.aws_region.current.name
          stat   = "Average", period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.blue_target_group_arn_suffix, { label = "blue", color = "#1f77b4" }],
            ["...", var.green_target_group_arn_suffix, { label = "green", color = "#2ca02c" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "ECS service CPU / memory"
          region = data.aws_region.current.name
          stat   = "Average", period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name],
            [".", "MemoryUtilization", ".", ".", ".", "."]
          ]
        }
      }
    ]
  })
}

output "topic_arn" { value = aws_sns_topic.ops.arn }
output "rollback_alarm_names" {
  value = concat(
    [aws_cloudwatch_metric_alarm.alb_5xx.alarm_name, aws_cloudwatch_metric_alarm.alb_latency.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.unhealthy_hosts : a.alarm_name]
  )
}
output "dashboard_name" { value = aws_cloudwatch_dashboard.this.dashboard_name }
