#!/usr/bin/env bash
# deploy.sh — Deploy the Strands Worker Agent to AWS AgentCore Runtime.
#
# This creates:
#   1. ECR repository and pushes the container image
#   2. IAM execution role for AgentCore
#   3. AgentCore Runtime pointing to the image
#
# Prerequisites:
#   - AWS CLI configured with sufficient permissions
#   - Docker (or finch/podman) installed
#   - Bedrock model access enabled in your account
#
# Usage:
#   ./deploy.sh                          # Deploy with defaults
#   ./deploy.sh -r us-west-2             # Deploy to us-west-2
#   ./deploy.sh -n my-strands-agent      # Custom runtime name
#   ./deploy.sh --dry-run                # Print config, no AWS calls
#
# After deployment, configure OpenAB:
#   [agentcore]
#   runtime_arn = "<output runtime ARN>"
set -euo pipefail

# Defaults
REGION="${AWS_REGION:-us-east-1}"
RUNTIME_NAME="${RUNTIME_NAME:-strands-worker-agent}"
ECR_REPO="${ECR_REPO:-agentcore-strands-worker}"
ROLE_NAME="${ROLE_NAME:-agentcore-strands-execution-role}"
DRY_RUN=false
PLATFORM="${PLATFORM:-linux/arm64}"   # AgentCore runs arm64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 [-r region] [-n name] [-p platform] [--dry-run]"
  echo ""
  echo "  -r, --region     AWS region (default: us-east-1)"
  echo "  -n, --name       Runtime name (default: strands-worker-agent)"
  echo "  -p, --platform   Docker platform (default: linux/arm64)"
  echo "  --dry-run        Print resolved config and exit"
  echo "  -h, --help       Show this help"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--region)   REGION="$2"; shift 2;;
    -n|--name)     RUNTIME_NAME="$2"; shift 2;;
    -p|--platform) PLATFORM="$2"; shift 2;;
    --dry-run)     DRY_RUN=true; shift;;
    -h|--help)     usage 0;;
    *) echo "Unknown option: $1" >&2; usage 1;;
  esac
done

for cmd in aws docker; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
ECR_URI="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"

cat <<EOF
==> Deployment Configuration
    Region:       $REGION
    Account:      $ACCOUNT
    Runtime:      $RUNTIME_NAME
    ECR Repo:     $ECR_REPO
    ECR URI:      $ECR_URI
    Platform:     $PLATFORM
    Role:         $ROLE_NAME
EOF

if [ "$DRY_RUN" = "true" ]; then
  echo "    (dry-run: no AWS calls)"
  exit 0
fi

# === Step 1: Create ECR repository ===
echo "==> [1/4] ECR repository"
aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$ECR_REPO" --region "$REGION" --output text --query 'repository.repositoryUri'
echo "    ✅ ECR repo ready: $ECR_URI"

# === Step 2: Build and push image ===
echo "==> [2/4] Build and push container image"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
docker buildx build --platform "$PLATFORM" \
  -t "${ECR_URI}:latest" \
  -f "$SCRIPT_DIR/Dockerfile" \
  "$SCRIPT_DIR" --push
echo "    ✅ Image pushed: ${ECR_URI}:latest"

# === Step 3: Create IAM execution role ===
echo "==> [3/4] IAM execution role"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "    Role already exists: $ROLE_ARN"
else
  cat > /tmp/trust-policy.json <<'TRUST'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
TRUST

  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file:///tmp/trust-policy.json \
    --region "$REGION" >/dev/null

  # Attach Bedrock invoke policy
  cat > /tmp/agent-policy.json <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:${REGION}::foundation-model/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT}:log-group:/aws/bedrock-agentcore/*"
    }
  ]
}
POLICY

  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "strands-agent-permissions" \
    --policy-document file:///tmp/agent-policy.json

  echo "    ✅ Created role: $ROLE_ARN"
  # Wait for role propagation
  echo "    Waiting 10s for IAM propagation..."
  sleep 10
fi

# === Step 4: Create AgentCore Runtime ===
echo "==> [4/4] Create AgentCore Runtime"

# Check if runtime already exists
EXISTING=$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
  --query "agentRuntimeSummaries[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId" \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  RUNTIME_ARN="arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT}:runtime/${EXISTING}"
  echo "    Runtime already exists: $RUNTIME_ARN"
  echo "    Updating container image..."
  aws bedrock-agentcore-control update-agent-runtime \
    --agent-runtime-id "$EXISTING" \
    --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${ECR_URI}:latest\"}}" \
    --region "$REGION" >/dev/null 2>&1 || true
else
  RESULT=$(aws bedrock-agentcore-control create-agent-runtime \
    --agent-runtime-name "$RUNTIME_NAME" \
    --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${ECR_URI}:latest\"}}" \
    --role-arn "$ROLE_ARN" \
    --network-configuration '{"networkMode":"PUBLIC"}' \
    --protocol-configuration '{"serverProtocol":"HTTP"}' \
    --region "$REGION" \
    --output json)
  RUNTIME_ARN=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agentRuntimeArn',''))" 2>/dev/null || echo "")
  echo "    ✅ Created runtime: $RUNTIME_ARN"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  DEPLOYMENT COMPLETE"
echo ""
echo "  Runtime ARN: $RUNTIME_ARN"
echo ""
echo "  To integrate with OpenAB, add to your config.toml:"
echo ""
echo "    [agentcore]"
echo "    runtime_arn = \"$RUNTIME_ARN\""
echo ""
echo "  Or for ECS/Fargate deployment with OpenAB, set:"
echo "    AGENTCORE_RUNTIME_ARN=$RUNTIME_ARN"
echo "════════════════════════════════════════════════════════════════"
