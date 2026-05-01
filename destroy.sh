#!/usr/bin/env bash
# destroy.sh — Tear down the OpenAB team cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "ERROR: .env not found."; exit 1
fi
set -a; source "$SCRIPT_DIR/.env"; set +a

: "${AWS_REGION:?}"
: "${CLUSTER_NAME:?}"

NS="openab"
RELEASE="openab-team"

echo "⚠️  This will destroy:"
echo "    - Helm release: $RELEASE"
echo "    - Namespace: $NS (all PVCs and data)"
echo "    - EKS cluster: $CLUSTER_NAME"
echo ""
read -p "Type 'yes' to confirm: " confirm
[ "$confirm" = "yes" ] || { echo "Aborted."; exit 0; }

echo "==> Uninstalling Helm release..."
helm uninstall "$RELEASE" -n "$NS" 2>/dev/null || true

echo "==> Deleting namespace..."
kubectl delete namespace "$NS" --timeout=120s 2>/dev/null || true

echo "==> Deleting EKS cluster (takes ~10 min)..."
eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION"

echo ""
echo "✅ Cluster $CLUSTER_NAME destroyed."
