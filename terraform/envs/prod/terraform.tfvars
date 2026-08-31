# Environment-specific values. Nothing secret lives here; secrets are generated
# in AWS Secrets Manager at apply time and never touch the repository.

region      = "us-east-1"
project     = "release-demo"
environment = "prod"

github_repository = "JhamelT/aws-end-to-end-cicd"
github_branch     = "main"

domain_name = "jhamelthedevopseng.com"
subdomain   = "app"

desired_count = 2
min_capacity  = 2
max_capacity  = 6

canary_percentage             = 10
canary_interval_minutes       = 2
blue_termination_wait_minutes = 5

enable_waf = true

# Set in an untracked file or on the command line:
#   terraform apply -var 'notification_email=you@example.com' -var 'admin_cidrs=["203.0.113.4/32"]'
