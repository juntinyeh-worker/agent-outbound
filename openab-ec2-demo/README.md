# OpenAB 4-Agent EC2 Demo

Deploy 4 AI agents (Kiro, Claude, Gemini, Codex) on a single EC2 with one command.

## One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/juntinyeh-worker/agent-outbound/main/openab-ec2-demo/install.sh | bash
```

Then:
```bash
cd ~/openab-demo
vim .env        # fill in your tokens and keys
./start.sh      # launch all 4 agents
```

## Prerequisites

- EC2: Amazon Linux 2023 or Ubuntu 22.04+ (`t3.large` recommended for 4 agents)
- Security group: outbound HTTPS (443) open
- 4 Discord bot tokens + 1 channel ID
- API keys: Kiro, Anthropic, Google Gemini, OpenAI

## What the Installer Does

1. Installs Docker + Docker Compose
2. Installs `envsubst` for config rendering
3. Downloads all project files to `~/openab-demo`
4. Creates `.env` template for you to fill in

## Operations

```bash
cd ~/openab-demo
docker compose ps              # status
docker compose logs -f         # all logs
docker compose logs agent-kiro # single agent
docker compose restart         # restart all
docker compose down            # stop all
docker compose pull && ./start.sh  # update images
```

## Architecture

```
EC2 (t3.large)
├── openab-kiro    → ghcr.io/openabdev/openab        (kiro-cli)
├── openab-claude  → ghcr.io/openabdev/openab-claude  (claude-agent-acp)
├── openab-gemini  → ghcr.io/openabdev/openab-gemini  (gemini --acp)
└── openab-codex   → ghcr.io/openabdev/openab-codex   (codex --acp)
```

All agents share one Discord channel with `allow_bot_messages = "mentions"` for inter-agent collaboration.
