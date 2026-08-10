#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# deploy.sh — Configurable OpenAB ECS Deployment
#
# Dual-region: ECS/ECR in ECS_REGION, sandbox-* admin in SANDBOX_REGION.
#
# Usage:
#   ./deploy.sh infra          Deploy CloudFormation infrastructure stack
#   ./deploy.sh service        Register task definition + create/update ECS service
#   ./deploy.sh webhook        Register Telegram webhook
#   ./deploy.sh all            infra + service + webhook
#   ./deploy.sh status         Show deployment status
#   ./deploy.sh destroy        Tear down everything
#   ./deploy.sh push-image     Build and push custom image to ECR
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env.conf"

# --- Load config ---
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: ${ENV_FILE} not found. Copy env.conf.example to env.conf and fill in values."
    exit 1
fi
# shellcheck source=env.conf
source "$ENV_FILE"

# --- Resolve AWS CLI ---
export PATH="/home/agent/aws-cli/v2/2.34.57/dist:/home/agent/bin:$PATH"

# --- Resolve defaults ---
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
ECS_REGION="${ECS_REGION:?Set ECS_REGION in env.conf}"
SANDBOX_REGION="${SANDBOX_REGION:?Set SANDBOX_REGION in env.conf}"
RESOURCE_PREFIX="${RESOURCE_PREFIX:-sandbox}"
STACK_NAME="${STACK_NAME:-${RESOURCE_PREFIX}-openab-infra}"
ECS_CLUSTER_NAME="${ECS_CLUSTER_NAME:-${RESOURCE_PREFIX}-openab}"
ECS_SERVICE_NAME="${ECS_SERVICE_NAME:-${RESOURCE_PREFIX}-openab-telegram}"
ECS_TASK_FAMILY="${ECS_TASK_FAMILY:-${RESOURCE_PREFIX}-openab-telegram}"
ECR_REPO_NAME="${ECR_REPO_NAME:-${RESOURCE_PREFIX}-openab}"
OAB_IMAGE="${OAB_IMAGE:-ghcr.io/openabdev/openab:stable-kiro}"
ECS_CPU="${ECS_CPU:-256}"
ECS_MEMORY="${ECS_MEMORY:-512}"
ECS_DESIRED_COUNT="${ECS_DESIRED_COUNT:-1}"
ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-ENABLED}"

ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${ECS_REGION}.amazonaws.com/${ECR_REPO_NAME}"

# ============================================================================
# HELPERS
# ============================================================================

log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { echo "[ERROR] $*" >&2; }

resolve_vpc() {
    if [[ -n "${VPC_ID:-}" ]]; then
        return
    fi
    log "Resolving default VPC in ${ECS_REGION}..."
    VPC_ID=$(aws ec2 describe-vpcs \
        --region "${ECS_REGION}" \
        --filters "Name=is-default,Values=true" \
        --query 'Vpcs[0].VpcId' \
        --output text)
    if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
        err "No default VPC found in ${ECS_REGION}. Set VPC_ID in env.conf."
        exit 1
    fi
    log "Using VPC: ${VPC_ID}"
}

resolve_subnets() {
    if [[ -n "${SUBNET_IDS:-}" ]]; then
        return
    fi
    log "Resolving subnets in VPC ${VPC_ID}..."
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --region "${ECS_REGION}" \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId | [0:3]' \
        --output text | tr '\t' ',')
    if [[ -z "$SUBNET_IDS" ]]; then
        # Fallback: grab any subnets
        SUBNET_IDS=$(aws ec2 describe-subnets \
            --region "${ECS_REGION}" \
            --filters "Name=vpc-id,Values=${VPC_ID}" \
            --query 'Subnets[*].SubnetId | [0:3]' \
            --output text | tr '\t' ',')
    fi
    log "Using subnets: ${SUBNET_IDS}"
}

# ============================================================================
# COMMANDS
# ============================================================================

cmd_infra() {
    log "Deploying infrastructure stack: ${STACK_NAME} in ${ECS_REGION}"
    resolve_vpc

    # Convert comma-separated subnets to CFN list format
    resolve_subnets
    local subnet_list="${SUBNET_IDS}"

    aws cloudformation deploy \
        --region "${ECS_REGION}" \
        --stack-name "${STACK_NAME}" \
        --template-file "${SCRIPT_DIR}/cfn-infra.yaml" \
        --capabilities CAPABILITY_NAMED_IAM \
        --parameter-overrides \
            ResourcePrefix="${RESOURCE_PREFIX}" \
            EcsRegion="${ECS_REGION}" \
            SandboxRegion="${SANDBOX_REGION}" \
            VpcId="${VPC_ID}" \
            SubnetIds="${subnet_list}" \
        --tags \
            Key=Project,Value=openab \
            Key=Environment,Value=sandbox \
        --no-fail-on-empty-changeset

    log "Stack deployed. Fetching outputs..."
    aws cloudformation describe-stacks \
        --region "${ECS_REGION}" \
        --stack-name "${STACK_NAME}" \
        --query 'Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}' \
        --output table
}

