# OpenAB 4-Agent EC2 Demo — 2x Gemini + 2x Claude

One-line install on a fresh EC2. Builds images from source, sets up swap, launches 4 agents.

## One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/juntinyeh-worker/agent-outbound/main/openab-ec2-demo/install.sh | bash
```

Then:
```bash
cd ~/openab-demo
vim .env        # fill in bot tokens + API keys
./start.sh      # launch
```

## What It Does

1. Installs Docker + Docker Compose + git + envsubst
2. Clones OpenAB source → builds `openab-gemini` and `openab-claude` images locally
3. Downloads compose + config files to `~/openab-demo`
4. Creates 4GB swap to prevent OOM
5. You fill `.env`, run `./start.sh` → 4 agents online

## Requirements

- EC2: `t3.large` (8GB RAM) recommended, Amazon Linux 2023 or Ubuntu 22.04+
- Security group: outbound 443 open
- 4 Discord bot tokens (create at https://discord.com/developers)
- API keys: Google Gemini, Anthropic

## Agents

| Container | Bot Token Var | Backend |
|---|---|---|
| openab-gemini-1 | `DISCORD_BOT_TOKEN_GEMINI1` | Gemini CLI |
| openab-gemini-2 | `DISCORD_BOT_TOKEN_GEMINI2` | Gemini CLI |
| openab-claude-1 | `DISCORD_BOT_TOKEN_CLAUDE1` | Claude Code |
| openab-claude-2 | `DISCORD_BOT_TOKEN_CLAUDE2` | Claude Code |

## Operations

```bash
cd ~/openab-demo
docker compose ps              # status
docker compose logs -f         # all logs
docker compose restart         # restart
docker compose down            # stop
```

Rebuild images after OpenAB updates:
```bash
rm -rf ~/.openab-src
curl -fsSL .../install.sh | bash   # re-clones and rebuilds
```
