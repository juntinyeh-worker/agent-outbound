#!/usr/bin/env bash
set -euo pipefail

#
# deploy.sh — Build and deploy dual OpenAB Telegram instances
#
# Usage:
#   ./deploy.sh setup       # First-time: create ECR repos, AgentCore runtime, set webhooks
#   ./deploy.sh build       # Build and push Strands runtime image
#   ./deploy.sh deploy      # Apply K8s manifests
#   ./deploy.sh webhook     # Register Telegram webhooks
#   ./deploy.sh auth-kiro   # Authenticate kiro-cli in the running pod
#   ./deploy.sh all         # Do everything (build + deploy + webhook)
#   ./deploy.sh destroy     # Tear down K8s resources
#

# ============================================================================
# CONFIGURATION — Edit these or set as environment variables
# ============================================================================

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO_NAME="${ECR_REPO_NAME:-openab-strands-runtime}"
AGENTCORE_RUNTIME_NAME="${AGENTCORE_RUNTIME_NAME:-strands-telegram-agent}"
AGENTCORE_ROLE_ARN="${AGENTCORE_ROLE_ARN:?Set AGENTCORE_ROLE_ARN}"

# Telegram
TELEGRAM_BOT_TOKEN_KIRO="${TELEGRAM_BOT_TOKEN_KIRO:?Set TELEGRAM_BOT_TOKEN_KIRO}"
TELEGRAM_BOT_TOKEN_STRANDS="${TELEGRAM_BOT_TOKEN_STRANDS:?Set TELEGRAM_BOT_TOKEN_STRANDS}"
TELEGRAM_ALLOWED_USER_ID="${TELEGRAM_ALLOWED_USER_ID:?Set TELEGRAM_ALLOWED_USER_ID}"
TELEGRAM_SECRET_TOKEN="${TELEGRAM_SECRET_TOKEN:-$(openssl rand -hex 16)}"

# Webhook URLs (your public HTTPS endpoints)
WEBHOOK_URL_KIRO="${WEBHOOK_URL_KIRO:?Set WEBHOOK_URL_KIRO (e.g. https://oab-kiro.example.com)}"
WEBHOOK_URL_STRANDS="${WEBHOOK_URL_STRANDS:?Set WEBHOOK_URL_STRANDS (e.g. https://oab-strands.example.com)}"

# Kiro
KIRO_API_KEY="${KIRO_API_KEY:?Set KIRO_API_KEY}"

# IRSA role for the strands pod
AGENTCORE_IAM_ROLE_ARN="${AGENTCORE_IAM_ROLE_ARN:-$AGENTCORE_ROLE_ARN}"

# Derived
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
K8S_DIR="${PROJECT_DIR}/k8s"
RUNTIME_DIR="${PROJECT_DIR}/strands-runtime"

# ============================================================================
# FUNCTIONS
# ============================================================================

log() { echo "==> $*"; }

setup_ecr() {
    log "Creating ECR repository: ${ECR_REPO_NAME}"
    aws ecr create-repository \
        --repository-name "${ECR_REPO_NAME}" \
        --region "${AWS_REGION}" \
        --image-scanning-configuration scanOnPush=true \
        2>/dev/null || log "ECR repo already exists"
}

build_and_push() {
    log "Building Strands runtime image (ARM64)..."
    cd "${RUNTIME_DIR}"

    # Login to ECR
    aws ecr get-login-password --region "${AWS_REGION}" | \
        docker login --username AWS --password-stdin \
        "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

    # Build and push
    docker buildx build \
        --platform linux/arm64 \
        -t "${ECR_URI}:latest" \
        -t "${ECR_URI}:$(date +%Y%m%d-%H%M%S)" \
        --push .

    log "Image pushed: ${ECR_URI}:latest"
}

create_agentcore_runtime() {
    log "Creating AgentCore runtime: ${AGENTCORE_RUNTIME_NAME}"

    RUNTIME_ARN=$(aws bedrock-agentcore-control create-agent-runtime \
        --agent-runtime-name "${AGENTCORE_RUNTIME_NAME}" \
        --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${ECR_URI}:latest\"}}" \
        --role-arn "${AGENTCORE_ROLE_ARN}" \
        --network-configuration '{"networkMode":"PUBLIC"}' \
        --protocol-configuration '{"serverProtocol":"HTTP"}' \
        --region "${AWS_REGION}" \
        --query 'agentRuntimeArn' \
        --output text 2>/dev/null) || {
        log "Runtime may already exist. Fetching ARN..."
        RUNTIME_ARN=$(aws bedrock-agentcore-control list-agent-runtimes \
            --region "${AWS_REGION}" \
            --query "agentRuntimes[?agentRuntimeName=='${AGENTCORE_RUNTIME_NAME}'].agentRuntimeArn | [0]" \
            --output text)
    }

    echo "${RUNTIME_ARN}"
    log "AgentCore Runtime ARN: ${RUNTIME_ARN}"
}

