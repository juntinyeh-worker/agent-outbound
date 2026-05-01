#!/usr/bin/env bash
# quickstart.sh — Deploy a role-based OpenAB software team on EKS
#
# Usage:
#   cp .env.example .env
#   vim .env          # fill in your values
#   ./quickstart.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load .env ──────────────────────────────────────────────
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env"
  exit 1
fi
set -a; source "$SCRIPT_DIR/.env"; set +a

# ── Validate required vars ─────────────────────────────────
: "${AWS_REGION:?Set AWS_REGION in .env}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME in .env}"
: "${DISCORD_CHANNEL_ID:?Set DISCORD_CHANNEL_ID in .env}"
: "${KIRO_API_KEY:?Set KIRO_API_KEY in .env}"
: "${BOT_TOKEN_PM:?Set BOT_TOKEN_PM in .env}"
: "${BOT_TOKEN_ARCHITECT:?Set BOT_TOKEN_ARCHITECT in .env}"
: "${BOT_TOKEN_DEV:?Set BOT_TOKEN_DEV in .env}"
: "${BOT_TOKEN_QA:?Set BOT_TOKEN_QA in .env}"
: "${BOT_TOKEN_CLOUDOPS:?Set BOT_TOKEN_CLOUDOPS in .env}"
: "${BOT_TOKEN_AUDITOR:?Set BOT_TOKEN_AUDITOR in .env}"

NODE_TYPE="${NODE_INSTANCE_TYPE:-t3.large}"
NODE_COUNT="${NODE_COUNT:-2}"
NS="openab"
RELEASE="openab-team"

# ── Preflight ──────────────────────────────────────────────
echo "==> Preflight checks"
for cmd in aws eksctl kubectl helm; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done
echo "    ✓ All tools found"
echo "    Region:  $AWS_REGION"
echo "    Cluster: $CLUSTER_NAME"
echo "    Nodes:   ${NODE_COUNT}× ${NODE_TYPE}"
echo ""

# ── Step 1: EKS Cluster ───────────────────────────────────
echo "==> [1/6] EKS cluster"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
  echo "    Cluster exists, skipping creation."
else
  echo "    Creating cluster (takes ~15 min)..."
  eksctl create cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --node-type "$NODE_TYPE" \
    --nodes "$NODE_COUNT" \
    --managed
fi
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
echo "    ✓ kubeconfig updated"

# ── Step 2: EBS CSI Driver ─────────────────────────────────
echo "==> [2/6] EBS CSI driver (for PVC persistence)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --approve 2>/dev/null || true

eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --role-name "AmazonEKS_EBS_CSI_DriverRole_${CLUSTER_NAME}" \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve --override-existing-serviceaccounts 2>/dev/null || true

eksctl create addon --name aws-ebs-csi-driver \
  --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
  --service-account-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole_${CLUSTER_NAME}" \
  --force 2>/dev/null || true
echo "    ✓ EBS CSI driver ready"

# ── Step 3: Namespace + Secrets ────────────────────────────
echo "==> [3/6] Namespace + secrets"
kubectl create namespace "$NS" 2>/dev/null || true

kubectl create secret generic openab-shared-secrets \
  --namespace "$NS" \
  --from-literal=kiro-api-key="$KIRO_API_KEY" \
  --from-literal=gh-token="${GH_TOKEN:-}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "    ✓ Secrets created"

# ── Step 4: Helm deploy ───────────────────────────────────
echo "==> [4/6] Helm deploy (6 agents)"
helm repo add openab https://openabdev.github.io/openab 2>/dev/null || true
helm repo update openab

# Resolve channel ID in values file
sed "s/YOUR_CHANNEL_ID/${DISCORD_CHANNEL_ID}/g" \
  "$SCRIPT_DIR/values-team.yaml" > /tmp/_values-team.yaml

helm upgrade --install "$RELEASE" openab/openab \
  --namespace "$NS" \
  -f /tmp/_values-team.yaml \
  --set agents.pm.discord.botToken="$BOT_TOKEN_PM" \
  --set agents.architect.discord.botToken="$BOT_TOKEN_ARCHITECT" \
  --set agents.dev.discord.botToken="$BOT_TOKEN_DEV" \
  --set agents.qa.discord.botToken="$BOT_TOKEN_QA" \
  --set agents.cloudops.discord.botToken="$BOT_TOKEN_CLOUDOPS" \
  --set agents.auditor.discord.botToken="$BOT_TOKEN_AUDITOR"

rm -f /tmp/_values-team.yaml
echo "    ✓ Helm release deployed"

# ── Step 5: Wait for pods ─────────────────────────────────
echo "==> [5/6] Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod \
  -l "app.kubernetes.io/instance=${RELEASE}" \
  -n "$NS" --timeout=300s
echo "    ✓ All pods ready"
kubectl get pods -n "$NS"

# ── Step 6: Auth instructions ─────────────────────────────
echo ""
echo "==> [6/6] Agent authentication (manual step)"
echo ""
echo "    Each agent needs a one-time Kiro CLI login."
echo "    Run each command below, follow the device-code flow in your browser:"
echo ""
for role in pm architect dev qa cloudops auditor; do
  echo "    kubectl exec -it deployment/${RELEASE}-${role} -n $NS -- kiro-cli login --use-device-flow"
done
echo ""
echo "    After ALL agents are authenticated, restart them:"
echo ""
echo "    kubectl rollout restart deployment -n $NS -l app.kubernetes.io/instance=$RELEASE"

# ── Done ──────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo " ✅  OpenAB Software Team deployed — 6 role-based agents"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo " Roles:   PM · Architect · Dev · QA · CloudOps · Auditor"
echo " Channel: $DISCORD_CHANNEL_ID"
echo " Cluster: $CLUSTER_NAME ($AWS_REGION)"
echo ""
echo " Pipeline: PM → Architect+Dev → QA → CloudOps → Review → Audit"
echo ""
echo " Verify:   kubectl get pods -n $NS"
echo " Logs:     kubectl logs -f deployment/${RELEASE}-dev -n $NS"
echo " Destroy:  ./destroy.sh"
echo ""
echo " → Go to Discord and @mention each bot to test!"
