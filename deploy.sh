#!/usr/bin/env bash
# deploy.sh - Deploy the OpenAB + Kiro Telegram bot.
#
# You must provide TWO inputs: your Kiro API key and your Telegram bot token.
# Each may be given as a literal value OR as a path to a file containing it.
# (A file path is preferred -- literal values on the command line can be visible
#  via `ps` and shell history.)
#
# Ways to pass them (checked in this order):
#   1. Flags:        -k/--kiro-key   -t/--telegram-token
#   2. Positional:   deploy.sh <kiro-key|file> <telegram-token|file> [allowed-users]
#   3. Env vars:     KIRO_KEY / TELEGRAM_TOKEN (literals)
#                    KIRO_KEY_FILE / TELEGRAM_TOKEN_FILE (paths)
#
# Options:
#   -k, --kiro-key <value|file>        Kiro API key
#   -t, --telegram-token <value|file>  Telegram bot token
#   -u, --allowed-users <ids>          Comma-separated Telegram user IDs (empty = open to all)
#   -s, --stack-name <name>            Stack name (default: openab-telegram-kiro)
#   -r, --region <region>              AWS region (default: us-east-1)
#   -n, --dry-run                      Print the resolved config and exit (no AWS calls)
#   -h, --help                         Show this help
#
# MULTIPLE AGENTS IN ONE ACCOUNT: give each a distinct --stack-name. Every AWS
# resource AND all three Secrets Manager secrets are namespaced under the stack
# name (SECRET_PREFIX defaults to the stack name), so separate agents never
# collide. Each agent still needs its own Telegram bot/token.
#
# Examples:
#   ./deploy.sh -k ~/.kiro/kiro-api-key -t ~/telegram-token -u 213695386
#   ./deploy.sh -s team-bot-2 -k ~/k2.key -t ~/t2.txt -u 999   # a second, isolated agent
#   ./deploy.sh -s team-bot-2 -k ~/k2.key -t ~/t2.txt --dry-run
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK="${STACK_NAME:-openab-telegram-kiro}"
ALLOWED_USERS="${ALLOWED_USERS:-}"
DRY_RUN=false
KIRO_IN=""
TG_IN=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
  exit "${1:-0}"
}

# --- parse args ---
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    -k|--kiro-key)        KIRO_IN="${2:-}"; shift 2;;
    -t|--telegram-token)  TG_IN="${2:-}"; shift 2;;
    -u|--allowed-users)   ALLOWED_USERS="${2:-}"; shift 2;;
    -s|--stack-name)      STACK="${2:-}"; shift 2;;
    -r|--region)          REGION="${2:-}"; shift 2;;
    -n|--dry-run)         DRY_RUN=true; shift;;
    -h|--help)            usage 0;;
    --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done;;
    -*) echo "ERROR: unknown option: $1" >&2; usage 1;;
    *)  POSITIONAL+=("$1"); shift;;
  esac
done

# Positional fallback: <kiro-key> <telegram-token> [allowed-users]
[ -z "$KIRO_IN" ] && [ "${#POSITIONAL[@]}" -ge 1 ] && KIRO_IN="${POSITIONAL[0]}"
[ -z "$TG_IN" ]   && [ "${#POSITIONAL[@]}" -ge 2 ] && TG_IN="${POSITIONAL[1]}"
[ -z "$ALLOWED_USERS" ] && [ "${#POSITIONAL[@]}" -ge 3 ] && ALLOWED_USERS="${POSITIONAL[2]}"

# Env fallbacks
[ -z "$KIRO_IN" ] && KIRO_IN="${KIRO_KEY:-${KIRO_KEY_FILE:-}}"
[ -z "$TG_IN" ]   && TG_IN="${TELEGRAM_TOKEN:-${TELEGRAM_TOKEN_FILE:-}}"

# Secret names are namespaced under the stack (or SECRET_PREFIX) so multiple
# agents can coexist in one account. Override any individually if you must.
SECRET_PREFIX="${SECRET_PREFIX:-$STACK}"
TELEGRAM_SECRET_NAME="${TELEGRAM_SECRET_NAME:-$SECRET_PREFIX/telegram-bot-token}"
KIRO_SECRET_NAME="${KIRO_SECRET_NAME:-$SECRET_PREFIX/kiro-api-key}"
TG_WEBHOOK_SECRET_NAME="${TG_WEBHOOK_SECRET_NAME:-$SECRET_PREFIX/telegram-webhook-secret}"

# Resolve an input that may be a file path or a literal value; trims whitespace.
resolve_secret() {
  local label="$1" in="$2"
  if [ -z "$in" ]; then echo "ERROR: $label not provided (use -k/-t, positional, or env)" >&2; return 1; fi
  if [ -f "$in" ]; then
    [ -s "$in" ] || { echo "ERROR: $label file is empty: $in" >&2; return 1; }
    tr -d '[:space:]' < "$in"
  else
    echo "WARN: $label passed as a literal value (prefer a file path; literals show up in 'ps'/history)" >&2
    printf '%s' "$in" | tr -d '[:space:]'
  fi
}

