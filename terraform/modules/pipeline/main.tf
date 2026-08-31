# Delivery pipeline: GitHub -> CodePipeline (V2) -> CodeBuild -> [approval] -> CodeDeploy ECS blue/green.

variable "name" { type = string }
variable "github_repository" { type = string }
variable "github_branch" { type = string }
variable "existing_connection_arn" {
  description = "Reuse an existing, AVAILABLE CodeConnections connection instead of creating one. Connections are account-level shared resources and need a one-time human handshake, so reuse is the norm."
  type        = string
  default     = ""
}
variable "kms_key_arn" { type = string }
variable "ecr_repository_url" { type = string }
variable "ecr_repository_arn" { type = string }
variable "ecr_repository_name" { type = string }
variable "container_name" { type = string }
variable "task_family" { type = string }
variable "task_execution_role_arn" { type = string }
variable "task_role_arn" { type = string }
variable "app_log_group" { type = string }
variable "app_secret_arn" { type = string }
variable "environment" { type = string }
variable "task_cpu" { type = number }
variable "task_memory" { type = number }
variable "validation_lambda_name" { type = string }
variable "codedeploy_app_name" { type = string }
variable "codedeploy_deployment_group_name" { type = string }
variable "codedeploy_deployment_config_name" { type = string }
variable "notification_topic_arn" { type = string }
variable "log_retention_days" { type = number }

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --------------------------------------------------------------------------- #
# Artifact store                                                               #
# --------------------------------------------------------------------------- #
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name}-pipeline-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

# --------------------------------------------------------------------------- #
# GitHub connection (GitHub App). If not reusing one, it is created PENDING:   #
# the handshake must be completed once in the console -> Developer Tools ->    #
# Connections. Note the resource yields a legacy codestar-connections ARN;     #
# a console-created connection yields a codeconnections ARN.                   #
# --------------------------------------------------------------------------- #
resource "aws_codestarconnections_connection" "github" {
  count         = var.existing_connection_arn == "" ? 1 : 0
  name          = "${var.name}-github"
  provider_type = "GitHub"
}

locals {
  connection_arn = var.existing_connection_arn != "" ? var.existing_connection_arn : aws_codestarconnections_connection.github[0].arn
}

# --------------------------------------------------------------------------- #
# CodeBuild                                                                    #
# --------------------------------------------------------------------------- #
resource "aws_cloudwatch_log_group" "build" {
  name              = "/aws/codebuild/${var.name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.name}-codebuild"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

data "aws_iam_policy_document" "codebuild" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.build.arn}:*"]
  }
  statement {
    sid       = "Artifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    sid       = "ArtifactEncryption"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage",
      "ecr:DescribeImages"
    ]
    resources = [var.ecr_repository_arn]
  }
  statement {
    sid       = "TestReports"
    actions   = ["codebuild:CreateReportGroup", "codebuild:CreateReport", "codebuild:UpdateReport", "codebuild:BatchPutTestCases", "codebuild:BatchPutCodeCoverages"]
    resources = ["arn:aws:codebuild:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:report-group/${var.name}-*"]
  }
}

resource "aws_iam_role_policy" "codebuild" {
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild.json
}

resource "aws_codebuild_project" "this" {
  name           = var.name
  description    = "Test, scan, build and publish the ${var.name} image"
  service_role   = aws_iam_role.codebuild.arn
  build_timeout  = 20
  queued_timeout = 30
  encryption_key = var.kms_key_arn

  artifacts {
    type = "CODEPIPELINE"
  }

  cache {
    type  = "LOCAL"
    modes = ["LOCAL_DOCKER_LAYER_CACHE", "LOCAL_CUSTOM_CACHE"]
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required for docker build

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }
    environment_variable {
      name  = "ECR_REPO_URL"
      value = var.ecr_repository_url
    }
    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = var.ecr_repository_name
    }
    environment_variable {
      name  = "CONTAINER_NAME"
      value = var.container_name
    }
    environment_variable {
      name  = "TASK_FAMILY"
      value = var.task_family
    }
    environment_variable {
      name  = "TASK_EXECUTION_ROLE_ARN"
      value = var.task_execution_role_arn
    }
    environment_variable {
      name  = "TASK_ROLE_ARN"
      value = var.task_role_arn
    }
    environment_variable {
      name  = "LOG_GROUP"
      value = var.app_log_group
    }
    environment_variable {
      name  = "APP_SECRET_ARN"
      value = var.app_secret_arn
    }
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
    }
    environment_variable {
      name  = "TASK_CPU"
      value = tostring(var.task_cpu)
    }
    environment_variable {
      name  = "TASK_MEMORY"
      value = tostring(var.task_memory)
    }
    environment_variable {
      name  = "VALIDATION_LAMBDA_NAME"
      value = var.validation_lambda_name
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build.name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipeline/buildspec.yml"
  }
}

