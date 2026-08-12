# Strands Worker Agent — OpenAB + AgentCore Runtime

A deployable Strands Agent package that runs on AWS Bedrock AgentCore Runtime and
integrates with **Discord** and **Telegram** through [OpenAB](https://github.com/openabdev/openab).

## Why

- **No concurrent session limit** — unlike Kiro's 4-session cap, this scales horizontally
- **Pay-per-use** — Bedrock inference + AgentCore compute, no per-seat cost
- **Full coding capabilities** — shell execution, git operations, file manipulation, persistent memory
- **Multi-platform** — same agent reachable from Discord, Telegram, Slack (via OpenAB)

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                                                                                  │
│  Discord / Telegram / Slack                                                      │
│         │                                                                        │
│         ▼                                                                        │
│  ┌─────────────┐  ACP stdio  ┌───────────────────┐  WebSocket  ┌─────────────┐  │
│  │   OpenAB    │────────────▶│ agentcore-bridge  │────────────▶│  AgentCore  │  │
│  │ (thin ACP   │             │ (built into OAB)  │  (SigV4)    │   Runtime   │  │
│  │  broker)    │             └───────────────────┘             │             │  │
│  └─────────────┘                                               │ ┌─────────┐ │  │
│                                                                │ │ Strands │ │  │
│  Image: ghcr.io/openabdev/openab:beta-agentcore (~50MB)        │ │  Agent  │ │  │
│  Runs on: ECS Fargate / K8s / local Docker                     │ │         │ │  │
│                                                                │ │ Tools:  │ │  │
│                                                                │ │ • shell │ │  │
│                                                                │ │ • git   │ │  │
│                                                                │ │ • files │ │  │
│                                                                │ │ • memory│ │  │
│                                                                │ └─────────┘ │  │
│                                                                │             │  │
│                                                                │ LLM:        │  │
│                                                                │ Bedrock     │  │
│                                                                │ (Claude 4)  │  │
│                                                                └─────────────┘  │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

## What's Included

```
├── main.py                 # Agent entry point (BedrockAgentCoreApp + conversation history)
├── conversation.py         # Multi-turn history management (persistent, per-session)
├── tools/
│   ├── __init__.py         # Tool exports
│   ├── think_tool.py       # think — plan before acting
│   ├── search_tools.py     # grep_search, find_files — navigate codebases
│   ├── shell_tool.py       # shell_execute — run any command
│   ├── git_tool.py         # git_operation — clone/commit/push/pull/branch
│   ├── file_ops_tool.py    # read_file, write_file, list_directory
│   └── memory_tool.py      # memory_store, memory_recall — persistent KV store
├── prompts/
│   └── __init__.py         # System prompt for the worker agent
├── Dockerfile              # Container for AgentCore Runtime
├── requirements.txt        # Python dependencies
├── deploy.sh               # One-command deployment to AgentCore
├── destroy.sh              # Tear down resources
└── template.yaml           # CloudFormation for full OAB+AgentCore stack
```

## Quick Start

### Step 1: Deploy the Strands Agent to AgentCore Runtime

```bash
cd strands-agent/

# Deploy (builds container, creates ECR, IAM, AgentCore Runtime)
./deploy.sh

# Output:
#   Runtime ARN: arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/abc123
```

### Step 2: Connect OpenAB

#### Option A: Discord (simplest — no webhook/ALB needed)

Create a `config.toml`:

```toml
[discord]
bot_token = "${DISCORD_BOT_TOKEN}"
allowed_channels = ["YOUR_CHANNEL_ID"]

[agentcore]
runtime_arn = "arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/abc123"
```

Run OpenAB:

```bash
docker run -d \
  -e DISCORD_BOT_TOKEN="your-token" \
  -v ./config.toml:/etc/openab/config.toml \
  ghcr.io/openabdev/openab:beta-agentcore
```

#### Option B: Telegram (requires webhook + TLS)

Use the CloudFormation template for full infra:

```bash
aws cloudformation deploy \
  --stack-name openab-strands \
  --template-file template.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    AgentCoreRuntimeArn="arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/abc123" \
    TelegramBotTokenArn="arn:aws:secretsmanager:..." \
    TelegramWebhookSecretArn="arn:aws:secretsmanager:..." \
    AllowedTelegramUsers="YOUR_TELEGRAM_USER_ID"
```

Then register the webhook:

```bash
curl "https://api.telegram.org/bot${TG_TOKEN}/setWebhook" \
  --data-urlencode "url=https://${CF_DOMAIN}/webhook/telegram" \
  --data-urlencode "secret_token=${WEBHOOK_SECRET}"
```

#### Option C: Kubernetes

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openab-strands
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: openab
          image: ghcr.io/openabdev/openab:beta-agentcore
          env:
            - name: DISCORD_BOT_TOKEN
              valueFrom:
                secretKeyRef:
                  name: openab-secrets
                  key: discord-bot-token
          volumeMounts:
            - name: config
              mountPath: /etc/openab
      volumes:
        - name: config
          configMap:
            name: openab-config
```

## Agent Capabilities

| Tool | Description |
|------|-------------|
| `think` | **Plan before acting** — step-by-step reasoning for complex tasks |
| `grep_search` | Search for patterns in code (regex, file glob filter, case control) |
| `find_files` | Discover files by name pattern, extension, or type |
| `shell_execute` | Run any shell command with timeout and output capture |
| `git_operation` | Full git workflow: clone, status, add, commit, push, pull, branch, diff, log, merge, stash |
| `read_file` | Read files (full or line range) |
| `write_file` | Create/overwrite/append/insert into files |
| `list_directory` | Browse directory trees with depth control |
| `memory_store` | Persist key-value data across conversations |
| `memory_recall` | Search memories by key, category, or text query |

### Multi-Turn Conversation History

The agent maintains conversation context across messages in the same session/thread.
Each Discord thread or Telegram chat maps to a persistent session — the agent remembers
what was discussed and can build on previous work without repeating context.

- **Context window**: up to 50 turns / 100K characters (auto-trims oldest)
- **Storage**: JSON files in the workspace (survives microVM restarts via AgentCore persistence)
- **Per-session**: separate history per thread/chat — agents don't cross-contaminate

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BEDROCK_MODEL_ID` | `us.anthropic.claude-sonnet-4-20250514-v1:0` | Bedrock model to use |
| `AWS_REGION` | `us-east-1` | AWS region |
| `AGENT_WORKSPACE` | `/home/agent/workspace` | Working directory for the agent |
| `AGENT_MEMORY_FILE` | `/home/agent/workspace/.agent_memory.json` | Persistent memory location |
| `GH_TOKEN` | — | GitHub token for git operations |

### Customizing the Model

The agent defaults to Claude Sonnet 4 on Bedrock. You can use any Bedrock-available model:

```bash
# Use Nova Pro
export BEDROCK_MODEL_ID="us.amazon.nova-pro-v1:0"

# Use Haiku for faster/cheaper responses
export BEDROCK_MODEL_ID="us.anthropic.claude-3-5-haiku-20241022-v1:0"
```

## Cost Estimate

| Component | ~Monthly Cost |
|-----------|--------------|
| AgentCore Runtime (pay-per-invoke) | ~$5-50 depending on usage |
| Bedrock inference (Claude Sonnet) | ~$3/MTok input, $15/MTok output |
| ECS Fargate for OpenAB (256 CPU, 512MB) | ~$9 |
| ALB (Telegram only) | ~$16 |
| CloudFront (Telegram only) | pennies |

**Discord-only deployments** skip ALB+CloudFront entirely (~$9/mo for OAB + usage-based agent costs).

## Multi-Agent Setup

Run multiple Strands agents for different tasks. Each gets its own AgentCore Runtime:

```toml
# config.toml — multi-agent example with OpenAB
[discord]
bot_token = "${DISCORD_BOT_TOKEN}"
allowed_channels = ["123456789"]

[agentcore]
runtime_arn = "arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/coding-agent"
```

Deploy a second agent on a different bot:

```bash
RUNTIME_NAME=strands-review-agent ./deploy.sh
```

## Tear Down

```bash
# Delete AgentCore runtime only
./destroy.sh

# Delete everything (ECR, IAM role too)
DELETE_ALL=true ./destroy.sh

# Delete the OpenAB stack
aws cloudformation delete-stack --stack-name openab-strands
```

## Extending

Add new tools by creating a Python file in `tools/`:

```python
# tools/my_custom_tool.py
from strands import tool

@tool
def my_tool(param: str) -> str:
    """Description of what the tool does."""
    # implementation
    return "result"
```

Then import it in `tools/__init__.py` and add to the agent's tool list in `main.py`.

## Comparison with Kiro-based Setup

| Aspect | Kiro (existing) | Strands Agent (this) |
|--------|----------------|---------------------|
| Concurrent sessions | Limited to 4 | Unlimited (scales horizontally) |
| Model | Kiro's backend | Any Bedrock model (Claude, Nova, etc.) |
| Tools | Kiro built-in | Custom Python tools |
| Memory | Kiro sessions | Persistent file-based + extensible |
| Cost model | Per-seat/API key | Pay-per-inference |
| Customizability | Limited | Full control |
| Code quality | Excellent (Kiro's strength) | Good (depends on model + prompt) |
| IDE features | Full IDE integration | None (agent-only) |
