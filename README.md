# OpenAB Telegram Sandbox

Deployment scripts and knowledge docs for running [OpenAB](https://github.com/openabdev/openab) with Telegram on AWS.

## Contents

```
├── docs/
│   ├── openab-knowledge-base.md           ← Full research: OpenAB, Telegram, AgentCore, Strands
│   └── openab-telegram-unified-setup.md   ← Step-by-step Telegram setup guide
├── deployment/
│   ├── ecs-sandbox/                       ← ECS Fargate deployment (configurable regions)
│   │   ├── env.conf                       ← Configuration (regions, prefix, tokens)
│   │   ├── cfn-infra.yaml                 ← CloudFormation template
│   │   └── deploy.sh                      ← One-command deployment script
│   └── telegram-dual/                     ← Dual-agent setup (Kiro + Strands)
│       ├── README.md                      ← Architecture and setup guide
│       ├── config-kiro.toml               ← OAB config for Kiro agent
│       ├── config-strands.toml            ← OAB config for Strands + AgentCore
│       ├── strands-runtime/               ← Custom Strands agent for AgentCore
│       │   ├── acp_wrapper.py             ← ACP JSON-RPC ↔ Strands bridge
│       │   ├── healthcheck.py             ← Health endpoint
│       │   ├── pyproject.toml             ← Python dependencies
│       │   └── Dockerfile                 ← ARM64 container for AgentCore
│       ├── k8s/                           ← Kubernetes manifests
│       └── scripts/
│           └── deploy.sh                  ← K8s deployment script
```

## Quick Start — ECS Sandbox

```bash
cd deployment/ecs-sandbox

# 1. Edit configuration
cp env.conf .env
vim .env  # Set regions, tokens, keys

# 2. Deploy everything
./deploy.sh all
```

### Configurable Regions

```bash
# env.conf
ECS_REGION="us-west-2"       # Where ECS cluster runs
SANDBOX_REGION="us-east-1"   # Where tasks have sandbox-* admin access
RESOURCE_PREFIX="sandbox"    # All resources prefixed with this
```

The ECS task role gets:
- ECR push/pull in any region for `sandbox-*` repos
- Full admin on `sandbox-*` resources in SANDBOX_REGION (S3, DynamoDB, Lambda, API GW, CFN, etc.)
- Bedrock model invocation (any region)
- AgentCore access

## Architectures

### Single Agent (ECS)

```
Telegram → API Gateway → ECS Fargate → OAB → kiro-cli acp
```

### Dual Agent (K8s)

```
Telegram Bot A → OAB Instance 1 → Kiro CLI (local)
Telegram Bot B → OAB Instance 2 → AgentCore → Strands Agent → Bedrock
```

## Docs

- [Knowledge Base](docs/openab-knowledge-base.md) — Research on OpenAB, Telegram integration, AgentCore, Strands, and Signal
- [Unified Setup Guide](docs/openab-telegram-unified-setup.md) — Full step-by-step Telegram setup

## Prerequisites

- AWS account with ECS/ECR access
- Telegram bot token (from [@BotFather](https://t.me/BotFather))
- Agent API key (Kiro, Claude, etc.)
- Public HTTPS URL for webhook (or Cloudflare Tunnel for dev)
