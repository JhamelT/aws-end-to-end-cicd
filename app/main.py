"""
Release-demo API.

This service exists to be deployed. It is intentionally small so the
pipeline, not the application, is the thing under review.

Endpoints
---------
GET /         -> human-readable landing page, colored per release so a traffic shift is visible
GET /health   -> liveness: the process is up (used by ALB + Docker HEALTHCHECK)
GET /ready    -> readiness: dependencies/config the app needs are present
GET /version  -> what exactly is running: version, git sha, build time, environment
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import sys
import time
import uuid
from datetime import UTC, datetime

from fastapi import FastAPI, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse

# --------------------------------------------------------------------------- #
# Configuration (all injected by the ECS task definition; safe defaults local) #
# --------------------------------------------------------------------------- #
APP_VERSION = os.getenv("APP_VERSION", "v0.0.0-local")
GIT_SHA = os.getenv("GIT_SHA", "local")
BUILD_TIME = os.getenv("BUILD_TIME", "unknown")
ENVIRONMENT = os.getenv("ENVIRONMENT", "local")
# Injected from Secrets Manager via the task definition `secrets` block.
# The value is never logged or returned; /ready only checks it is present.
APP_API_KEY = os.getenv("APP_API_KEY")
# Flip to "true" in the task definition to simulate a bad release: the process
# stays alive (/health 200, so the ALB thinks it's fine) but /ready reports 503.
# That is exactly the class of failure a load balancer health check cannot catch
# and the CodeDeploy validation hook exists to catch. Never set this in a real service.
SIMULATE_FAILURE = os.getenv("SIMULATE_FAILURE", "false").lower() == "true"

STARTED_AT = time.time()


# --------------------------------------------------------------------------- #
# Structured JSON logging -> CloudWatch Logs                                   #
# --------------------------------------------------------------------------- #
class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": datetime.now(UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
            "version": APP_VERSION,
            "sha": GIT_SHA,
        }
        for key in ("request_id", "method", "path", "status", "duration_ms"):
            if hasattr(record, key):
                payload[key] = getattr(record, key)
        return json.dumps(payload)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("release-demo")
log.setLevel(logging.INFO)
log.handlers = [handler]
log.propagate = False

app = FastAPI(title="release-demo", version=APP_VERSION, docs_url=None, redoc_url=None)


@app.middleware("http")
async def request_context(request: Request, call_next):
    request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
    start = time.perf_counter()
    response: Response = await call_next(request)
    duration_ms = round((time.perf_counter() - start) * 1000, 2)
    response.headers["x-request-id"] = request_id
    response.headers["x-release"] = f"{APP_VERSION}+{GIT_SHA[:7]}"
    # ALB health checks are noisy; log them at DEBUG so they don't drown real traffic.
    level = logging.DEBUG if request.url.path == "/health" else logging.INFO
    log.log(
        level,
        "request",
        extra={
            "request_id": request_id,
            "method": request.method,
            "path": request.url.path,
            "status": response.status_code,
            "duration_ms": duration_ms,
        },
    )
    return response


# --------------------------------------------------------------------------- #
# Routes                                                                      #
# --------------------------------------------------------------------------- #
@app.get("/health")
def health() -> JSONResponse:
    """Liveness. If this fails, the task should be replaced."""
    return JSONResponse({"status": "ok", "uptime_s": round(time.time() - STARTED_AT, 1)})


@app.get("/ready")
def ready() -> JSONResponse:
    """Readiness. If this fails, don't send traffic yet."""
    checks = {
        "config_loaded": bool(APP_VERSION and GIT_SHA),
        "secret_present": APP_API_KEY is not None and len(APP_API_KEY) > 0,
        "dependencies": not SIMULATE_FAILURE,  # stands in for "can I reach my DB/queue/downstream"
    }
    ok = all(checks.values())
    return JSONResponse({"status": "ready" if ok else "not_ready", "checks": checks}, status_code=200 if ok else 503)


@app.get("/version")
def version() -> dict:
    return {
        "version": APP_VERSION,
        "commit": GIT_SHA,
        "build_time": BUILD_TIME,
        "environment": ENVIRONMENT,
    }


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    # Each release gets its own hue derived from the commit, so when CodeDeploy
    # shifts traffic from the old task set to the new one, the page visibly changes.
    hue = int(hashlib.sha256(GIT_SHA.encode()).hexdigest()[:4], 16) % 360
    bg = f"hsl({hue} 55% 38%)"
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>release-demo {APP_VERSION}</title>
<style>
 body{{margin:0;font-family:system-ui,-apple-system,Segoe UI,sans-serif;background:{bg};color:#fff;
      min-height:100vh;display:flex;align-items:center;justify-content:center;text-align:center}}
 .card{{background:rgba(0,0,0,.25);padding:2.5rem 3rem;border-radius:16px}}
 h1{{margin:0 0 .5rem;font-size:3rem;letter-spacing:.02em}} code{{font-size:1.1rem}}
 .muted{{opacity:.8;margin-top:1rem;font-size:.9rem}}
</style></head>
<body><div class="card">
 <h1>{APP_VERSION}</h1>
 <div>commit <code>{GIT_SHA[:7]}</code></div>
 <div class="muted">env: {ENVIRONMENT} &middot; built {BUILD_TIME}</div>
</div></body></html>"""
