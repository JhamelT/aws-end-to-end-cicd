# TLS certificate for the public endpoint, validated through the Route 53
# hosted zone that domain registration created. The alias record itself lives
# in the environment root because it needs the ALB, and the ALB needs this
# certificate — keeping them apart keeps the dependency graph one-directional.

variable "domain_name" { type = string }
variable "subdomain" { type = string }

locals {
  fqdn = "${var.subdomain}.${var.domain_name}"
}

data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_acm_certificate" "this" {
  domain_name       = local.fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }
  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

output "certificate_arn" { value = aws_acm_certificate_validation.this.certificate_arn }
output "fqdn" { value = local.fqdn }
output "zone_id" { value = data.aws_route53_zone.this.zone_id }
