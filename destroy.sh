#!/usr/bin/env bash
# destroy.sh - Tear down one OpenAB + Kiro Telegram agent (by stack name).
#
# Options:
#   -s, --stack-name <name>            Stack to delete (default: openab-telegram-kiro)
#   -t, --telegram-token <value|file>  Token to deregister the webhook (optional)
#   -r, --region <region>              AWS region (default: us-east-1)
#       --delete-secrets               Also delete this stack's 3 Secrets Manager secrets
#   -h, --help                         Show this help
#
# Secrets are namespaced under the stack name (matching deploy.sh), so this only
# ever touches the named agent -- other agents in the account are untouched.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK="${STACK_NAME:-openab-telegram-kiro}"
TG_IN=""
DELETE_SECRETS=false

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--stack-name)     STACK="${2:-}"; shift 2;;
    -t|--telegram-token) TG_IN="${2:-}"; shift 2;;
    -r|--region)         REGION="${2:-}"; shift 2;;
    --delete-secrets)    DELETE_SECRETS=true; shift;;
    -h|--help)           usage 0;;
    *) echo "ERROR: unknown arg: $1" >&2; usage 1;;
  esac
done

SECRET_PREFIX="${SECRET_PREFIX:-$STACK}"
TELEGRAM_SECRET_NAME="${TELEGRAM_SECRET_NAME:-$SECRET_PREFIX/telegram-bot-token}"
KIRO_SECRET_NAME="${KIRO_SECRET_NAME:-$SECRET_PREFIX/kiro-api-key}"
TG_WEBHOOK_SECRET_NAME="${TG_WEBHOOK_SECRET_NAME:-$SECRET_PREFIX/telegram-webhook-secret}"

# Best-effort: remove the Telegram webhook so updates stop hitting the old URL.
[ -z "$TG_IN" ] && TG_IN="${TELEGRAM_TOKEN:-${TELEGRAM_TOKEN_FILE:-}}"
if [ -n "$TG_IN" ]; then
  if [ -f "$TG_IN" ]; then TT=$(tr -d '[:space:]' < "$TG_IN"); else TT=$(printf '%s' "$TG_IN" | tr -d '[:space:]'); fi
  echo "==> Deleting Telegram webhook"
  curl -sS "https://api.telegram.org/bot${TT}/deleteWebhook" >/dev/null || true
fi

echo "==> Deleting stack $STACK"
aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"
aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION"
echo "    stack deleted"

if [ "$DELETE_SECRETS" = "true" ]; then
  echo "==> Deleting secrets (force, no recovery window)"
  for s in "$TELEGRAM_SECRET_NAME" "$KIRO_SECRET_NAME" "$TG_WEBHOOK_SECRET_NAME"; do
    aws secretsmanager delete-secret --secret-id "$s" --force-delete-without-recovery --region "$REGION" >/dev/null 2>&1 \
      && echo "    deleted secret: $s" || echo "    (skip) secret not found: $s"
  done
else
  echo "Secrets kept. To remove them: re-run with --delete-secrets"
fi
echo "Done."
