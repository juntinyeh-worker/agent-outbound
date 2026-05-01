#!/usr/bin/env bash
# quickstart.sh — Full automated deploy: Discord bots + EKS + OpenAB
#
# Usage:
#   cp .env.example .env   # fill in Discord creds + Kiro API key
#   ./quickstart.sh        # does everything
#
# Or run steps separately:
#   python setup-discord.py   # Step 1: create Discord bots
#   ./quickstart.sh --skip-discord  # Steps 2-5: EKS + Helm only
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKIP_DISCORD=false
for arg in "$@"; do
  [ "$arg" = "--skip-discord" ] && SKIP_DISCORD=true
done

# ── Load .env ──────────────────────────────────────────────
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env"
  exit 1
fi
set -a; source "$SCRIPT_DIR/.env"; set +a

# ── Step 1: Discord bot setup (AgentCore Browser) ─────────
if [ "$SKIP_DISCORD" = false ]; then
  echo "==> [1/6] Creating Discord bots via AgentCore Browser..."

  if [ -z "${DISCORD_EMAIL:-}" ] || [ -z "${DISCORD_PASSWORD:-}" ] || [ -z "${NOVA_ACT_API_KEY:-}" ]; then
    echo "ERROR: DISCORD_EMAIL, DISCORD_PASSWORD, and NOVA_ACT_API_KEY required for Discord setup."
    echo "Set them in .env, or run: ./quickstart.sh --skip-discord"
    exit 1
  fi

  # Install Python deps if needed
  if ! python3 -c "import nova_act" 2>/dev/null; then
    echo "    Installing Python dependencies..."
    pip install -r "$SCRIPT_DIR/requirements.txt" -q
  fi

  python3 "$SCRIPT_DIR/setup-discord.py"

  # Reload .env (setup-discord.py updated it with bot tokens)
  set -a; source "$SCRIPT_DIR/.env"; set +a
  echo "    ✓ Discord bots created and tokens saved to .env"
else
  echo "==> [1/6] Skipping Discord setup (--skip-discord)"
fi

# ── Validate required vars ─────────────────────────────────
: "${AWS_REGION:?Set AWS_REGION in .env}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME in .env}"
: "${DISCORD_CHANNEL_ID:?Set DISCORD_CHANNEL_ID in .env (or run without --skip-discord)}"
: "${KIRO_API_KEY:?Set KIRO_API_KEY in .env}"
: "${BOT_TOKEN_PM:?Missing BOT_TOKEN_PM — run setup-discord.py first}"
: "${BOT_TOKEN_ARCHITECT:?Missing BOT_TOKEN_ARCHITECT}"
: "${BOT_TOKEN_DEV:?Missing BOT_TOKEN_DEV}"
: "${BOT_TOKEN_QA:?Missing BOT_TOKEN_QA}"
: "${BOT_TOKEN_CLOUDOPS:?Missing BOT_TOKEN_CLOUDOPS}"
: "${BOT_TOKEN_AUDITOR:?Missing BOT_TOKEN_AUDITOR}"

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

# ── Step 2: EKS Cluster ───────────────────────────────────
echo "==> [2/6] EKS cluster"
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

# ── Step 3: EBS CSI Driver ─────────────────────────────────
echo "==> [3/6] EBS CSI driver"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --approve 2>/dev/null || true
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa --namespace kube-system \
  --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
  --role-name "AmazonEKS_EBS_CSI_DriverRole_${CLUSTER_NAME}" \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve --override-existing-serviceaccounts 2>/dev/null || true
eksctl create addon --name aws-ebs-csi-driver \
  --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
  --service-account-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole_${CLUSTER_NAME}" \
  --force 2>/dev/null || true

# ── Step 4: Namespace + Secrets ────────────────────────────
echo "==> [4/6] Namespace + secrets"
kubectl create namespace "$NS" 2>/dev/null || true
kubectl create secret generic openab-shared-secrets \
  --namespace "$NS" \
  --from-literal=kiro-api-key="$KIRO_API_KEY" \
  --from-literal=gh-token="${GH_TOKEN:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Step 5: Helm deploy ───────────────────────────────────
echo "==> [5/6] Helm deploy (6 agents)"
helm repo add openab https://openabdev.github.io/openab 2>/dev/null || true
helm repo update openab

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

# ── Step 6: Wait ──────────────────────────────────────────
echo "==> [6/6] Waiting for pods..."
kubectl wait --for=condition=ready pod \
  -l "app.kubernetes.io/instance=${RELEASE}" \
  -n "$NS" --timeout=300s
kubectl get pods -n "$NS"

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
