#!/usr/bin/env bash
# One-screen view of the pipeline and the most recent CodeDeploy deployment.
set -euo pipefail

ENV_DIR="$(dirname "$0")/../terraform/envs/prod"
PIPELINE="$(terraform -chdir="$ENV_DIR" output -raw pipeline_name)"
APP="$(terraform -chdir="$ENV_DIR" output -raw codedeploy_application)"

echo "== CodePipeline: ${PIPELINE}"
aws codepipeline get-pipeline-state --name "$PIPELINE" \
  --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table

DEPLOYMENT_ID="$(aws deploy list-deployments --application-name "$APP" --deployment-group-name "$APP" --query 'deployments[0]' --output text)"
if [[ "$DEPLOYMENT_ID" != "None" ]]; then
  echo "== CodeDeploy: latest deployment ${DEPLOYMENT_ID}"
  aws deploy get-deployment --deployment-id "$DEPLOYMENT_ID" \
    --query 'deploymentInfo.{status:status,config:deploymentConfigName,created:createTime,rollback:rollbackInfo.rollbackMessage,error:errorInformation.message}' \
    --output table
fi