create_k8s_secrets() {
    log "Creating Kubernetes secrets..."
    kubectl create namespace openab 2>/dev/null || true

    kubectl create secret generic openab-secrets \
        --namespace openab \
        --from-literal=telegram-bot-token-kiro="${TELEGRAM_BOT_TOKEN_KIRO}" \
        --from-literal=telegram-bot-token-strands="${TELEGRAM_BOT_TOKEN_STRANDS}" \
        --from-literal=kiro-api-key="${KIRO_API_KEY}" \
        --from-literal=telegram-allowed-user-id="${TELEGRAM_ALLOWED_USER_ID}" \
        --from-literal=agentcore-runtime-arn="${RUNTIME_ARN:-${AGENTCORE_RUNTIME_ARN:-unknown}}" \
        --dry-run=client -o yaml | kubectl apply -f -
}

deploy_k8s() {
    log "Deploying Kubernetes manifests..."

    # Update IRSA annotation in-place
    sed "s|\${AGENTCORE_IAM_ROLE_ARN}|${AGENTCORE_IAM_ROLE_ARN}|g" \
        "${K8S_DIR}/04-deployment-strands.yaml" > /tmp/04-deployment-strands.yaml

    kubectl apply -f "${K8S_DIR}/01-configmap.yaml"
    kubectl apply -f "${K8S_DIR}/02-pvc.yaml"
    kubectl apply -f "${K8S_DIR}/03-deployment-kiro.yaml"
    kubectl apply -f /tmp/04-deployment-strands.yaml
    kubectl apply -f "${K8S_DIR}/05-ingress.yaml"

    rm -f /tmp/04-deployment-strands.yaml

    log "Waiting for rollout..."
    kubectl rollout status deployment/openab-kiro -n openab --timeout=120s || true
    kubectl rollout status deployment/openab-strands -n openab --timeout=120s || true
}

register_webhooks() {
    log "Registering Telegram webhooks..."

    # Kiro bot
    curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN_KIRO}/setWebhook?url=${WEBHOOK_URL_KIRO}/webhook/telegram&secret_token=${TELEGRAM_SECRET_TOKEN}" | jq .
    log "Kiro webhook: ${WEBHOOK_URL_KIRO}/webhook/telegram"

    # Strands bot
    curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN_STRANDS}/setWebhook?url=${WEBHOOK_URL_STRANDS}/webhook/telegram&secret_token=${TELEGRAM_SECRET_TOKEN}" | jq .
    log "Strands webhook: ${WEBHOOK_URL_STRANDS}/webhook/telegram"
}

auth_kiro() {
    log "Authenticating kiro-cli (device flow)..."
    kubectl exec -it deployment/openab-kiro -n openab -- kiro-cli login --use-device-flow
    kubectl rollout restart deployment/openab-kiro -n openab
}

destroy() {
    log "Destroying K8s resources..."
    kubectl delete namespace openab --ignore-not-found

    log "Removing Telegram webhooks..."
    curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN_KIRO}/deleteWebhook" | jq .
    curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN_STRANDS}/deleteWebhook" | jq .
}

status() {
    log "Pod status:"
    kubectl get pods -n openab -o wide
    echo
    log "Services:"
    kubectl get svc -n openab
    echo
    log "Ingress:"
    kubectl get ingress -n openab
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-help}" in
    setup)
        setup_ecr
        build_and_push
        RUNTIME_ARN=$(create_agentcore_runtime)
        export RUNTIME_ARN
        create_k8s_secrets
        deploy_k8s
        register_webhooks
        log "Setup complete! Run './deploy.sh auth-kiro' to authenticate kiro-cli."
        ;;
    build)
        build_and_push
        ;;
    deploy)
        create_k8s_secrets
        deploy_k8s
        ;;
    webhook)
        register_webhooks
        ;;
    auth-kiro)
        auth_kiro
        ;;
    all)
        build_and_push
        create_k8s_secrets
        deploy_k8s
        register_webhooks
        log "Done! Run './deploy.sh auth-kiro' to authenticate kiro-cli."
        ;;
    status)
        status
        ;;
    destroy)
        destroy
        ;;
    help|*)
        echo "Usage: $0 {setup|build|deploy|webhook|auth-kiro|all|status|destroy}"
        echo
        echo "  setup      - First-time full setup (ECR + AgentCore + K8s + webhooks)"
        echo "  build      - Build and push Strands runtime to ECR"
        echo "  deploy     - Apply K8s manifests only"
        echo "  webhook    - Register Telegram webhooks"
        echo "  auth-kiro  - Authenticate kiro-cli in the running pod"
        echo "  all        - Build + deploy + webhook (no AgentCore creation)"
        echo "  status     - Show pod/service/ingress status"
        echo "  destroy    - Tear down everything"
        echo
        echo "Required env vars:"
        echo "  AWS_ACCOUNT_ID, AWS_REGION, AGENTCORE_ROLE_ARN"
        echo "  TELEGRAM_BOT_TOKEN_KIRO, TELEGRAM_BOT_TOKEN_STRANDS"
        echo "  TELEGRAM_ALLOWED_USER_ID, KIRO_API_KEY"
        echo "  WEBHOOK_URL_KIRO, WEBHOOK_URL_STRANDS"
        ;;
esac
