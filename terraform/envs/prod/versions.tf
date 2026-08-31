terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Bucket/region are supplied at init time so this file has no account-specific values:
  #   terraform init -backend-config="bucket=<from bootstrap>" -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
  backend "s3" {
    key     = "envs/prod/terraform.tfstate"
    encrypt = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = var.github_repository
      CostCenter  = "portfolio"
    }
  }
}
