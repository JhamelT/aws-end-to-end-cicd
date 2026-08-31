# ADR 0003 — One NAT Gateway, plus an S3 gateway endpoint

**Status:** accepted (for this environment) · **Date:** 2026-08

## Context

Fargate tasks in private subnets need outbound access to pull from ECR, write logs, and fetch secrets. The options are a NAT Gateway per AZ, a single NAT Gateway, or interface VPC endpoints for each AWS service.

## Costs (us-east-1, approximate)

| Option | Monthly | Notes |
|---|---|---|
| 1 × NAT | ~$33 + $0.045/GB | Cross-AZ dependency |
| 2 × NAT | ~$66 + data | AZ-independent |
| 4 interface endpoints (ECR api, ECR dkr, Logs, Secrets Manager) | ~$29 + $0.01/GB | No internet path at all; per-AZ endpoints double it |
| S3 gateway endpoint | $0 | ECR layers are served from S3 |

## Decision

One NAT Gateway and the free S3 gateway endpoint. Image layer pulls bypass the NAT; only ECR API calls, log delivery and secret fetches go through it.

## Consequences

- If the NAT's AZ fails, tasks in the surviving AZ keep serving existing traffic (the ALB → task path does not use the NAT) but cannot start new tasks or fetch secrets. For a portfolio environment that is acceptable; for production it is not, and the fix is `count = var.az_count` on the NAT and per-AZ private route tables.
- The validation Lambda also egresses through this NAT, which is why the ALB test listener's security group allows the NAT's EIP. Adding a second NAT means allowing both EIPs.
- Interface endpoints would remove the NAT entirely and are the better long-term answer once egress data exceeds a few hundred GB/month.
