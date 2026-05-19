#!/usr/bin/env bash
# deploy.sh — Deploy single-bot multi-agent system on ECS Fargate
# Usage: ./deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################################################################
# Load config
###############################################################################
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env && vim .env"
  exit 1
fi
set -a; source "$SCRIPT_DIR/.env"; set +a

: "${AWS_REGION:?}"
: "${CLUSTER_NAME:?}"
: "${DISCORD_BOT_TOKEN:?}"
: "${DISCORD_CHANNEL_ID:?}"
: "${ROUTER_API_KEY:?}"
: "${PLANNER_API_KEY:?}"
: "${DEVELOPER_API_KEY:?}"
: "${REVIEWER_API_KEY:?}"

NAMESPACE="${NAMESPACE:-openab}"
ECR_REPO_GEMINI="${ECR_REPO_GEMINI:-openab-gemini}"
ECR_REPO_CLAUDE="${ECR_REPO_CLAUDE:-openab-claude}"

echo "════════════════════════════════════════════════════════════"
echo " OpenAB Multi-Agent — ECS Fargate Deployment"
echo "════════════════════════════════════════════════════════════"

###############################################################################
# Preflight
###############################################################################
echo "==> [1/7] Preflight checks..."
for cmd in aws docker git; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "    Account: $AWS_ACCOUNT_ID, Region: $AWS_REGION ✓"

###############################################################################
# ECR — build and push images
###############################################################################
echo "==> [2/7] Building and pushing images..."
OPENAB_SRC="$HOME/.openab-src"
if [ ! -d "$OPENAB_SRC" ]; then
  git clone --depth 1 https://github.com/openabdev/openab.git "$OPENAB_SRC"
fi

for repo in "$ECR_REPO_GEMINI" "$ECR_REPO_CLAUDE"; do
  aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" &>/dev/null || \
    aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION" >/dev/null
done

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

ECR_GEMINI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_GEMINI}:latest"
ECR_CLAUDE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_CLAUDE}:latest"

docker build -f "$OPENAB_SRC/Dockerfile.gemini" -t "$ECR_GEMINI" "$OPENAB_SRC"
docker push "$ECR_GEMINI"
docker build -f "$OPENAB_SRC/Dockerfile.claude" -t "$ECR_CLAUDE" "$OPENAB_SRC"
docker push "$ECR_CLAUDE"
echo "    Images pushed ✓"

###############################################################################
# VPC + Networking
###############################################################################
echo "==> [3/7] Setting up VPC..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
  --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text --region "$AWS_REGION")
  aws ec2 create-tags --resources "$VPC_ID" --tags "Key=Name,Value=${CLUSTER_NAME}-vpc" --region "$AWS_REGION"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support --region "$AWS_REGION"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$AWS_REGION"

  # Subnets (2 AZs)
  AZS=($(aws ec2 describe-availability-zones --region "$AWS_REGION" --query 'AvailabilityZones[:2].ZoneName' --output text))
  SUBNET_PRIV_1=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.1.0/24 --availability-zone "${AZS[0]}" --query 'Subnet.SubnetId' --output text --region "$AWS_REGION")
  SUBNET_PRIV_2=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.2.0/24 --availability-zone "${AZS[1]}" --query 'Subnet.SubnetId' --output text --region "$AWS_REGION")
  SUBNET_PUB=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.100.0/24 --availability-zone "${AZS[0]}" --query 'Subnet.SubnetId' --output text --region "$AWS_REGION")

  # Internet Gateway + NAT
  IGW=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text --region "$AWS_REGION")
  aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW" --region "$AWS_REGION"

  # Public route table
  RTB_PUB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text --region "$AWS_REGION")
  aws ec2 create-route --route-table-id "$RTB_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" --region "$AWS_REGION" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RTB_PUB" --subnet-id "$SUBNET_PUB" --region "$AWS_REGION" >/dev/null

  # NAT Gateway
  EIP=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text --region "$AWS_REGION")
  NAT=$(aws ec2 create-nat-gateway --subnet-id "$SUBNET_PUB" --allocation-id "$EIP" --query 'NatGateway.NatGatewayId' --output text --region "$AWS_REGION")
  echo "    Waiting for NAT Gateway..."
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT" --region "$AWS_REGION"

  # Private route table
  RTB_PRIV=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text --region "$AWS_REGION")
  aws ec2 create-route --route-table-id "$RTB_PRIV" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT" --region "$AWS_REGION" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RTB_PRIV" --subnet-id "$SUBNET_PRIV_1" --region "$AWS_REGION" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RTB_PRIV" --subnet-id "$SUBNET_PRIV_2" --region "$AWS_REGION" >/dev/null

  # Security group (outbound only)
  SG=$(aws ec2 create-security-group --group-name "${CLUSTER_NAME}-sg" --description "OpenAB agents" --vpc-id "$VPC_ID" --query 'GroupId' --output text --region "$AWS_REGION")
  # Allow internal traffic between containers
  aws ec2 authorize-security-group-ingress --group-id "$SG" --source-group "$SG" --protocol -1 --region "$AWS_REGION" >/dev/null
