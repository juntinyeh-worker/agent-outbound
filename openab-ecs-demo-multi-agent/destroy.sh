#!/usr/bin/env bash
# destroy.sh — Tear down the ECS multi-agent deployment
# ⚠️ DESTRUCTIVE — removes all ECS services, tasks, VPC resources
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SCRIPT_DIR/.env" ]; then echo "No .env found"; exit 1; fi
set -a; source "$SCRIPT_DIR/.env"; set +a

echo "⚠️  This will destroy the ECS cluster and all resources for: $CLUSTER_NAME"
echo "    Press Ctrl+C to cancel, or Enter to continue..."
read -r

NAMESPACE="${NAMESPACE:-openab}"

echo "==> Stopping services..."
for svc in router planner developer reviewer; do
  aws ecs update-service --cluster "$CLUSTER_NAME" --service "${NAMESPACE}-${svc}" \
    --desired-count 0 --region "$AWS_REGION" 2>/dev/null || true
  aws ecs delete-service --cluster "$CLUSTER_NAME" --service "${NAMESPACE}-${svc}" \
    --force --region "$AWS_REGION" 2>/dev/null || true
done

echo "==> Deleting cluster..."
aws ecs delete-cluster --cluster "$CLUSTER_NAME" --region "$AWS_REGION" 2>/dev/null || true

echo "==> Cleaning SSM parameters..."
for param in discord-bot-token router-api-key planner-api-key developer-api-key reviewer-api-key gh-token; do
  aws ssm delete-parameter --name "/${NAMESPACE}/${param}" --region "$AWS_REGION" 2>/dev/null || true
done

echo ""
echo "✅ ECS resources deleted."
echo "   Note: VPC, EFS, NAT Gateway, and ECR repos are NOT deleted (manual cleanup if needed)."
