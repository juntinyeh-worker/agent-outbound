# OpenAB Dual-Agent Telegram Setup

Two OpenAB instances connected to Telegram — one running **Kiro CLI** locally, the other running a **Strands Agent** on **Amazon Bedrock AgentCore Runtime**.

## Architecture

```
┌──────────────────┐
│  Telegram Users  │
└───────┬──────────┘
        │ webhooks (HTTPS)
        ▼
┌───────────────────────────────────────────────────┐
│              Ingress / Load Balancer               │
│  oab-kiro.example.com    oab-strands.example.com  │
└──────┬────────────────────────────┬───────────────┘
       │                            │
       ▼                            ▼
┌──────────────┐          ┌─────────────────────┐
│ OAB (Kiro)   │          │ OAB (Strands)       │
│ ~500MB image │          │ ~50MB image         │
│              │          │                     │
│ [telegram]   │          │ [telegram]          │
│ [agent]      │          │ [agentcore]         │
│  └─kiro-cli  │          │  └─agentcore-bridge │
└──────────────┘          └──────────┬──────────┘
                                     │ WebSocket (SigV4)
                                     ▼
                          ┌──────────────────────┐
                          │ AgentCore microVM    │
                          │ └─ acp_wrapper.py    │
                          │    └─ Strands Agent  │
                          │       └─ Bedrock     │
                          │         (Claude/Nova)│
                          └──────────────────────┘
```

## Prerequisites

- AWS account with Bedrock model access enabled
- Kubernetes cluster (EKS recommended for IRSA)
- Docker with `buildx` (for ARM64 cross-compilation)
- `kubectl`, `aws` CLI, `curl`, `jq`
- Two Telegram bot tokens (from [@BotFather](https://t.me/BotFather))

## Directory Structure

```
openab-telegram-dual/
├── config-kiro.toml            # OAB config for Kiro instance
├── config-strands.toml         # OAB config for Strands instance
├── strands-runtime/
│   ├── Dockerfile              # ARM64 container for AgentCore
│   ├── acp_wrapper.py          # ACP JSON-RPC ↔ Strands bridge
│   ├── healthcheck.py          # Health endpoint for AgentCore
│   └── pyproject.toml          # Python dependencies
├── k8s/
│   ├── 00-namespace-secrets.yaml
│   ├── 01-configmap.yaml
│   ├── 02-pvc.yaml
│   ├── 03-deployment-kiro.yaml
│   ├── 04-deployment-strands.yaml
│   └── 05-ingress.yaml
└── scripts/
    └── deploy.sh               # One-script deployment
```

## Setup Steps

### 1. Create Telegram Bots

1. Open [@BotFather](https://t.me/BotFather) in Telegram
2. Create **two** bots: one for Kiro, one for Strands
3. Save both tokens
4. Get your Telegram user ID from [@userinfobot](https://t.me/userinfobot)

### 2. Set Environment Variables

```bash
export AWS_ACCOUNT_ID="123456789012"
export AWS_REGION="us-east-1"

# Telegram
export TELEGRAM_BOT_TOKEN_KIRO="123456:AAH..."
export TELEGRAM_BOT_TOKEN_STRANDS="789012:BBK..."
export TELEGRAM_ALLOWED_USER_ID="176096071"

# Agent keys
export KIRO_API_KEY="your-kiro-api-key"

# AgentCore IAM role (needs bedrock-agentcore:InvokeAgentRuntimeCommandShell + ECR pull)
export AGENTCORE_ROLE_ARN="arn:aws:iam::123456789012:role/AgentCoreExecutionRole"
export AGENTCORE_IAM_ROLE_ARN="arn:aws:iam::123456789012:role/OpenABStrandsPodRole"

# Public webhook URLs (your domain with TLS)
export WEBHOOK_URL_KIRO="https://oab-kiro.example.com"
export WEBHOOK_URL_STRANDS="https://oab-strands.example.com"
```

### 3. Create the AgentCore IAM Role

The execution role needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:*::foundation-model/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    }
  ]
}
```

The pod's IRSA role needs:

```json
{
  "Effect": "Allow",
  "Action": ["bedrock-agentcore:InvokeAgentRuntimeCommandShell"],
  "Resource": ["arn:aws:bedrock-agentcore:us-east-1:*:runtime/*"]
}
```

### 4. Deploy (First Time)

```bash
cd scripts
./deploy.sh setup
```

This will:
1. Create ECR repository
2. Build & push the Strands runtime image (ARM64)
3. Create the AgentCore runtime
4. Create K8s namespace, secrets, configmap, PVC
5. Deploy both OAB instances
6. Register Telegram webhooks

### 5. Authenticate Kiro CLI

```bash
./deploy.sh auth-kiro
```

Follow the device flow URL in your browser to complete OAuth. The pod will restart after auth.

### 6. Test

Message each bot in Telegram:
- `@YourKiroBot` → routes to Kiro CLI
- `@YourStrandsBot` → routes to Strands Agent on Bedrock

## Day-to-Day Operations

```bash
# Rebuild Strands image after code changes
./deploy.sh build

# Redeploy K8s manifests
./deploy.sh deploy

# Update webhooks (e.g., after domain change)
./deploy.sh webhook

# Check pod status
./deploy.sh status

# Tear down everything
./deploy.sh destroy
```

## Customizing the Strands Agent

Edit `strands-runtime/acp_wrapper.py` to:
- Change the Bedrock model (`BEDROCK_MODEL_ID` env var)
- Add tools to the agent
- Modify the system prompt
- Add conversation memory

Environment variables for the Strands agent:

| Variable | Default | Description |
|----------|---------|-------------|
| `BEDROCK_MODEL_ID` | `us.anthropic.claude-sonnet-4-20250514` | Bedrock model ID |
| `AWS_REGION` | `us-east-1` | AWS region for Bedrock calls |
| `SYSTEM_PROMPT` | Generic assistant | Agent system prompt |
| `AGENT_NAME` | `strands-bedrock-agent` | Agent name in ACP |
| `LOG_LEVEL` | `WARNING` | Python log level |

## Local Development (No K8s)

Test the Strands ACP wrapper locally:

```bash
cd strands-runtime
pip install strands-agents boto3

# Test with a manual JSON-RPC request
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | python3 acp_wrapper.py
echo '{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"test","messages":[{"role":"user","content":"Hello!"}]}}' | python3 acp_wrapper.py
```

Test with a local OAB binary (no AgentCore):

```bash
# In config.toml:
# [agent]
# command = "python3"
# args = ["strands-runtime/acp_wrapper.py"]

# [telegram]
# bot_token = "..."
# allow_all_users = true

# Then use cloudflared for a temp public URL:
cloudflared tunnel --url http://localhost:8080
```

## Troubleshooting

**Bot doesn't respond:**
- Check `./deploy.sh status` for pod health
- Verify webhooks: `curl https://api.telegram.org/bot<TOKEN>/getWebhookInfo`
- Check pod logs: `kubectl logs -n openab deployment/openab-kiro`

**AgentCore timeout:**
- First invocation has ~5-15s cold start
- Check runtime status: `aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id <ID> --region us-east-1`

**Kiro auth expired:**
- Re-run `./deploy.sh auth-kiro`

**Strands model errors:**
- Verify Bedrock model access is enabled in your account
- Check the model ID is correct for your region
- Verify IAM role has `bedrock:InvokeModel` permission
