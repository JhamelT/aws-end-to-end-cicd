# ADR 0005 — Pre-traffic validation hook instead of trusting ALB health checks

**Status:** accepted · **Date:** 2026-08

## Context

An ALB health check answers one question: does the target return 200 on a path. A service can pass that check while being unable to reach its database, running the wrong build, or missing a secret. Those are the outages that make it to production because the load balancer said everything was fine.

## Decision

Three endpoints with distinct meanings, and a CodeDeploy `AfterAllowTestTraffic` hook that checks all three through the ALB test listener before any production traffic moves:

| Endpoint | Meaning | Who uses it |
|---|---|---|
| `/health` | The process is up | ALB target group, Docker HEALTHCHECK, ECS container health |
| `/ready` | Dependencies and config are present; safe to serve | Validation hook |
| `/version` | Exactly which commit and version this is | Validation hook, humans, smoke script |

The hook fails the deployment if `/ready` is not 200 or `/version` does not report the commit CodeDeploy is deploying. On failure, CodeDeploy's auto-rollback terminates green; blue never stopped serving.

The failure drill (`SIMULATE_FAILURE=true`) is built to exercise exactly this gap: `/health` stays 200, `/ready` returns 503.

## Consequences

- The hook Lambda runs inside the VPC and reaches the test listener through the NAT; the ALB security group allows port 8080 from the NAT's EIP only. The test listener is not reachable from the internet.
- The hook is a single point of decision. It is capped at one concurrent execution and 120 seconds, and it reports `Failed` on any exception, so a broken hook blocks releases rather than waving them through.
- Application teams own `/ready`. If it lies, the pipeline can't help.
