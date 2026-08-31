variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  description = "Short name used as a prefix for every resource."
  type        = string
  default     = "release-demo"
}

variable "environment" {
  type    = string
  default = "prod"
}

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------
variable "github_repository" {
  description = "owner/repo that CodePipeline watches."
  type        = string
  default     = "JhamelT/aws-end-to-end-cicd"
}

variable "github_branch" {
  type    = string
  default = "main"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to spread public/private subnets across."
  type        = number
  default     = 2
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the ALB test listener (8080) directly, e.g. your home IP/32. The validation Lambda is allowed automatically."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# DNS / TLS
# ---------------------------------------------------------------------------
variable "domain_name" {
  description = "Route 53 hosted zone name (registered domain). Leave empty for an HTTP-only ALB."
  type        = string
  default     = ""
}

variable "subdomain" {
  description = "Host label for the app, e.g. 'app' -> app.<domain_name>."
  type        = string
  default     = "app"
}

# ---------------------------------------------------------------------------
# Service sizing
# ---------------------------------------------------------------------------
variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "min_capacity" {
  type    = number
  default = 2
}

variable "max_capacity" {
  type    = number
  default = 6
}

variable "cpu_target_utilization" {
  type    = number
  default = 60
}

# ---------------------------------------------------------------------------
# Release controls
# ---------------------------------------------------------------------------
variable "canary_percentage" {
  description = "Share of production traffic sent to green first."
  type        = number
  default     = 10
}

variable "canary_interval_minutes" {
  description = "Minutes green must hold the canary share before receiving 100%."
  type        = number
  default     = 2
}

variable "blue_termination_wait_minutes" {
  description = "Bake period: how long the old task set stays warm after the shift, so a rollback is a listener swap instead of a redeploy."
  type        = number
  default     = 5
}

variable "enable_waf" {
  type    = bool
  default = true
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
variable "notification_email" {
  description = "Receives approval requests, build/deploy failures, and rollback notices. Confirm the SNS subscription email after apply."
  type        = string
}

variable "log_retention_days" {
  type    = number
  default = 30
}
