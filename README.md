# AWS Blue/Green CI/CD for a Containerized Python API

**GitHub → CodePipeline → CodeBuild (lint · tests · dependency + container scans) → immutable ECR image → manual approval → CodeDeploy ECS blue/green with canary traffic shifting → ALB (ACM/WAF) → CloudWatch alarm-based rollback. All of it provisioned with Terraform.**

This is the second version of this repository. [v1](https://github.com/JhamelT/aws-end-to-end-cicd/tree/v1-ec2-codedeploy) pushed a `:latest` image to Docker Hub and had CodeDeploy run shell scripts on a single EC2 box. It worked, and it had every problem a real release process is designed to prevent: no tests, no scanning, mutable tags, one instance, downtime on every deploy, and "rollback" meant rebuilding the previous version by hand. v2 is what I'd actually put in front of a security review.

## The scenario

A small SaaS company currently deploys its Python API manually to production. Releases create downtime, rollback requires rebuilding the previous version, and there is no consistent test or security gate. I designed an AWS-native CI/CD pipeline that builds and scans each container image, deploys it to an isolated green environment, validates application health, and shifts production traffic only after approval.

Success criteria I designed against:

| Requirement | How it's met |
|---|---|
| Zero-downtime releases | ECS blue/green: green task set is fully healthy before any traffic moves |
| Nothing unreviewed reaches prod | Ruff, Bandit, pytest, pip-audit, Trivy, and a manual approval gate |
| Know exactly what's running | Immutable ECR tags = git SHA; `/version` returns the commit; the validation hook refuses to promote a mismatch |
| Rollback in seconds, not minutes | CodeDeploy keeps blue warm for a 5-minute bake; rollback is a listener swap |
| Failures roll back on their own | AfterAllowTestTraffic hook + ALB 5XX / latency / unhealthy-host alarms wired to auto-rollback |
| Survive an AZ loss | 2 AZs, minimum 2 tasks, target-tracking autoscaling to 6 |

## Architecture

```
                 developer push to main
                          │
                          ▼
   GitHub ──CodeConnections──▶ CodePipeline (V2, push trigger; docs-only commits ignored)
                                    │
                    ┌───────────────┼──────────────────┐
                    ▼               ▼                  ▼
              Build_Test_Scan   Approve_Production   Deploy_BlueGreen
              (CodeBuild)       (manual, SNS email)  (CodeDeploy → ECS)
              ├ ruff / bandit
              ├ pip-audit
              ├ pytest
              ├ docker build
              ├ trivy (CRITICAL/HIGH, fixed only)
              ├ local smoke test
              └ push  ECR :<git-sha>  (immutable, KMS, scan-on-push)

   ┌───────────────────────── VPC 10.40.0.0/16, 2 AZs ─────────────────────────┐
   │  public subnets                        private subnets                    │
   │  ┌──────────────────────┐              ┌──────────────────────────────┐   │
   │  │ ALB  (+ WAF, ACM)    │              │ ECS Fargate service          │   │
   │  │  :443 prod listener ─┼─▶ blue TG ───┼─▶ task set A  (2–6 tasks)    │   │
   │  │  :80  → 301 to 443   │              │                              │   │
   │  │  :8080 test listener ┼─▶ green TG ──┼─▶ task set B  (during deploy)│   │
   │  └──────────────────────┘              └──────────────┬───────────────┘   │
   │           ▲  restricted to NAT EIP + admin CIDRs      │ NAT (1×) + S3 GW   │
   │           │                                           ▼                    │
   │   validation Lambda (in VPC) ◀── CodeDeploy hook   ECR · Logs · Secrets   │
   └────────────────────────────────────────────────────────────────────────────┘

   Route 53  app.<domain>  ──alias──▶ ALB          CloudWatch: alarms → SNS → email
                                                   EventBridge: pipeline/deploy state → SNS
```

Per release, CodeDeploy does the following, and each arrow is a place it can stop and roll back:

1. Registers a **green task set** from the new task definition and waits for it to pass ALB health checks on the **test listener** (port 8080).
2. Invokes the **AfterAllowTestTraffic** Lambda. It reads the task definition CodeDeploy is deploying, hits `/health`, `/ready`, `/version` through the test listener, and fails the deployment if the commit doesn't match or readiness fails.
3. Shifts production traffic **10% to green for 2 minutes** (canary), watching the rollback alarms, then **100%**.
4. Keeps **blue warm for 5 minutes**. Rollback during the bake is a listener swap.
5. Terminates blue.

## What's in the repo

```
app/                       FastAPI service: /, /health, /ready, /version; JSON logs; non-root image
pipeline/
  buildspec.yml            CI gates + image build + artifact rendering (runs in CodeBuild)
  taskdef.template.json    ECS task definition template (image + account values injected at build)
  appspec.yaml             CodeDeploy AppSpec with the AfterAllowTestTraffic hook
  render.py                fails the build on any unresolved ${PLACEHOLDER}
  hooks/validate_green/    the validation Lambda
terraform/
  bootstrap/               remote-state bucket (applied once)
  envs/prod/               the environment: composes the modules below
  modules/network          VPC, subnets, NAT, S3 endpoint, flow logs, inert default SG
  modules/alb              ALB, blue/green TGs, prod+test listeners, WAF, access logs
  modules/ecr              immutable, KMS-encrypted, lifecycle-pruned repository
  modules/ecs              cluster, split task/execution roles, Secrets Manager, service, autoscaling
  modules/codedeploy       app, canary deployment config, deployment group, hook Lambda
  modules/pipeline         CodeConnections, CodeBuild, CodePipeline V2, artifact bucket
  modules/observability    rollback alarms, ops alarms, SNS, EventBridge, dashboard
  modules/dns              ACM certificate + DNS validation
docs/
  adr/                     why ECS over EKS, why CodeDeploy, why one NAT, why immutable tags
  runbook.md               deploy, verify, force a rollback, break glass, tear down
.github/workflows/         PR checks with no AWS credentials: tests, fmt, validate, tflint, checkov
.checkov.yml               every skipped policy has a reason next to it
```

## Running it

Prerequisites: Terraform ≥ 1.10, AWS CLI v2 with credentials for a sandbox account, Docker (only for `make run`), a Route 53 hosted zone if you want HTTPS (leave `domain_name = ""` for an HTTP-only ALB).

```bash
make test                          # the same gates CodeBuild runs
make bootstrap                     # once: remote state bucket
make init                          # backend config from your account ID
make plan NOTIFICATION_EMAIL=you@example.com TF_ARGS='-var admin_cidrs=["<your-ip>/32"]'
make apply
```

After the first apply there are two one-time manual steps, both by design:

1. **Finish the GitHub connection.** AWS creates it `PENDING`; the GitHub App handshake has to be authorized by a human in the console (Developer Tools → Settings → Connections → Update pending connection).
2. **Confirm the SNS email subscription**, or approval requests and rollback notices go nowhere.

Then push to `main`. The pipeline runs, pauses at `Approve_Production`, and on approval performs the first blue/green deployment from the bootstrap placeholder to your image.

```bash
make release-status                # pipeline stages + latest deployment
make smoke                         # hit /version 10× — during a canary you'll see two commits interleave
```

See [docs/runbook.md](docs/runbook.md) for the failure drill: set `SIMULATE_FAILURE=true` in the task definition template, push, approve, and watch the hook fail the deployment and CodeDeploy roll back with production never having served the bad build.

## What building it actually looked like

Everything below happened on the first day, and each one is in the commit history. They are the part of this project I'd want to talk about in an interview.

| What happened | Why it matters | Fix |
|---|---|---|
| `pip-audit` rejected the first FastAPI pin — five published CVEs in the Starlette underneath it | The dependency gate paid for itself before the pipeline had deployed anything | Bumped to current pins |
| Trivy failed `python:3.12-slim` with 28 HIGH/CRITICAL | Slim base images drift between rebuilds; "official image" is not "patched image" | `apt-get upgrade` at build time; dropped `curl`, health checks use Python |
| CodeBuild ran `post_build` after `build` failed and **pushed the unscanned image to ECR** | CodeBuild's default is to continue into `post_build` on failure | `on-failure: ABORT` on every phase before the push |
| A unit test asserted `environment == "local"` and CodeBuild sets `ENVIRONMENT=prod` | Tests that read ambient env are not tests | Fixture pins every variable the app reads |
| Push trigger dead while the Source stage was green | The AWS Connector GitHub App was *authorized* for the user but never *installed* on the account — cloning works on a user token, webhooks only come from an installation | Installed the app; pipeline reuses a `codeconnections` connection bound to that installation |
| `for_each` over a CIDR list containing the NAT EIP failed at plan | `for_each` keys must be known at plan time; EIPs are not | `count` |
| Terraform tried to "fix" `platform_version` on the ECS service and ECS refused | `LATEST` resolves to `1.4.0` after creation, and CODE_DEPLOY-controlled services reject `UpdateService` for it | `ignore_changes` |
| First validation hook crashed on `KeyError('appSpecContent')` | CodePipeline registers CodeDeploy revisions as S3, not `AppSpecContent`; parsing the revision was the wrong idea | Hook finds the green task set by `externalId == deploymentId` |

That last one is worth pausing on: the hook crashed, reported `Failed` in its `finally`, and CodeDeploy rolled back with production untouched. A validation step that fails closed is worth more than one that is clever.

### Measured

From the evidence in [`docs/evidence/`](docs/evidence/):

| Step | Time |
|---|---|
| `terraform apply`, 107 resources | ~6 min |
| CodeBuild (lint, tests, audit, build, Trivy, smoke, push), warm cache | 1 min 39 s |
| Approval → green healthy → hook passed | 2 min 09 s |
| Canary 10% → 100% | 2 min |
| Bake, then blue terminated → deployment `Succeeded` | 9 min 14 s end to end |
| Failure drill: approval → hook `Failed` (18 attempts over 90 s) → auto-rollback | 3 min 41 s, zero production requests served by the bad build |

## Cost

Roughly **$2.50–3.00/day** while up in us-east-1: ALB (~$0.55), one NAT Gateway (~$1.10 + data), two 0.5 vCPU / 1 GB Fargate tasks (~$0.60), WAF (~$0.30), plus cents for KMS, CodeBuild minutes, ECR storage and logs. `make destroy` removes everything except the state bucket.

## Things I'd change for a real production account

- **Separate accounts** for CI, staging and prod, with the pipeline assuming a cross-account deploy role. One account is fine for a demo and wrong for a company.
- **NAT per AZ**, or interface endpoints for ECR/Logs/Secrets so the tasks have no NAT dependency at all.
- **A second human gate** at CodeDeploy's `deployment_ready_option` (STOP_DEPLOYMENT) for regulated workloads that need explicit sign-off on the traffic shift itself, not just on starting the deployment.
- **Secret rotation** with a rotation Lambda; the demo secret is generated at apply and never rotated.
- **Database migrations** using expand/contract so blue and green can run against the same schema during the bake.

## Related

- Thursday learning post: *Blue/Green vs Rolling vs Canary — and why this pipeline uses two of them at once.*
- Previous projects in this series: security remediation platform · Terraform 3-tier app · EKS game deployment
