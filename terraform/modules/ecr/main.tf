# Container registry. Immutable tags are the whole point: the SHA the pipeline
# built is the SHA that runs, and nobody can re-push "v1.0.0" with different bytes.

variable "name" { type = string }
variable "kms_key_arn" { type = string }

resource "aws_ecr_repository" "this" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # portfolio env: let `terraform destroy` remove images

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }
}

# Keep enough history to roll back several releases without paying for
# every image ever built.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 1 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 15 most recent release images"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 15 }
        action       = { type = "expire" }
      }
    ]
  })
}

output "repository_url" { value = aws_ecr_repository.this.repository_url }
output "repository_arn" { value = aws_ecr_repository.this.arn }
output "repository_name" { value = aws_ecr_repository.this.name }
