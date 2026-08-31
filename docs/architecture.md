# Architecture notes

## Request path

```
client ──HTTPS──▶ Route 53 (app.<domain>) ──▶ ALB :443 (WAF, ACM, TLS 1.3/1.2)
                                                  │
                                                  ▼ production listener → whichever TG is PRIMARY
                                     blue TG ◀────┴────▶ green TG
                                        │                   │
                                  task set A            task set B      (Fargate, private subnets, no public IPs,
                                  (2–6 tasks, 2 AZs)    (during deploy)  SG allows :8000 from the ALB SG only)
```

## Release path

```
push main ─▶ CodePipeline ─▶ CodeBuild ─▶ ECR ─▶ [approval] ─▶ CodeDeploy ─▶ ECS task set ─▶ ALB test listener :8080
                                                                    │                             │
                                                                    │◀──── AfterAllowTestTraffic ─┘ (Lambda in VPC, via NAT)
                                                                    ▼
                                                           canary 10% / 2 min ─▶ 100% ─▶ 5 min bake ─▶ terminate blue
                                                                    │
                                              rollback alarms: ALB 5XX, p95 latency, unhealthy hosts (either TG)
```

## Identity and access

| Principal | Can | Cannot |
|---|---|---|
| CodePipeline role | read/write artifact bucket, use the GitHub connection, start CodeBuild, create CodeDeploy deployments for this app/group/config, register task definitions, pass the two task roles to `ecs-tasks.amazonaws.com`, publish approval notices | touch ECR, ECS services directly, or any other pipeline |
| CodeBuild role | push/pull this ECR repository, read/write artifacts, use the KMS key, write its own log group and test reports | read secrets, deploy anything |
| CodeDeploy role | `AWSCodeDeployRoleForECS` (task sets, target groups, listeners, invoke hooks) | — |
| ECS task execution role | pull this repository, read this one secret, write this one log group, decrypt with this key | — |
| ECS task role | nothing | everything — the app calls no AWS APIs |
| Validation Lambda role | `GetDeployment`, `PutLifecycleEventHookExecutionStatus`, `DescribeTaskDefinition`, VPC networking, logs | change anything |

## Encryption

One customer-managed KMS key (`alias/release-demo-prod`) with rotation enabled covers pipeline artifacts, CodeBuild, ECR images, the application secret and the SNS topic. The key policy grants `events` and `cloudwatch` service principals `GenerateDataKey`/`Decrypt` so alarms and EventBridge can publish to the encrypted topic. ALB access logs use SSE-S3 because ELB log delivery does not support SSE-KMS.

## Where the sharp edges are

- **Terraform vs CodeDeploy ownership.** After the first deployment, CodeDeploy owns the service's task definition, its target-group binding and both listeners' default actions. The `ignore_changes` blocks in `modules/ecs` and `modules/alb` are load-bearing; remove them and the next `apply` will point production at the wrong task set.
- **for_each on the NAT EIP.** The test-listener SG rules use `count`, not `for_each`, because the NAT EIP is unknown at plan time and `for_each` keys must be known.
- **Rollback alarm dimensions.** Alarms pinned to a target group watch the *idle* color half the time. The 5XX and latency alarms are at the load-balancer level for this reason.
- **Bootstrap.** ECR is empty at first apply. The service starts on a public `python:3.12-slim` placeholder serving `/health`; the first pipeline run replaces it via a normal blue/green deployment. Alternatives (seeding an image with `local-exec`, two-phase apply) were rejected as either requiring Docker on the operator's machine or breaking the single-apply story.
- **GitHub connection handshake and SNS confirmation** are manual by AWS design; Terraform cannot complete either. Worse: a connection can be `AVAILABLE` and clone fine while push webhooks never arrive, if the GitHub App is authorized but not installed. Test the trigger, not just the Source stage.
- **The 5XX rollback alarm sees test-listener traffic.** `HTTPCode_Target_5XX_Count` at the load-balancer level counts every target, including green behind the test listener. During the failure drill the hook's eighteen `/ready` probes tripped the alarm. That is acceptable (a second, independent trip-wire on a bad release) but it means a *new* deployment started while the alarm is still in `ALARM` will be stopped immediately by `DEPLOYMENT_STOP_ON_ALARM`. Wait for `OK`, or scope the alarm to the production target group and accept that it then needs re-pointing after every deploy.
- **CodeBuild phase semantics.** `post_build` runs after a failed `build` unless `on-failure: ABORT` is set. Anything that publishes belongs behind that flag.
- **Revision shape depends on the caller.** CodePipeline's `CodeDeployToECS` action stores the revision in S3; `aws deploy create-deployment` can pass `AppSpecContent`. The hook therefore reads the green task set from ECS (`externalId == deploymentId`) rather than parsing the revision.
