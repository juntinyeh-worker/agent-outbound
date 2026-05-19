# OpenAB Agent EC2 Demo

One-line installer to deploy AI agents on a single EC2 instance. Three scenarios available.

## One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/juntinyeh-worker/agent-outbound/main/openab-ec2-demo/install.sh | bash
```

Then:
```bash
cd ~/openab-demo
vim .env                    # fill in bot tokens + API keys
./start.sh                  # pick a scenario (see below)
```

## Scenarios

| Command | Agents | Bot Tokens Needed | API Keys |
|---------|--------|-------------------|----------|
| `./start.sh` | 2x Gemini + 2x Claude | 4 | Gemini + Anthropic |
| `./start.sh gemini3` | 3x Gemini | 3 | Gemini |
| `./start.sh claude2` | 2x Claude | 2 | Anthropic |

## Requirements

- EC2: `t3.large` (8GB RAM) recommended
- Amazon Linux 2023 or Ubuntu 22.04+
- Security group: outbound 443 open
- Discord bot tokens (one per agent)
- API keys for your chosen scenario

## What the Installer Does

1. Installs Docker + Docker Compose + git + envsubst
2. Builds `openab-gemini` and `openab-claude` images from source
3. Downloads all compose files + config templates
4. Sets up 4GB swap to prevent OOM

## Operations

```bash
cd ~/openab-demo

# Status / logs
docker compose ps
docker compose logs -f

# Stop
docker compose down

# Switch scenario (stop current first)
docker compose down
./start.sh gemini3

# Rebuild images after OpenAB updates
rm -rf ~/.openab-src
docker rmi openab-gemini:latest openab-claude:latest
# Re-run install script
```

## File Structure

```
~/openab-demo/
├── docker-compose.yml           # Scenario A: 2x Gemini + 2x Claude
├── docker-compose.gemini3.yml   # Scenario B: 3x Gemini
├── docker-compose.claude2.yml   # Scenario C: 2x Claude
├── start.sh                     # Launcher (picks scenario)
├── .env                         # Your secrets
└── config/
    ├── gemini1.toml             # Agent config templates
    ├── gemini2.toml
    ├── gemini3.toml
    ├── claude1.toml
    └── claude2.toml
```
