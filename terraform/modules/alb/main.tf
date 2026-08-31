# Application Load Balancer with the four pieces blue/green needs:
#   - production listener (443, or 80 when no certificate)
#   - test listener (8080) that only the validation Lambda / admins can reach
#   - blue target group
#   - green target group
#
# CodeDeploy swaps which target group each listener points at during a
# deployment, so Terraform must ignore default_action drift on both listeners
# or the next `apply` would "fix" production back to the old task set.

variable "name" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "container_port" { type = number }
variable "certificate_arn" {
  type    = string
  default = ""
}
variable "test_listener_cidrs" {
  description = "CIDRs allowed to hit the test listener."
  type        = list(string)
}
variable "enable_waf" { type = bool }
variable "log_retention_days" { type = number }

locals {
  https = var.certificate_arn != ""
}

# --------------------------------------------------------------------------- #
# Security groups                                                              #
# --------------------------------------------------------------------------- #
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public entry point"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere (redirects to HTTPS when a cert is present)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count             = local.https ? 1 : 0
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from anywhere"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# count, not for_each: the first CIDR is the NAT EIP, unknown until apply,
# and for_each keys must be known at plan time.
resource "aws_vpc_security_group_ingress_rule" "alb_test" {
  count             = length(var.test_listener_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "Test listener: validation hook + admins only"
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
  cidr_ipv4         = var.test_listener_cidrs[count.index]
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "To targets in the VPC"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "service" {
  name        = "${var.name}-service"
  description = "ECS tasks: only the ALB may talk to them"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-service" }
}

resource "aws_vpc_security_group_ingress_rule" "service_from_alb" {
  security_group_id            = aws_security_group.service.id
  description                  = "App port from the ALB only"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "service_all" {
  security_group_id = aws_security_group.service.id
  description       = "Outbound via NAT for ECR/Logs/Secrets"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --------------------------------------------------------------------------- #
# Load balancer + target groups                                                #
# --------------------------------------------------------------------------- #
resource "aws_lb" "this" {
  name                       = var.name
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true
  enable_deletion_protection = false
  idle_timeout               = 60

  access_logs {
    bucket  = aws_s3_bucket.access_logs.bucket
    prefix  = "alb"
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.access_logs]
}

# --------------------------------------------------------------------------- #
# ALB access logs                                                              #
# --------------------------------------------------------------------------- #
data "aws_elb_service_account" "this" {}
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "access_logs" {
  bucket        = "${var.name}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # ELB log delivery does not support SSE-KMS
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.log_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ELBLogDelivery"
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.this.arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.access_logs.arn, "${aws_s3_bucket.access_logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.access_logs]
}

resource "aws_lb_target_group" "color" {
  for_each             = toset(["blue", "green"])
  name                 = "${var.name}-${each.key}"
  port                 = var.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Color = each.key }
}

# Production listener. Starts on blue; CodeDeploy takes it from here.
resource "aws_lb_listener" "prod" {
  load_balancer_arn = aws_lb.this.arn
  port              = local.https ? 443 : 80
  protocol          = local.https ? "HTTPS" : "HTTP"
  ssl_policy        = local.https ? "ELBSecurityPolicy-TLS13-1-2-2021-06" : null
  certificate_arn   = local.https ? var.certificate_arn : null

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.color["blue"].arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

resource "aws_lb_listener" "http_redirect" {
  count             = local.https ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Test listener. Starts on green; CodeDeploy points it at whichever task set is
# under validation.
resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.this.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.color["green"].arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

# --------------------------------------------------------------------------- #
# WAF (optional)                                                               #
# --------------------------------------------------------------------------- #
resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0
  name  = var.name
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = {
      AWSManagedRulesCommonRuleSet          = 10
      AWSManagedRulesKnownBadInputsRuleSet  = 20
      AWSManagedRulesAmazonIpReputationList = 30
    }
    content {
      name     = rule.key
      priority = rule.value
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = "AWS"
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "RateLimitPerIP"
    priority = 40
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIP"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudwatch_log_group" "waf" {
  count             = var.enable_waf ? 1 : 0
  name              = "aws-waf-logs-${var.name}" # WAF requires this prefix
  retention_in_days = var.log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count                   = var.enable_waf ? 1 : 0
  resource_arn            = aws_wafv2_web_acl.this[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]
}

resource "aws_wafv2_web_acl_association" "this" {
  count        = var.enable_waf ? 1 : 0
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}

output "alb_arn" { value = aws_lb.this.arn }
output "alb_arn_suffix" { value = aws_lb.this.arn_suffix }
output "alb_dns_name" { value = aws_lb.this.dns_name }
output "alb_zone_id" { value = aws_lb.this.zone_id }
output "alb_security_group_id" { value = aws_security_group.alb.id }
output "service_security_group_id" { value = aws_security_group.service.id }
output "prod_listener_arn" { value = aws_lb_listener.prod.arn }
output "test_listener_arn" { value = aws_lb_listener.test.arn }
output "blue_target_group_arn" { value = aws_lb_target_group.color["blue"].arn }
output "blue_target_group_name" { value = aws_lb_target_group.color["blue"].name }
output "blue_target_group_arn_suffix" { value = aws_lb_target_group.color["blue"].arn_suffix }
output "green_target_group_name" { value = aws_lb_target_group.color["green"].name }
output "green_target_group_arn_suffix" { value = aws_lb_target_group.color["green"].arn_suffix }
output "test_endpoint" { value = "http://${aws_lb.this.dns_name}:8080" }
