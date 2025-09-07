#!/bin/bash
set -e

NAME="simple-python-app"

# Stop & remove if present; do nothing if not
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "[stop] Ensured $NAME is not running."
