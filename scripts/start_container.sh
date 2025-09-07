#!/bin/bash 
set -e

IMAGE="jhamelthorne/myapp:latest"
NAME="simple-python-app"
PORT="5000"   # matches app.py and Dockerfile

echo "[start] Pulling latest image: $IMAGE"
docker pull "$IMAGE"

echo "[start] Starting container $NAME on :$PORT"
docker run -d --name "$NAME" --restart=always -p ${PORT}:5000 "$IMAGE"

# Lightweight sanity check (non-fatal if app isn't warm yet)
sleep 2
if curl -fsS "http://localhost:${PORT}/health" >/dev/null; then
  echo "[start] Health OK."
else
  echo "[start] App starting; health endpoint not ready yet."
fi
