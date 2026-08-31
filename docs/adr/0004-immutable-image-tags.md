# ADR 0004 — Immutable image tags keyed on the git commit

**Status:** accepted · **Date:** 2026-08

## Context

v1 of this repository pushed every build to `myapp:latest`. That made three questions unanswerable: what is running in production, what was running before the last deploy, and whether the image in the registry is the one CI tested.

## Decision

- ECR repository has tag immutability enabled; a tag can never be re-pushed.
- CodeBuild tags each image with the short git SHA (`release-demo-prod:a71c92f`). There is no `latest`.
- The task definition rendered by the build references that tag; the container's `GIT_SHA` env var carries the same value; `/version` returns it.
- The CodeDeploy validation hook reads the task definition being deployed and refuses to promote green unless `/version` reports the expected commit.
- A lifecycle policy keeps the 15 most recent images and expires untagged layers after a day.

## Consequences

- Rollback to any of the last 15 releases is a pipeline run at that commit; no rebuild, no "hope it's the same".
- Semantic versions (`VERSION` file) are informational and travel in `APP_VERSION`; they are not the deploy key, because two commits can share a version string.
- Pinning by digest instead of tag would be stricter still. With immutability on, tag and digest are equivalent for our purposes, and tags are readable in the console at 3am.
