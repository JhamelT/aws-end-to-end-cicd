# syntax=docker/dockerfile:1.7
# ---- build stage: resolve wheels once, keep compilers out of the runtime image ----
FROM public.ecr.aws/docker/library/python:3.12-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- runtime stage ----
FROM public.ecr.aws/docker/library/python:3.12-slim
ARG APP_VERSION=v0.0.0
ARG GIT_SHA=unknown
ARG BUILD_TIME=unknown

# Patch the base OS at build time (slim images ship with known CVEs between
# rebuilds) and create a non-root user; ECS Fargate tasks should never run as root.
# No curl: fewer packages, smaller attack surface; health checks use Python.
RUN apt-get update && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system app && useradd --system --gid app --uid 10001 --home /app app

WORKDIR /app
COPY --from=build /install /usr/local
COPY --chown=app:app main.py .

ENV APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA} \
    BUILD_TIME=${BUILD_TIME} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000

USER app
EXPOSE 8000

# Container-level liveness; ECS also health-checks via the ALB.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request as u,sys; sys.exit(0 if u.urlopen('http://127.0.0.1:8000/health', timeout=3).status == 200 else 1)"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--no-access-log"]