else
  SUBNET_PRIV_1=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=10.0.1.0/24" --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")
  SUBNET_PRIV_2=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=10.0.2.0/24" --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")
  SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${CLUSTER_NAME}-sg" --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION")
fi
echo "    VPC: $VPC_ID ✓"

###############################################################################
# EFS
###############################################################################
echo "==> [4/7] Setting up EFS..."
EFS_ID=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='Name'&&Value=='${CLUSTER_NAME}-efs']].FileSystemId" --output text --region "$AWS_REGION")

if [ -z "$EFS_ID" ] || [ "$EFS_ID" = "None" ]; then
  EFS_ID=$(aws efs create-file-system --performance-mode generalPurpose --tags "Key=Name,Value=${CLUSTER_NAME}-efs" --query 'FileSystemId' --output text --region "$AWS_REGION")
  aws efs create-mount-target --file-system-id "$EFS_ID" --subnet-id "$SUBNET_PRIV_1" --security-groups "$SG" --region "$AWS_REGION" >/dev/null
  aws efs create-mount-target --file-system-id "$EFS_ID" --subnet-id "$SUBNET_PRIV_2" --security-groups "$SG" --region "$AWS_REGION" >/dev/null
fi
echo "    EFS: $EFS_ID ✓"

###############################################################################
# SSM Parameters (secrets)
###############################################################################
echo "==> [5/7] Storing secrets in SSM..."
aws ssm put-parameter --name "/${NAMESPACE}/discord-bot-token" --value "$DISCORD_BOT_TOKEN" --type SecureString --overwrite --region "$AWS_REGION" >/dev/null
aws ssm put-parameter --name "/${NAMESPACE}/router-api-key" --value "$ROUTER_API_KEY" --type SecureString --overwrite --region "$AWS_REGION" >/dev/null
aws ssm put-parameter --name "/${NAMESPACE}/planner-api-key" --value "$PLANNER_API_KEY" --type SecureString --overwrite --region "$AWS_REGION" >/dev/null
aws ssm put-parameter --name "/${NAMESPACE}/developer-api-key" --value "$DEVELOPER_API_KEY" --type SecureString --overwrite --region "$AWS_REGION" >/dev/null
aws ssm put-parameter --name "/${NAMESPACE}/reviewer-api-key" --value "$REVIEWER_API_KEY" --type SecureString --overwrite --region "$AWS_REGION" >/dev/null
[ -n "${GH_TOKEN:-}" ] && aws ssm put-parameter --name "/${NAMESPACE}/gh-token" --value "$GH_TOKEN" --type SecureString --overwrite --region "$AWS_REGION" >/dev/null
echo "    Secrets stored ✓"