cmd_service() {
    log "Registering ECS task definition: ${ECS_TASK_FAMILY}"

    # Get role ARNs from stack outputs
    local exec_role_arn task_role_arn sg_id log_group
    exec_role_arn=$(aws cloudformation describe-stacks \
        --region "${ECS_REGION}" \
        --stack-name "${STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`TaskExecutionRoleArn`].OutputValue' \
        --output text)
    task_role_arn=$(aws cloudformation describe-stacks \
        --region "${ECS_REGION}" \
        --stack-name "${STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`TaskRoleArn`].OutputValue' \
        --output text)
    sg_id=$(aws cloudformation describe-stacks \
        --region "${ECS_REGION}" \
        --stack-name "${STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`SecurityGroupId`].OutputValue' \
        --output text)
    log_group=$(aws cloudformation describe-stacks \
        --region "${ECS_REGION}" \
        --stack-name "${STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`LogGroupName`].OutputValue' \
        --output text)

    # Build environment vars
    local env_vars="["
    env_vars+="{\"name\":\"TELEGRAM_ALLOW_ALL_USERS\",\"value\":\"${TELEGRAM_ALLOW_ALL_USERS}\"},"
    env_vars+="{\"name\":\"AWS_DEFAULT_REGION\",\"value\":\"${SANDBOX_REGION}\"},"
    env_vars+="{\"name\":\"ECS_REGION\",\"value\":\"${ECS_REGION}\"},"
    env_vars+="{\"name\":\"SANDBOX_REGION\",\"value\":\"${SANDBOX_REGION}\"}"
    env_vars+="]"

    # Build secrets (from SSM or Secrets Manager)
    local secrets="["
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        # Store in SSM if not already there
        aws ssm put-parameter \
            --region "${ECS_REGION}" \
            --name "/${RESOURCE_PREFIX}/openab/telegram-bot-token" \
            --value "${TELEGRAM_BOT_TOKEN}" \
            --type SecureString \
            --overwrite 2>/dev/null || true
        secrets+="{\"name\":\"TELEGRAM_BOT_TOKEN\",\"valueFrom\":\"arn:aws:ssm:${ECS_REGION}:${AWS_ACCOUNT_ID}:parameter/${RESOURCE_PREFIX}/openab/telegram-bot-token\"},"
    fi
    if [[ -n "${KIRO_API_KEY:-}" ]]; then
        aws ssm put-parameter \
            --region "${ECS_REGION}" \
            --name "/${RESOURCE_PREFIX}/openab/kiro-api-key" \
            --value "${KIRO_API_KEY}" \
            --type SecureString \
            --overwrite 2>/dev/null || true
        secrets+="{\"name\":\"KIRO_API_KEY\",\"valueFrom\":\"arn:aws:ssm:${ECS_REGION}:${AWS_ACCOUNT_ID}:parameter/${RESOURCE_PREFIX}/openab/kiro-api-key\"},"
    fi
    if [[ -n "${TELEGRAM_ALLOWED_USER_ID:-}" ]]; then
        env_vars=$(echo "$env_vars" | sed 's/]$//')
        env_vars+=",{\"name\":\"TELEGRAM_ALLOWED_USERS\",\"value\":\"${TELEGRAM_ALLOWED_USER_ID}\"}]"
    fi
    # Remove trailing comma and close
    secrets=$(echo "$secrets" | sed 's/,$//')
    secrets+="]"

    # Register task definition
    local task_def
    task_def=$(cat <<EOF
{
    "family": "${ECS_TASK_FAMILY}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "${ECS_CPU}",
    "memory": "${ECS_MEMORY}",
    "executionRoleArn": "${exec_role_arn}",
    "taskRoleArn": "${task_role_arn}",
    "containerDefinitions": [
        {
            "name": "openab",
            "image": "${OAB_IMAGE}",
            "essential": true,
            "portMappings": [
                {"containerPort": 8080, "protocol": "tcp"}
            ],
            "environment": ${env_vars},
            "secrets": ${secrets},
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "${log_group}",
                    "awslogs-region": "${ECS_REGION}",
                    "awslogs-stream-prefix": "oab"
                }
            },
            "healthCheck": {
                "command": ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"],
                "interval": 30,
                "timeout": 5,
                "retries": 3,
                "startPeriod": 30
            }
        }
    ]
}
EOF
    )

    echo "$task_def" > /tmp/task-def.json
    aws ecs register-task-definition \
        --region "${ECS_REGION}" \
        --cli-input-json file:///tmp/task-def.json \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text
    log "Task definition registered."

    # Create or update service
    resolve_vpc
    resolve_subnets
    local subnet_json
    subnet_json=$(echo "${SUBNET_IDS}" | tr ',' '\n' | sed 's/.*/"&"/' | paste -sd ',' -)

    local service_exists
    service_exists=$(aws ecs describe-services \
        --region "${ECS_REGION}" \
        --cluster "${ECS_CLUSTER_NAME}" \
        --services "${ECS_SERVICE_NAME}" \
        --query 'services[?status==`ACTIVE`].serviceName' \
        --output text 2>/dev/null || echo "")

    if [[ -n "$service_exists" ]]; then
        log "Updating existing service: ${ECS_SERVICE_NAME}"
        aws ecs update-service \
            --region "${ECS_REGION}" \
            --cluster "${ECS_CLUSTER_NAME}" \
            --service "${ECS_SERVICE_NAME}" \
            --task-definition "${ECS_TASK_FAMILY}" \
            --desired-count "${ECS_DESIRED_COUNT}" \
            --force-new-deployment \
            --query 'service.serviceName' \
            --output text
    else
        log "Creating service: ${ECS_SERVICE_NAME}"
        aws ecs create-service \
            --region "${ECS_REGION}" \
            --cluster "${ECS_CLUSTER_NAME}" \
            --service-name "${ECS_SERVICE_NAME}" \
            --task-definition "${ECS_TASK_FAMILY}" \
            --desired-count "${ECS_DESIRED_COUNT}" \
            --launch-type FARGATE \
            --network-configuration "{
                \"awsvpcConfiguration\": {
                    \"subnets\": [${subnet_json}],
                    \"securityGroups\": [\"${sg_id}\"],
                    \"assignPublicIp\": \"${ASSIGN_PUBLIC_IP}\"
                }
            }" \
            --enable-execute-command \
            --query 'service.serviceName' \
            --output text
    fi
    log "Service deployed: ${ECS_SERVICE_NAME}"
    rm -f /tmp/task-def.json
}

