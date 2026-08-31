"""
CodeDeploy lifecycle hook: AfterAllowTestTraffic.

At this point the green task set is registered with the ALB *test* listener and
receives no production traffic. This function decides whether it ever will.

Checks
------
1. /health returns 200            -> process is alive behind the test listener
2. /ready  returns 200            -> config + secrets are actually present
3. /version commit == built SHA   -> the thing we're validating is the thing we built
   (the expected SHA is read from the task definition CodeDeploy is deploying,
   so a stale or mis-tagged image cannot pass)

Any failure -> Failed status -> CodeDeploy stops the deployment and, because the
deployment group has auto-rollback enabled, blue keeps serving and green is torn down.
"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.request

import boto3

TEST_ENDPOINT = os.environ["TEST_ENDPOINT"].rstrip("/")  # e.g. http://<alb-dns>:8080
MAX_WAIT_S = int(os.environ.get("MAX_WAIT_SECONDS", "90"))
POLL_S = 5

codedeploy = boto3.client("codedeploy")
ecs = boto3.client("ecs")


def _get(path: str, timeout: float = 5.0) -> tuple[int, str]:
    req = urllib.request.Request(f"{TEST_ENDPOINT}{path}", headers={"x-request-id": "codedeploy-validation"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - fixed scheme/host from env
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:  # noqa: BLE001
        return 0, str(e)


def _expected_release(deployment_id: str) -> tuple[str, str]:
    """Return (git_sha, app_version) from the task definition this deployment registers."""
    info = codedeploy.get_deployment(deploymentId=deployment_id)["deploymentInfo"]
    appspec = info["revision"]["appSpecContent"]["content"]
    # Grab the task definition ARN without pulling a YAML dependency into the Lambda package.
    match = re.search(r"TaskDefinition:\s*[\"']?(arn:aws:ecs:[^\s\"']+)", appspec)
    if not match:
        raise RuntimeError("could not find TaskDefinition ARN in AppSpec")
    taskdef_arn = match.group(1)
    td = ecs.describe_task_definition(taskDefinition=taskdef_arn)["taskDefinition"]
    container = td["containerDefinitions"][0]
    env = {e["name"]: e["value"] for e in container.get("environment", [])}
    image_tag = container["image"].rsplit(":", 1)[-1]
    return env.get("GIT_SHA", image_tag), env.get("APP_VERSION", "unknown")


def _validate(expected_sha: str, expected_version: str) -> list[str]:
    problems: list[str] = []

    status, body = _get("/health")
    if status != 200:
        problems.append(f"/health -> {status}: {body[:200]}")

    status, body = _get("/ready")
    if status != 200:
        problems.append(f"/ready -> {status}: {body[:200]}")

    status, body = _get("/version")
    if status != 200:
        problems.append(f"/version -> {status}: {body[:200]}")
    else:
        try:
            v = json.loads(body)
        except json.JSONDecodeError:
            problems.append(f"/version returned non-JSON: {body[:200]}")
        else:
            if v.get("commit") != expected_sha:
                problems.append(f"/version commit {v.get('commit')!r} != expected {expected_sha!r}")
            if v.get("version") != expected_version:
                problems.append(f"/version version {v.get('version')!r} != expected {expected_version!r}")
    return problems


def handler(event, context):
    deployment_id = event["DeploymentId"]
    hook_id = event["LifecycleEventHookExecutionId"]
    print(json.dumps({"msg": "validation start", "deployment_id": deployment_id, "endpoint": TEST_ENDPOINT}))

    status = "Failed"
    try:
        expected_sha, expected_version = _expected_release(deployment_id)
        print(json.dumps({"msg": "expected release", "sha": expected_sha, "version": expected_version}))

        deadline = time.time() + MAX_WAIT_S
        problems = ["not attempted"]
        attempt = 0
        while time.time() < deadline:
            attempt += 1
            problems = _validate(expected_sha, expected_version)
            print(json.dumps({"msg": "attempt", "n": attempt, "problems": problems}))
            if not problems:
                status = "Succeeded"
                break
            time.sleep(POLL_S)

        print(json.dumps({"msg": "validation result", "status": status, "problems": problems}))
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"msg": "validation error", "error": repr(e)}))
    finally:
        codedeploy.put_lifecycle_event_hook_execution_status(
            deploymentId=deployment_id, lifecycleEventHookExecutionId=hook_id, status=status
        )
    return {"status": status}