# --------------------------------------------------------------------------- #
# CodePipeline                                                                 #
# --------------------------------------------------------------------------- #
data "aws_iam_policy_document" "codepipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = "${var.name}-codepipeline"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume.json
}

data "aws_iam_policy_document" "codepipeline" {
  statement {
    sid       = "Artifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning", "s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    sid       = "ArtifactEncryption"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }
  statement {
    sid       = "UseGitHubConnection"
    actions   = ["codestar-connections:UseConnection", "codeconnections:UseConnection"]
    resources = [local.connection_arn]
  }
  statement {
    sid       = "RunBuild"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds", "codebuild:StopBuild"]
    resources = [aws_codebuild_project.this.arn]
  }
  statement {
    sid       = "ApprovalNotifications"
    actions   = ["sns:Publish"]
    resources = [var.notification_topic_arn]
  }
  statement {
    sid = "CodeDeploy"
    actions = [
      "codedeploy:CreateDeployment", "codedeploy:GetDeployment", "codedeploy:GetDeploymentConfig",
      "codedeploy:GetApplication", "codedeploy:GetApplicationRevision", "codedeploy:RegisterApplicationRevision",
      "codedeploy:GetDeploymentGroup", "codedeploy:StopDeployment", "codedeploy:ContinueDeployment"
    ]
    resources = [
      "arn:aws:codedeploy:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:application:${var.codedeploy_app_name}",
      "arn:aws:codedeploy:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:deploymentgroup:${var.codedeploy_app_name}/${var.codedeploy_deployment_group_name}",
      "arn:aws:codedeploy:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:deploymentconfig:${var.codedeploy_deployment_config_name}",
    ]
  }
  statement {
    # RegisterTaskDefinition does not support resource-level permissions.
    sid       = "RegisterTaskDefinition"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition", "ecs:DescribeServices", "ecs:TagResource"]
    resources = ["*"]
  }
  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = [var.task_execution_role_arn, var.task_role_arn]
    condition {
      test     = "StringEqualsIfExists"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "codepipeline" {
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.codepipeline.json
}

resource "aws_codepipeline" "this" {
  name           = var.name
  role_arn       = aws_iam_role.codepipeline.arn
  pipeline_type  = "V2"
  execution_mode = "SUPERSEDED"

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
    encryption_key {
      id   = var.kms_key_arn
      type = "KMS"
    }
  }

  stage {
    name = "Source"
    action {
      name             = "GitHub"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceArtifact"]
      configuration = {
        ConnectionArn        = local.connection_arn
        FullRepositoryId     = var.github_repository
        BranchName           = var.github_branch
        DetectChanges        = "false" # triggers block below handles this
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  stage {
    name = "Build_Test_Scan"
    action {
      name             = "CodeBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["BuildArtifact"]
      configuration = {
        ProjectName = aws_codebuild_project.this.name
      }
    }
  }

  stage {
    name = "Approve_Production"
    action {
      name     = "ManualApproval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
      configuration = {
        NotificationArn = var.notification_topic_arn
        CustomData      = "Image passed lint, tests, dependency + container scans. Approve to start the blue/green deployment to ${var.environment}."
      }
    }
  }

  stage {
    name = "Deploy_BlueGreen"
    action {
      name            = "CodeDeployToECS"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeployToECS"
      version         = "1"
      input_artifacts = ["BuildArtifact"]
      configuration = {
        ApplicationName                = var.codedeploy_app_name
        DeploymentGroupName            = var.codedeploy_deployment_group_name
        TaskDefinitionTemplateArtifact = "BuildArtifact"
        TaskDefinitionTemplatePath     = "taskdef.json"
        AppSpecTemplateArtifact        = "BuildArtifact"
        AppSpecTemplatePath            = "appspec.yaml"
        Image1ArtifactName             = "BuildArtifact"
        Image1ContainerName            = "IMAGE1_NAME"
      }
    }
  }

  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "GitHub"
      push {
        branches {
          includes = [var.github_branch]
        }
        # Docs-only commits should not burn a build or nag for approval.
        file_paths {
          excludes = ["docs/**", "**/*.md"]
        }
      }
    }
  }
}

output "pipeline_name" { value = aws_codepipeline.this.name }
output "pipeline_arn" { value = aws_codepipeline.this.arn }
output "codebuild_project_name" { value = aws_codebuild_project.this.name }
output "connection_arn" { value = local.connection_arn }
output "connection_status" { value = var.existing_connection_arn != "" ? "AVAILABLE (reused)" : aws_codestarconnections_connection.github[0].connection_status }
output "artifact_bucket" { value = aws_s3_bucket.artifacts.bucket }
output "codebuild_role_arn" { value = aws_iam_role.codebuild.arn }
output "codepipeline_role_arn" { value = aws_iam_role.codepipeline.arn }
