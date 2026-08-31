# ADR 0001 — Deploy to ECS Fargate rather than EKS or Elastic Beanstalk

**Status:** accepted · **Date:** 2026-08

## Context

The application is a stateless Python API. The goal of this project is to demonstrate a production-grade release process (build gates, blue/green, validation, rollback), not container orchestration itself. Three targets were considered.

## Options

**EKS.** Maximum flexibility and the industry default for platform teams. But the previous project in this series already covers Kubernetes, and EKS adds a control-plane cost (~$73/month) plus a deployment-strategy layer (Argo Rollouts / Flagger) that would become the project instead of the pipeline.

**Elastic Beanstalk.** Supports blue/green through environment URL swaps. It hides exactly the mechanics an interviewer wants to see: target groups, listeners, task sets, health checks, hooks.

**ECS Fargate.** No cluster to manage, per-task billing, native integration with CodeDeploy's ECS blue/green deployment type, and every moving part (task sets, target groups, listeners, lifecycle hooks) is visible and controllable in Terraform.

## Decision

ECS Fargate with CodeDeploy as the deployment controller.

## Consequences

- No node patching, no cluster upgrades, no capacity planning beyond task sizing.
- The application has no access to host-level features (no DaemonSets, no privileged containers). Acceptable for a stateless API.
- Blue/green temporarily doubles task count during a deployment; autoscaling `max_capacity` must leave headroom for that.
- Moving to EKS later would replace the `ecs` and `codedeploy` modules; the pipeline, ECR, network and observability modules carry over.