cmd_webhook() {
    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        err "TELEGRAM_BOT_TOKEN not set in env.conf"
        exit 1
    fi

    local webhook_url="${WEBHOOK_URL:-}"
    if [[ -z "$webhook_url" ]]; then
        # Try to get the task public IP
        log "Looking for task public IP..."
        local task_arn
        task_arn=$(aws ecs list-tasks \
            --region "${ECS_REGION}" \
            --cluster "${ECS_CLUSTER_NAME}" \
            --service-name "${ECS_SERVICE_NAME}" \
            --query 'taskArns[0]' \
            --output text 2>/dev/null || echo "None")

        if [[ "$task_arn" != "None" && -n "$task_arn" ]]; then
            local eni_id
            eni_id=$(aws ecs describe-tasks \
                --region "${ECS_REGION}" \
                --cluster "${ECS_CLUSTER_NAME}" \
                --tasks "$task_arn" \
                --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
                --output text 2>/dev/null || echo "")

            if [[ -n "$eni_id" ]]; then
                local public_ip
                public_ip=$(aws ec2 describe-network-interfaces \
                    --region "${ECS_REGION}" \
                    --network-interface-ids "$eni_id" \
                    --query 'NetworkInterfaces[0].Association.PublicIp' \
                    --output text 2>/dev/null || echo "None")

                if [[ "$public_ip" != "None" && -n "$public_ip" ]]; then
                    webhook_url="http://${public_ip}:8080"
                    log "Found task IP: ${public_ip}"
                    log "WARNING: Using HTTP (not HTTPS). For production, set up API Gateway or ALB with TLS."
                fi
            fi
        fi

        if [[ -z "$webhook_url" ]]; then
            err "Could not determine webhook URL. Set WEBHOOK_URL in env.conf or wait for task to start."
            exit 1
        fi
    fi

    log "Registering Telegram webhook: ${webhook_url}/webhook/telegram"
    curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook?url=${webhook_url}/webhook/telegram" | python3 -m json.tool 2>/dev/null || true
}

cmd_status() {
    log "=== Stack: ${STACK_NAME} (${ECS_REGION}) ==="
    aws cloudformation describe-stacks \
        --region "${ECS_REGION}" \
        --stack-name "${STACK_NAME}" \
        --query 'Stacks[0].{Status:StackStatus,Created:CreationTime}' \
        --output table 2>/dev/null || echo "  Stack not found."

    echo
    log "=== ECS Service: ${ECS_SERVICE_NAME} ==="
    aws ecs describe-services \
        --region "${ECS_REGION}" \
        --cluster "${ECS_CLUSTER_NAME}" \
        --services "${ECS_SERVICE_NAME}" \
        --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount,TaskDef:taskDefinition}' \
        --output table 2>/dev/null || echo "  Service not found."

    echo
    log "=== Tasks ==="
    aws ecs list-tasks \
        --region "${ECS_REGION}" \
        --cluster "${ECS_CLUSTER_NAME}" \
        --service-name "${ECS_SERVICE_NAME}" \
        --query 'taskArns' \
        --output text 2>/dev/null || echo "  No tasks."

    echo
    log "=== Configuration ==="
    echo "  ECS Region:     ${ECS_REGION}"
    echo "  Sandbox Region: ${SANDBOX_REGION}"
    echo "  Prefix:         ${RESOURCE_PREFIX}"
    echo "  Image:          ${OAB_IMAGE}"
    echo "  ECR:            ${ECR_URI}"
}