###############################################################################
# ECS Cluster + Service Connect
###############################################################################
echo "==> [6/7] Creating ECS cluster..."
aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$AWS_REGION" --query 'clusters[0].status' --output text 2>/dev/null | grep -q ACTIVE || \
  aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --service-connect-defaults "namespace=${NAMESPACE}.local" >/dev/null

# Task execution role
EXEC_ROLE_NAME="${CLUSTER_NAME}-exec-role"
if ! aws iam get-role --role-name "$EXEC_ROLE_NAME" &>/dev/null; then
  aws iam create-role --role-name "$EXEC_ROLE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  aws iam put-role-policy --role-name "$EXEC_ROLE_NAME" --policy-name ssm-read \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ssm:GetParameters\",\"ssm:GetParameter\"],\"Resource\":\"arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter/${NAMESPACE}/*\"}]}"
fi
EXEC_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EXEC_ROLE_NAME}"
echo "    Cluster: $CLUSTER_NAME ✓"

###############################################################################
# Register task definitions + create services
###############################################################################
echo "==> [7/7] Deploying services..."

register_task() {
  local NAME=$1 IMAGE=$2 CPU=$3 MEM=$4 CMD=$5 SECRET_NAME=$6 SECRET_ENV=$7 EFS_ROOT=$8
  local SECRETS="[{\"name\":\"${SECRET_ENV}\",\"valueFrom\":\"arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter/${NAMESPACE}/${SECRET_NAME}\"}]"

  cat > "/tmp/taskdef-${NAME}.json" <<EOF
{
  "family": "${NAMESPACE}-${NAME}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "${CPU}",
  "memory": "${MEM}",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "containerDefinitions": [{
    "name": "${NAME}",
    "image": "${IMAGE}",
    "essential": true,
    "command": ${CMD},
    "secrets": ${SECRETS},
    "portMappings": [{"containerPort": 8080, "name": "mcp"}],
    "mountPoints": [{"sourceVolume": "home", "containerPath": "/home/node"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${NAMESPACE}-${NAME}",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "ecs",
        "awslogs-create-group": "true"
      }
    }
  }],
  "volumes": [{
    "name": "home",
    "efsVolumeConfiguration": {
      "fileSystemId": "${EFS_ID}",
      "rootDirectory": "/${EFS_ROOT}"
    }
  }]
}
EOF
  aws ecs register-task-definition --cli-input-json "file:///tmp/taskdef-${NAME}.json" --region "$AWS_REGION" >/dev/null
}

create_service() {
  local NAME=$1 PORT_NAME=$2
  local SVC_EXISTS=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "${NAMESPACE}-${NAME}" --region "$AWS_REGION" --query 'services[0].status' --output text 2>/dev/null)

  if [ "$SVC_EXISTS" = "ACTIVE" ]; then
    aws ecs update-service --cluster "$CLUSTER_NAME" --service "${NAMESPACE}-${NAME}" \
      --task-definition "${NAMESPACE}-${NAME}" --force-new-deployment --region "$AWS_REGION" >/dev/null
  else
    aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "${NAMESPACE}-${NAME}" \
      --task-definition "${NAMESPACE}-${NAME}" --desired-count 1 --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_PRIV_1,$SUBNET_PRIV_2],securityGroups=[$SG],assignPublicIp=DISABLED}" \
      --service-connect-configuration "{\"enabled\":true,\"namespace\":\"${NAMESPACE}.local\",\"services\":[{\"portName\":\"mcp\",\"clientAliases\":[{\"port\":8080,\"dnsName\":\"${NAME}.${NAMESPACE}.local\"}]}]}" \
      --region "$AWS_REGION" >/dev/null
  fi
}

