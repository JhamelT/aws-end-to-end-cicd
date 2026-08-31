output "app_url" {
  description = "Production endpoint"
  value       = local.use_domain ? "https://${module.dns[0].fqdn}" : "http://${module.alb.alb_dns_name}"
}

output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "test_endpoint" {
  description = "Green validation endpoint (reachable only from the validation Lambda and admin_cidrs)"
  value       = module.alb.test_endpoint
}

output "pipeline_name" {
  value = module.pipeline.pipeline_name
}

output "github_connection_arn" {
  value = module.pipeline.connection_arn
}

output "github_connection_status" {
  description = "Must be AVAILABLE. If PENDING, finish the GitHub App handshake in the console (Developer Tools -> Settings -> Connections)."
  value       = module.pipeline.connection_status
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "ecs_cluster" {
  value = module.ecs.cluster_name
}

output "ecs_service" {
  value = module.ecs.service_name
}

output "codedeploy_application" {
  value = module.codedeploy.app_name
}

output "codedeploy_deployment_config" {
  value = module.codedeploy.deployment_config_name
}

output "rollback_alarms" {
  value = module.observability.rollback_alarm_names
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${module.observability.dashboard_name}"
}

output "nat_public_ip" {
  value = module.network.nat_public_ip
}