cmd_push_image() {
    local image_path="${2:-}"
    if [[ -z "$image_path" ]]; then
        err "Usage: ./deploy.sh push-image <path-to-dockerfile-dir>"
        exit 1
    fi

    log "Logging into ECR (${ECS_REGION})..."
    aws ecr get-login-password --region "${ECS_REGION}" | \
        docker login --username AWS --password-stdin \
        "${AWS_ACCOUNT_ID}.dkr.ecr.${ECS_REGION}.amazonaws.com"

    log "Building and pushing: ${ECR_URI}:latest"
    docker buildx build \
        --platform linux/arm64 \
        -t "${ECR_URI}:latest" \
        -t "${ECR_URI}:$(date +%Y%m%d-%H%M%S)" \
        --push \
        "$image_path"

    log "Pushed: ${ECR_URI}:latest"
}

cmd_destroy() {
    log "WARNING: This will delete the ECS service and CloudFormation stack."
    read -rp "Continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi

    # Delete service
    log "Deleting ECS service..."
    aws ecs update-service \
        --region "${ECS_REGION}" \
        --cluster "${ECS_CLUSTER_NAME}" \
        --service "${ECS_SERVICE_NAME}" \
        --desired-count 0 2>/dev/null || true
    aws ecs delete-service \
        --region "${ECS_REGION}" \
        --cluster "${ECS_CLUSTER_NAME}" \
        --service "${ECS_SERVICE_NAME}" \
        --force 2>/dev/null || true

    # Delete stack
    log "Deleting CloudFormation stack..."
    aws cloudformation delete-stack \
        --region "${ECS_REGION}" \
        --stack-name "${STACK_NAME}"
    aws cloudformation wait stack-delete-complete \
        --region "${ECS_REGION}" \
        --stack-name "${STACK_NAME}" || true

    # Remove SSM params
    log "Cleaning up SSM parameters..."
    aws ssm delete-parameter --region "${ECS_REGION}" \
        --name "/${RESOURCE_PREFIX}/openab/telegram-bot-token" 2>/dev/null || true
    aws ssm delete-parameter --region "${ECS_REGION}" \
        --name "/${RESOURCE_PREFIX}/openab/kiro-api-key" 2>/dev/null || true

    # Remove webhook
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook" | python3 -m json.tool 2>/dev/null || true
    fi

    log "Destroyed."
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-help}" in
    infra)      cmd_infra ;;
    service)    cmd_service ;;
    webhook)    cmd_webhook ;;
    push-image) cmd_push_image "$@" ;;
    status)     cmd_status ;;
    all)
        cmd_infra
        cmd_service
        cmd_webhook
        log "Deployment complete!"
        log "  ECS Region:     ${ECS_REGION}"
        log "  Sandbox Region: ${SANDBOX_REGION}"
        log "  Cluster:        ${ECS_CLUSTER_NAME}"
        log "  Service:        ${ECS_SERVICE_NAME}"
        ;;
    destroy)    cmd_destroy ;;
    help|*)
        cat <<EOF
OpenAB ECS Sandbox Deployment

Usage: ./deploy.sh <command>

Commands:
  infra        Deploy CloudFormation stack (ECS cluster, IAM, ECR, SG, logs)
  service      Register task definition + create/update ECS service
  webhook      Register Telegram webhook
  push-image   Build and push custom image to ECR
  all          infra + service + webhook
  status       Show deployment status
  destroy      Tear down everything

Configuration:
  Edit env.conf to set regions, credentials, and options.
  
  Key settings:
    ECS_REGION       — Where ECS/ECR run (default: us-west-2)
    SANDBOX_REGION   — Where task role has sandbox-* admin (default: us-east-1)
    RESOURCE_PREFIX  — Prefix for all resources (default: sandbox)

Examples:
  # Deploy everything
  ./deploy.sh all

  # Change regions
  sed -i 's/us-west-2/ap-northeast-1/' env.conf  # ECS in Tokyo
  sed -i 's/us-east-1/us-west-2/' env.conf       # Sandbox in Oregon
  ./deploy.sh all

  # Push a custom Strands image
  ./deploy.sh push-image ../strands-runtime/
EOF
        ;;
esac
