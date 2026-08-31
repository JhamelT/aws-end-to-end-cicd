# ADR 0002 — CodeDeploy blue/green (with canary traffic shifting) as the deployment controller

**Status:** accepted · **Date:** 2026-08

## Context

ECS can deploy new task definitions three ways: the rolling update controller built into ECS, ECS's own built-in blue/green strategy (2025), and an external controller (CodeDeploy). The requirement is: green must be validated by something stronger than an ALB health check before it receives any production traffic, rollback must be automatic and fast, and a human must approve production releases.

## Options

**ECS rolling update.** Simplest. Old and new versions serve production traffic simultaneously during the roll; rollback is another roll. No test listener, no pre-traffic validation hook. Fails the first requirement.

**ECS-native blue/green.** Newer, fewer moving parts, supports lifecycle hooks and a test listener. Terraform provider support is recent, and it is less familiar in interview and operations contexts.

**CodeDeploy (ECS platform).** Mature. First-class CodePipeline action (`CodeDeployToECS`). Lifecycle hooks (`AfterAllowTestTraffic` et al.), alarm-based auto-rollback, bake period before terminating blue, and traffic-shifting configs including time-based canary and linear.

## Decision

CodeDeploy, with a custom `TimeBasedCanary` deployment config: 10% of production traffic to green for 2 minutes, then 100%. Blue is kept for 5 minutes after the shift.

So this is blue/green *deployment* with canary *traffic shifting*. They are not competing strategies; blue/green describes the infrastructure topology (two full task sets), canary describes how traffic moves between them.

## Consequences

- Terraform must `ignore_changes` on the ECS service's task definition/load balancer and the listeners' default actions, because CodeDeploy mutates them. This is a well-known sharp edge and is documented in the modules.
- The task definition is rendered in CodeBuild, not managed in Terraform. Terraform owns the *bootstrap* task definition only.
- The human gate is a CodePipeline manual approval before the deployment starts. A second gate at the traffic-shift point is available via `deployment_ready_option = STOP_DEPLOYMENT` and was deliberately not enabled, to keep the demo fully automated after approval.
- CodeDeploy's ECS support is feature-frozen relative to ECS-native blue/green; if AWS deprecates it, the migration path is the `codedeploy` module plus the pipeline's deploy action.