# Router (has Discord bot token + MCP config pointing to backend agents)
ROUTER_SECRETS="[{\"name\":\"GEMINI_API_KEY\",\"valueFrom\":\"arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter/${NAMESPACE}/router-api-key\"},{\"name\":\"DISCORD_BOT_TOKEN\",\"valueFrom\":\"arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter/${NAMESPACE}/discord-bot-token\"}]"
cat > /tmp/taskdef-router.json <<EOF
{
  "family": "${NAMESPACE}-router",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "containerDefinitions": [{
    "name": "router",
    "image": "${ECR_GEMINI}",
    "essential": true,
    "command": ["openab", "run", "-c", "/etc/openab/config.toml"],
    "secrets": ${ROUTER_SECRETS},
    "environment": [
      {"name": "DISCORD_CHANNEL_ID", "value": "${DISCORD_CHANNEL_ID}"}
    ],
    "mountPoints": [{"sourceVolume": "home", "containerPath": "/home/node"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${NAMESPACE}-router",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "ecs",
        "awslogs-create-group": "true"
      }
    }
  }],
  "volumes": [{
    "name": "home",
    "efsVolumeConfiguration": {
      "fileSystemId": "${EFS_ID}",
      "rootDirectory": "/router"
    }
  }]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/taskdef-router.json --region "$AWS_REGION" >/dev/null

# Backend agents
register_task "planner" "$ECR_GEMINI" "512" "1024" \
  "[\"gemini\",\"--acp\",\"--mcp-server\",\"--port\",\"8080\"]" \
  "planner-api-key" "GEMINI_API_KEY" "planner"

register_task "developer" "$ECR_CLAUDE" "512" "2048" \
  "[\"claude-agent-acp\",\"--mcp-server\",\"--port\",\"8080\"]" \
  "developer-api-key" "ANTHROPIC_API_KEY" "developer"

register_task "reviewer" "$ECR_GEMINI" "512" "1024" \
  "[\"gemini\",\"--acp\",\"--mcp-server\",\"--port\",\"8080\"]" \
  "reviewer-api-key" "GEMINI_API_KEY" "reviewer"

# Create services (backend first, then router)
create_service "planner" "mcp"
create_service "developer" "mcp"
create_service "reviewer" "mcp"

# Router service (no Service Connect port — it's a client, not a server)
SVC_EXISTS=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "${NAMESPACE}-router" --region "$AWS_REGION" --query 'services[0].status' --output text 2>/dev/null)
if [ "$SVC_EXISTS" = "ACTIVE" ]; then
  aws ecs update-service --cluster "$CLUSTER_NAME" --service "${NAMESPACE}-router" \
    --task-definition "${NAMESPACE}-router" --force-new-deployment --region "$AWS_REGION" >/dev/null
else
  aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "${NAMESPACE}-router" \
    --task-definition "${NAMESPACE}-router" --desired-count 1 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_PRIV_1,$SUBNET_PRIV_2],securityGroups=[$SG],assignPublicIp=DISABLED}" \
    --service-connect-configuration "{\"enabled\":true,\"namespace\":\"${NAMESPACE}.local\",\"services\":[]}" \
    --region "$AWS_REGION" >/dev/null
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo " ✅  Deployed! 4 services on ECS Fargate"
echo "════════════════════════════════════════════════════════════"
echo ""
echo " Cluster:  $CLUSTER_NAME"
echo " Services: ${NAMESPACE}-router, ${NAMESPACE}-planner, ${NAMESPACE}-developer, ${NAMESPACE}-reviewer"
echo ""
echo " Service discovery (internal DNS):"
echo "   planner.${NAMESPACE}.local:8080"
echo "   developer.${NAMESPACE}.local:8080"
echo "   reviewer.${NAMESPACE}.local:8080"
echo ""
echo " Commands:"
echo "   aws ecs list-services --cluster $CLUSTER_NAME --region $AWS_REGION"
echo "   aws ecs describe-services --cluster $CLUSTER_NAME --services ${NAMESPACE}-router --region $AWS_REGION"
echo "   aws logs tail /ecs/${NAMESPACE}-router --region $AWS_REGION --follow"
echo ""
echo " → @mention your bot in Discord"
