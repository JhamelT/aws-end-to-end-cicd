locals {
  name           = "${var.project}-${var.environment}"
  container_name = "api"
  container_port = 8000
  use_domain     = var.domain_name != ""
}

# --------------------------------------------------------------------------- #
# One customer-managed key for everything this stack encrypts at rest          #
# (pipeline artifacts, ECR images, the app secret).                            #
# --------------------------------------------------------------------------- #
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "kms" {
  # Account administrators manage the key; IAM policies then govern use.
  statement {
    sid       = "EnableIAMUserPermissions"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
  # Services that publish to the encrypted SNS topic on our behalf.
  statement {
    sid       = "AllowEventPublishersToUseKey"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "cloudwatch.amazonaws.com", "codestar-notifications.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "${local.name} data key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.this.key_id
}

# --------------------------------------------------------------------------- #
# Modules                                                                      #
# --------------------------------------------------------------------------- #
module "network" {
  source   = "../../modules/network"
  name     = local.name
  vpc_cidr = var.vpc_cidr
  az_count = var.az_count
}

module "dns" {
  count       = local.use_domain ? 1 : 0
  source      = "../../modules/dns"
  domain_name = var.domain_name
  subdomain   = var.subdomain
}

module "ecr" {
  source      = "../../modules/ecr"
  name        = local.name
  kms_key_arn = aws_kms_key.this.arn
}

module "alb" {
  source             = "../../modules/alb"
  name               = local.name
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  container_port     = local.container_port
  certificate_arn    = local.use_domain ? module.dns[0].certificate_arn : ""
  enable_waf         = var.enable_waf
  log_retention_days = var.log_retention_days
  # The validation Lambda egresses through the NAT, so its source IP is the NAT EIP.
  test_listener_cidrs = concat(["${module.network.nat_public_ip}/32"], var.admin_cidrs)
}

resource "aws_route53_record" "app" {
  count   = local.use_domain ? 1 : 0
  zone_id = module.dns[0].zone_id
  name    = module.dns[0].fqdn
  type    = "A"
  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

module "ecs" {
  source                    = "../../modules/ecs"
  name                      = local.name
  environment               = var.environment
  container_name            = local.container_name
  container_port            = local.container_port
  private_subnet_ids        = module.network.private_subnet_ids
  service_security_group_id = module.alb.service_security_group_id
  blue_target_group_arn     = module.alb.blue_target_group_arn
  ecr_repository_arn        = module.ecr.repository_arn
  kms_key_arn               = aws_kms_key.this.arn
  task_cpu                  = var.task_cpu
  task_memory               = var.task_memory
  desired_count             = var.desired_count
  min_capacity              = var.min_capacity
  max_capacity              = var.max_capacity
  cpu_target_utilization    = var.cpu_target_utilization
  log_retention_days        = var.log_retention_days

  # ECS refuses to create a service whose target group is not yet attached to a listener.
  depends_on = [module.alb]
}

module "observability" {
  source                        = "../../modules/observability"
  name                          = local.name
  alb_arn_suffix                = module.alb.alb_arn_suffix
  blue_target_group_arn_suffix  = module.alb.blue_target_group_arn_suffix
  green_target_group_arn_suffix = module.alb.green_target_group_arn_suffix
  cluster_name                  = module.ecs.cluster_name
  service_name                  = module.ecs.service_name
  notification_email            = var.notification_email
  kms_key_arn                   = aws_kms_key.this.arn
}

module "codedeploy" {
  source                        = "../../modules/codedeploy"
  name                          = local.name
  cluster_name                  = module.ecs.cluster_name
  service_name                  = module.ecs.service_name
  prod_listener_arn             = module.alb.prod_listener_arn
  test_listener_arn             = module.alb.test_listener_arn
  blue_target_group_name        = module.alb.blue_target_group_name
  green_target_group_name       = module.alb.green_target_group_name
  test_endpoint                 = module.alb.test_endpoint
  rollback_alarm_names          = module.observability.rollback_alarm_names
  canary_percentage             = var.canary_percentage
  canary_interval_minutes       = var.canary_interval_minutes
  blue_termination_wait_minutes = var.blue_termination_wait_minutes
  private_subnet_ids            = module.network.private_subnet_ids
  vpc_id                        = module.network.vpc_id
  hook_source_dir               = "${path.root}/../../../pipeline/hooks/validate_green"
  log_retention_days            = var.log_retention_days
}

module "pipeline" {
  source                            = "../../modules/pipeline"
  name                              = local.name
  environment                       = var.environment
  github_repository                 = var.github_repository
  github_branch                     = var.github_branch
  kms_key_arn                       = aws_kms_key.this.arn
  ecr_repository_url                = module.ecr.repository_url
  ecr_repository_arn                = module.ecr.repository_arn
  ecr_repository_name               = module.ecr.repository_name
  container_name                    = local.container_name
  task_family                       = module.ecs.task_family
  task_execution_role_arn           = module.ecs.execution_role_arn
  task_role_arn                     = module.ecs.task_role_arn
  app_log_group                     = module.ecs.log_group_name
  app_secret_arn                    = module.ecs.app_secret_arn
  task_cpu                          = var.task_cpu
  task_memory                       = var.task_memory
  validation_lambda_name            = module.codedeploy.hook_function_name
  codedeploy_app_name               = module.codedeploy.app_name
  codedeploy_deployment_group_name  = module.codedeploy.deployment_group_name
  codedeploy_deployment_config_name = module.codedeploy.deployment_config_name
  notification_topic_arn            = module.observability.topic_arn
  log_retention_days                = var.log_retention_days
}
