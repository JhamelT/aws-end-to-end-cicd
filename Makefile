.DEFAULT_GOAL := help
SHELL := /bin/bash

REGION      ?= us-east-1
ENV_DIR     := terraform/envs/prod
BOOT_DIR    := terraform/bootstrap
ACCOUNT_ID  := $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
STATE_BUCKET := release-demo-tfstate-$(ACCOUNT_ID)

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- app ----
test: ## Run the same gates CodeBuild runs (lint, security lint, tests)
	cd app && ruff check . && ruff format --check . && bandit -q -r . -c pyproject.toml && python -m pytest -q
	ruff check pipeline

image: ## Build the container locally
	docker build --build-arg APP_VERSION=$$(cat VERSION) --build-arg GIT_SHA=$$(git rev-parse --short HEAD) -t release-demo:local app/

run: image ## Run the container locally on :8000
	docker run --rm -p 8000:8000 -e APP_API_KEY=local release-demo:local

# ------------------------------------------------------------ terraform ----
tf-check: ## fmt + validate + tflint + checkov (no AWS calls)
	terraform -chdir=$(ENV_DIR) fmt -check -recursive ../../
	terraform -chdir=$(ENV_DIR) init -backend=false -input=false >/dev/null
	terraform -chdir=$(ENV_DIR) validate
	tflint --chdir=$(ENV_DIR) --recursive || true
	checkov -d terraform --quiet --compact

bootstrap: ## One-time: create the remote state bucket
	terraform -chdir=$(BOOT_DIR) init -input=false
	terraform -chdir=$(BOOT_DIR) apply -input=false

init: ## Initialise the prod environment against the remote state bucket
	terraform -chdir=$(ENV_DIR) init -input=false \
	  -backend-config="bucket=$(STATE_BUCKET)" \
	  -backend-config="region=$(REGION)" \
	  -backend-config="use_lockfile=true"

plan: ## Plan prod (requires NOTIFICATION_EMAIL)
	terraform -chdir=$(ENV_DIR) plan -input=false -out=tfplan -var "notification_email=$(NOTIFICATION_EMAIL)" $(TF_ARGS)

apply: ## Apply the saved plan
	terraform -chdir=$(ENV_DIR) apply -input=false tfplan

outputs: ## Show stack outputs
	terraform -chdir=$(ENV_DIR) output

destroy: ## Tear everything down (state bucket survives)
	terraform -chdir=$(ENV_DIR) destroy -var "notification_email=$(NOTIFICATION_EMAIL)" $(TF_ARGS)

# ------------------------------------------------------------- release ----
release-status: ## Pipeline + latest deployment at a glance
	@scripts/status.sh

smoke: ## Hit the production endpoint and print the release that answered
	@scripts/smoke.sh

.PHONY: help test image run tf-check bootstrap init plan apply outputs destroy release-status smoke