for c in aws jq openssl; do command -v "$c" >/dev/null || { echo "ERROR: $c not found"; exit 1; }; done
KK=$(resolve_secret "Kiro API key" "$KIRO_IN")     || usage 1
TT=$(resolve_secret "Telegram bot token" "$TG_IN") || usage 1
[ -n "$KK" ] || { echo "ERROR: Kiro API key resolved empty"; exit 1; }
[ -n "$TT" ] || { echo "ERROR: Telegram bot token resolved empty"; exit 1; }
echo "$TT" | grep -qE '^[0-9]{6,}:[A-Za-z0-9_-]{30,}$' || echo "WARN: Telegram token does not match expected 'id:secret' format" >&2

ACCESS_DESC="OPEN (all users)"; [ -n "$ALLOWED_USERS" ] && ACCESS_DESC="RESTRICTED to: $ALLOWED_USERS"
cat <<CFG
==> Resolved configuration
    Region:            $REGION
    Stack:             $STACK
    Secret prefix:     $SECRET_PREFIX
      telegram token:  $TELEGRAM_SECRET_NAME
      kiro api key:    $KIRO_SECRET_NAME
      webhook secret:  $TG_WEBHOOK_SECRET_NAME
    Access:            $ACCESS_DESC
CFG

if [ "$DRY_RUN" = "true" ]; then
  echo "    (dry-run: no AWS calls made)"
  exit 0
fi

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "    Account:           $ACCOUNT"

upsert_secret() {
  local name="$1" value="$2"
  if aws secretsmanager describe-secret --secret-id "$name" --region "$REGION" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --secret-id "$name" --secret-string "$value" --region "$REGION" >/dev/null
    echo "    updated secret: $name" >&2
  else
    aws secretsmanager create-secret --name "$name" --secret-string "$value" --region "$REGION" >/dev/null
    echo "    created secret: $name" >&2
  fi
  # ONLY the ARN goes to stdout (captured by the caller).
  aws secretsmanager describe-secret --secret-id "$name" --region "$REGION" --query ARN --output text
}

echo "==> [1/4] Secrets Manager"
TG_ARN=$(upsert_secret "$TELEGRAM_SECRET_NAME" "$TT")
KIRO_ARN=$(upsert_secret "$KIRO_SECRET_NAME" "$KK")

# Webhook secret token: generate once (64 hex chars), reuse on later deploys so the
# registered webhook and the running container always agree.
if aws secretsmanager describe-secret --secret-id "$TG_WEBHOOK_SECRET_NAME" --region "$REGION" >/dev/null 2>&1; then
  WS=$(aws secretsmanager get-secret-value --secret-id "$TG_WEBHOOK_SECRET_NAME" --region "$REGION" --query SecretString --output text)
  WS_ARN=$(aws secretsmanager describe-secret --secret-id "$TG_WEBHOOK_SECRET_NAME" --region "$REGION" --query ARN --output text)
  echo "    reusing webhook secret: $TG_WEBHOOK_SECRET_NAME"
else
  WS=$(openssl rand -hex 32)
  WS_ARN=$(aws secretsmanager create-secret --name "$TG_WEBHOOK_SECRET_NAME" --secret-string "$WS" --region "$REGION" --query ARN --output text)
  echo "    created webhook secret: $TG_WEBHOOK_SECRET_NAME"
fi

echo "==> [2/4] Deploy CloudFormation stack (this takes a few minutes; CloudFront ~5-10 min)"
set +e
DEPLOY_OUT=$(aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK" \
  --template-file "$SCRIPT_DIR/template.yaml" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    TelegramSecretArn="$TG_ARN" \
    KiroSecretArn="$KIRO_ARN" \
    TelegramSecretTokenArn="$WS_ARN" \
    AllowedTelegramUsers="$ALLOWED_USERS" 2>&1)
DEPLOY_RC=$?
set -e
echo "$DEPLOY_OUT"
# `aws cloudformation deploy` exits non-zero when there is nothing to change;
# treat that as success so re-runs still refresh the webhook below.
if [ "$DEPLOY_RC" -ne 0 ] && ! echo "$DEPLOY_OUT" | grep -qi "No changes to deploy"; then
  echo "ERROR: stack deploy failed (rc=$DEPLOY_RC)" >&2
  exit "$DEPLOY_RC"
fi

echo "==> [3/4] Stack outputs"
OUTPUTS=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs' --output json)
WEBHOOK_URL=$(echo "$OUTPUTS" | jq -r '.[]|select(.OutputKey=="WebhookUrl").OutputValue')
CF_DOMAIN=$(echo "$OUTPUTS"  | jq -r '.[]|select(.OutputKey=="CloudFrontDomain").OutputValue')
ACCESS=$(echo "$OUTPUTS"     | jq -r '.[]|select(.OutputKey=="AccessMode").OutputValue')
echo "    CloudFront: $CF_DOMAIN"
echo "    Webhook:    $WEBHOOK_URL"
echo "    Access:     $ACCESS"

echo "==> [4/4] Register Telegram webhook (with secret_token)"
RESP=$(curl -sS "https://api.telegram.org/bot${TT}/setWebhook" \
  --data-urlencode "url=${WEBHOOK_URL}" \
  --data-urlencode "secret_token=${WS}" \
  --data-urlencode "allowed_updates=[\"message\",\"edited_message\"]")
echo "    setWebhook: $(echo "$RESP" | jq -c '{ok,description}')"
echo "    getWebhookInfo:"
curl -sS "https://api.telegram.org/bot${TT}/getWebhookInfo" | jq '{url:.result.url, pending:.result.pending_update_count, last_error:.result.last_error_message}'

echo ""
echo "Done. Message your bot on Telegram."
