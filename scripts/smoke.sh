#!/usr/bin/env bash
# Hit the production endpoint repeatedly and show which release answers.
# During a canary shift you will see two different commits interleaved.
set -euo pipefail

URL="${1:-$(terraform -chdir="$(dirname "$0")/../terraform/envs/prod" output -raw app_url)}"
N="${2:-10}"

echo "==> ${URL}"
for _ in $(seq 1 "$N"); do
  curl -sS --max-time 5 "${URL}/version" -w '  [%{http_code} %{time_total}s]\n' || true
  sleep 0.5
done
