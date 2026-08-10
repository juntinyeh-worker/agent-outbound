# OpenAB Telegram Integration — Unified Mode Setup

This guide walks you through setting up OpenAB with Telegram using Unified Mode, from bot creation to agent configuration.

## Overview

In Unified Mode, the OAB binary embeds the Telegram webhook server directly — no separate gateway process needed.

```
Telegram ──POST──▶ OAB (:8080/webhook/telegram) ──▶ Agent (stdio)
```

This is the recommended approach for new deployments (available since v0.9.0-beta.4).

## Prerequisites

- A Telegram account
- A running environment for OAB (Docker, Kubernetes, or bare metal)
- A public HTTPS URL for the webhook (or Cloudflare Tunnel for development)
- An API key for your chosen agent backend (e.g., Kiro API key)

## Step 1: Create a Telegram Bot

1. Open Telegram and search for [@BotFather](https://t.me/BotFather)
2. Send `/newbot`
3. Choose a display name (e.g., `My OpenAB Agent`)
4. Choose a username (e.g., `my_openab_bot`) — must end in `bot`
5. Copy the bot token (format: `123456789:ABCdefGHI-jklMNOpqrSTUvwxYZ`)

### Optional: Disable Privacy Mode (for groups)

If you want the bot to respond to @mentions in group chats:

1. Send `/setprivacy` to @BotFather
2. Select your bot
3. Choose `Disable`

This allows the bot to see all messages in groups (required for @mention gating).

## Step 2: Get Your Telegram User ID

To restrict access to your bot (recommended):

1. Message [@userinfobot](https://t.me/userinfobot) in Telegram
2. It replies with your user ID (a numeric string like `176096071`)
3. Save this for the configuration step

## Step 3: Configure OpenAB

Create a `config.toml` file:

### Minimal Configuration

```toml
[telegram]
bot_token = "${TELEGRAM_BOT_TOKEN}"
allow_all_users = true

[agent]
env = { KIRO_API_KEY = "${KIRO_API_KEY}" }
```

### Recommended Configuration (with access control)

```toml
[telegram]
bot_token = "${TELEGRAM_BOT_TOKEN}"
allowed_users = ["YOUR_USER_ID"]
rich_messages = true
streaming = true

[agent]
env = { KIRO_API_KEY = "${KIRO_API_KEY}" }

[pool]
max_sessions = 3
session_ttl_hours = 1

[reactions]
enabled = true
tool_display = "compact"
```

### Configuration Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `bot_token` | Yes | — | Bot API token from @BotFather |
| `secret_token` | No | — | Webhook signature validation |
| `allowed_users` | No | `[]` (deny all) | Telegram user IDs allowed to interact |
| `allow_all_users` | No | `false` | Set `true` to allow everyone |
| `rich_messages` | No | `true` | Enable headings, tables, rich formatting |
| `streaming` | No | follows `rich_messages` | Live-update replies as tokens arrive |
| `webhook_path` | No | `/webhook/telegram` | Webhook endpoint path |

### Access Control Behavior

- **No config** → `allow_all_users` defaults to `false` → bot denies all users
- **`allowed_users = ["12345678"]`** → only listed IDs can chat
- **`allow_all_users = true`** → open to everyone (opt-in)

## Step 4: Set Up the Agent

By default, OAB uses Kiro CLI as the agent backend. The `[agent]` section configures how it runs.

### Default (Kiro CLI)

```toml
[agent]
# command defaults to: kiro-cli acp --trust-all-tools
env = { KIRO_API_KEY = "${KIRO_API_KEY}" }
```

### Using a Different Agent

Override the command to use any ACP-compatible agent:

```toml
# Claude Code
[agent]
command = "claude-agent-acp"
env = { ANTHROPIC_API_KEY = "${ANTHROPIC_API_KEY}" }

# Gemini
[agent]
command = "gemini"
args = ["--acp"]
env = { GOOGLE_API_KEY = "${GOOGLE_API_KEY}" }

# Codex
[agent]
command = "codex-acp"
env = { OPENAI_API_KEY = "${OPENAI_API_KEY}" }

# Custom Strands Agent (local)
[agent]
command = "python3"
args = ["/app/acp_wrapper.py"]
env = { AWS_REGION = "us-east-1", BEDROCK_MODEL_ID = "us.anthropic.claude-sonnet-4-20250514" }
```

### Using AgentCore Runtime (remote microVM)

Instead of running the agent locally, delegate to Bedrock AgentCore:

```toml
[agentcore]
runtime_arn = "arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/my-agent"
shell_command = "kiro-cli acp --trust-all-tools"
```

When `[agentcore]` is set, OAB uses the lightweight `beta-agentcore` path — no CLI bundled in the container.

## Step 5: Set the Webhook

OAB listens on port 8080. Telegram needs a public HTTPS URL to send updates.

### For Development (Cloudflare Tunnel)

```bash
cloudflared tunnel --url http://localhost:8080
# Outputs: https://random-slug.trycloudflare.com
```

### Register the Webhook

```bash
export BOT_TOKEN="your-bot-token"
export WEBHOOK_URL="https://your-public-url"
export SECRET="your-webhook-secret"  # optional but recommended

curl "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook?url=${WEBHOOK_URL}/webhook/telegram&secret_token=${SECRET}"
```

### Verify the Webhook

```bash
curl "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo" | jq .
```

Expected output:
```json
{
  "ok": true,
  "result": {
    "url": "https://your-public-url/webhook/telegram",
    "has_custom_certificate": false,
    "pending_update_count": 0
  }
}
```

## Step 6: Start OAB

### Docker

```bash
docker run -d --name openab-telegram \
  -e TELEGRAM_BOT_TOKEN="your-bot-token" \
  -e TELEGRAM_ALLOW_ALL_USERS="true" \
  -e KIRO_API_KEY="your-kiro-api-key" \
  -p 8080:8080 \
  ghcr.io/openabdev/openab:latest
```

### Docker with Config File

```bash
docker run -d --name openab-telegram \
  -v ./config.toml:/etc/openab/config.toml:ro \
  -e TELEGRAM_BOT_TOKEN="your-bot-token" \
  -e KIRO_API_KEY="your-kiro-api-key" \
  -p 8080:8080 \
  ghcr.io/openabdev/openab:latest
```

### Binary (if installed locally)

```bash
export TELEGRAM_BOT_TOKEN="your-bot-token"
export KIRO_API_KEY="your-kiro-api-key"
openab --config config.toml
```

## Step 7: Authenticate the Agent (First Time — Kiro Only)

If using Kiro CLI, you need to authenticate once:

```bash
# Docker
docker exec -it openab-telegram kiro-cli login --use-device-flow

# Kubernetes
kubectl exec -it deployment/openab-kiro -- kiro-cli login --use-device-flow
```

Follow the URL in your browser to complete OAuth, then restart:

```bash
docker restart openab-telegram
# or
kubectl rollout restart deployment/openab-kiro
```

## Step 8: Test

Send a message to your bot in Telegram:

```
Hello! Can you help me write a Python function to calculate fibonacci numbers?
```

You should see:
1. 👀 reaction (queued)
2. 🤔 reaction (thinking)
3. 🔥 reaction (working)
4. The agent's reply appears (streamed live if streaming is enabled)
5. 👍 reaction (done)

### In Groups

Add the bot to a group, then @mention it:

```
@my_openab_bot explain what a VPC is
```

The bot creates a forum topic (in supergroups with topics enabled). Follow-up messages in the same topic don't need @mention.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Bot doesn't respond | Check webhook: `curl .../getWebhookInfo` |
| Bot doesn't respond in groups | Disable privacy mode via @BotFather |
| "not enough rights to create topic" | Give bot **Manage Topics** permission in group admin |
| Webhook returns 502 | Check OAB is running: `curl http://localhost:8080/health` |
| Auth expired (Kiro) | Re-run `kiro-cli login --use-device-flow` |

## Next Steps

- [Configure Rich Messages and streaming](https://github.com/openabdev/openab/blob/main/docs/telegram.md)
- [Set up multiple agents](https://github.com/openabdev/openab/blob/main/docs/multi-agent.md)
- [Deploy on Kubernetes](https://github.com/openabdev/openab/blob/main/docs/agentcore.md)
- [Add voice message support (STT)](https://github.com/openabdev/openab/blob/main/docs/stt.md)
