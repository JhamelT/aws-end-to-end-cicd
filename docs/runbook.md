# Runbook — release-demo (prod)

Everything here is runnable from the repo root with the AWS CLI authenticated to the target account.

## 1. Normal release

1. Merge to `main`. The pipeline triggers on push (docs-only commits are filtered out by the trigger).
2. `Build_Test_Scan` runs. If it fails, the CodeBuild log link is in the failure email. Common causes:
   - `pip-audit` found a CVE in a pinned dependency → bump the pin. Do not add `--ignore-vuln` without a ticket.
   - Trivy found a fixed CRITICAL/HIGH in the base image → rebuild; `python:3.12-slim` gets patched frequently.
   - `render.py: unresolved placeholders` → a CodeBuild environment variable is missing; check `terraform/modules/pipeline`.
3. Approve at `Approve_Production` (console or `aws codepipeline put-approval-result`). The approval email includes what passed.
4. Watch the deployment: `make release-status` or the CodeDeploy console. Expected timeline: ~2 min green healthy → hook ~10 s → 2 min canary → 100% → 5 min bake → blue terminated. Total ≈ 10 min.
5. `make smoke` — every response should show the new commit once the shift completes.

## 2. Verify what is running

```bash
curl -s https://app.<domain>/version
aws ecs describe-services --cluster release-demo-prod --services release-demo-prod \
  --query 'services[0].taskSets[].{id:id,status:status,taskDef:taskDefinition,scale:scale.value}'
```

The `PRIMARY` task set's task definition should reference the image tag equal to the commit in `/version`.

## 3. Failure drill — force a rollback

This is the demo that matters. It fails in the way an ALB health check cannot catch: the process is alive but not ready.

1. In `pipeline/taskdef.template.json`, change `"SIMULATE_FAILURE"` from `"false"` to `"true"`. Commit and push.
2. Build passes (the app is fine; the *deployment* is what's wrong). Approve.
3. CodeDeploy brings up green; ALB health checks pass (`/health` is 200). The `AfterAllowTestTraffic` hook calls `/ready`, gets 503, retries for 90 s, and reports `Failed`.
4. CodeDeploy marks the deployment `Failed`, auto-rollback fires, green is torn down. Production traffic never left blue.
5. Evidence: CodeDeploy deployment → *Events* tab; Lambda log group `/aws/lambda/release-demo-prod-validate-green` shows each attempt's problems list; `/version` in prod still shows the previous commit.
6. Revert the flag, push, approve.

## 4. Roll back a release that already shifted

During the 5-minute bake: stop the deployment in CodeDeploy (`Stop and roll back`). Traffic returns to blue in seconds.

After the bake (blue terminated): redeploy the previous commit. Because tags are immutable and lifecycle keeps the last 15 images, this is a normal pipeline run pointed at the old SHA:

```bash
aws codepipeline start-pipeline-execution --name release-demo-prod \
  --source-revisions actionName=GitHub,revisionType=COMMIT_ID,revisionValue=<previous-sha>
```

## 5. Break glass — the pipeline itself is broken

Register a task definition from a known-good image and create a CodeDeploy deployment directly:

```bash
aws deploy create-deployment --application-name release-demo-prod \
  --deployment-group-name release-demo-prod \
  --revision '{"revisionType":"AppSpecContent","appSpecContent":{"content":"<appspec yaml with the task definition ARN>"}}'
```

Log it in the incident channel; the pipeline is the source of truth and this bypasses the approval gate.

## 6. Rollback alarms

Attached to the deployment group; any of them in `ALARM` during a deployment stops it and rolls back:

| Alarm | Signal | Why |
|---|---|---|
| `release-demo-prod-alb-target-5xx` | ≥5 target 5XX/min for 2 min, ALB-level | Measured at the load balancer so it covers whichever color is live |
| `release-demo-prod-alb-p95-latency` | p95 > 1 s for 3 min | A slow release is a bad release |
| `release-demo-prod-{blue,green}-unhealthy-hosts` | ≥1 unhealthy target for 2 min | Task crash-looping behind either TG |

Not rollback signals (page only): ECS CPU/memory > 85% for 5 min. CPU alone says nothing about correctness.

## 7. First-time setup gotchas

- **GitHub connection PENDING**: Terraform cannot complete the GitHub App handshake. Console → Developer Tools → Settings → Connections → *Update pending connection*. Until then the pipeline's Source stage fails.
- **Source works but pushes don't trigger the pipeline**: the "AWS Connector for GitHub" app is *authorized* for your user but not *installed* on the account/org. Install it at `github.com/apps/aws-connector-for-github/installations/new`, create a connection against that installation, and set `github_connection_arn`. Connections are account-level shared resources; prefer reusing one over creating one per stack.
- **Build fails but an image still lands in ECR**: `post_build` ran after `build` failed. Every phase before the push must carry `on-failure: ABORT` (they do; don't remove it).
- **`terraform apply` fails with "Unable to update platform version"**: something removed `platform_version` from the ECS service's `ignore_changes`.
- **SNS subscription unconfirmed**: approvals still work in the console, but no emails arrive.
- **First deployment from bootstrap**: the ECS service starts on a public `python:3.12-slim` placeholder that serves `/health`. The first pipeline run replaces it via a real blue/green deployment. `/version` returns `bootstrap` until then.
- **ACM validation**: DNS validation can take 5–30 minutes after registration; `terraform apply` waits on it.
- **Test listener unreachable from your laptop**: intended. Add your IP to `admin_cidrs` if you want to poke green by hand.

## 8. Tear down

```bash
make destroy NOTIFICATION_EMAIL=you@example.com
```

Order matters and Terraform handles it, but two things will not be removed on purpose: the remote state bucket (`terraform/bootstrap`, `prevent_destroy`) and the registered domain. The KMS key enters a 7-day pending-deletion window.
