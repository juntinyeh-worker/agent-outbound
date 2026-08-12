#!/usr/bin/env bash
# destroy.sh — Tear down the Strands Worker Agent from AgentCore Runtime.
#
# Usage:
#   ./destroy.sh                  # Delete runtime only, keep ECR image and role
#   DELETE_ALL=true ./destroy.sh  # Also delete ECR repo and IAM role
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
RUNTIME_NAME="${RUNTIME_NAME:-strands-worker-agent}"
ECR_REPO="${ECR_REPO:-agentcore-strands-worker}"
ROLE_NAME="${ROLE_NAME:-agentcore-strands-execution-role}"
DELETE_ALL="${DELETE_ALL:-false}"

echo "==> Destroying Strands Worker Agent"
echo "    Region:  $REGION"
echo "    Runtime: $RUNTIME_NAME"
echo ""

# Find and delete the runtime
RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
  --query "agentRuntimeSummaries[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId" \
  --output text 2>/dev/null || echo "")

if [ -n "$RUNTIME_ID" ] && [ "$RUNTIME_ID" != "None" ]; then
  echo "    Deleting AgentCore runtime: $RUNTIME_ID"
  aws bedrock-agentcore-control delete-agent-runtime \
    --agent-runtime-id "$RUNTIME_ID" \
    --region "$REGION" 2>/dev/null || echo "    (already deleted or not found)"
  echo "    ✅ Runtime deleted"
else
  echo "    Runtime not found (already deleted?)"
fi

if [ "$DELETE_ALL" = "true" ]; then
  echo ""
  echo "==> Cleaning up ECR and IAM (DELETE_ALL=true)"

  # Delete ECR repository
  echo "    Deleting ECR repo: $ECR_REPO"
  aws ecr delete-repository --repository-name "$ECR_REPO" --force --region "$REGION" 2>/dev/null || \
    echo "    (not found)"

  # Delete IAM role
  echo "    Deleting IAM role: $ROLE_NAME"
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "strands-agent-permissions" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || \
    echo "    (not found)"

  echo "    ✅ All resources cleaned up"
fi

echo ""
echo "Done."
