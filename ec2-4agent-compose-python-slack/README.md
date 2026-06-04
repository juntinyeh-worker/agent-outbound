# OpenAB 4-Agent on EC2 (with Python + Extensible Runtimes)

Deploy 4 OpenAB agents (Kiro, Claude, Gemini, Codex) on a single EC2 instance with **Python pre-installed** and the ability to install additional runtimes as needed.

## What's Different from the Base Setup

- Each agent container includes **Python 3 + pip + venv**
- `apt-get` cache is preserved so you can install additional packages without rebuilding:
  ```bash
  docker exec -u root openab-gemini apt-get install -y ruby golang
  ```

## Quick Start

```bash
ssh ec2-user@<your-ec2-ip>
git clone https://github.com/juntinyeh-worker/agent-workspaces.git
cd agent-workspaces/ec2-4agent-compose

cp .env.example .env
vim .env   # fill in all tokens and keys

chmod +x setup.sh
./setup.sh
```

## File Structure

```
ec2-4agent-compose/
├── Dockerfile              # Extends OpenAB images with Python + apt
├── docker-compose.yml      # 4-agent services (build from Dockerfile)
├── setup.sh                # One-stop install + build + launch
├── .env.example            # Template for secrets
└── config/
    ├── kiro.toml
    ├── claude.toml
    ├── gemini.toml
    └── codex.toml
```

## Installing Additional Runtimes

Inside any running container:

```bash
# Install at runtime (ephemeral — lost on container restart)
docker exec -u root openab-gemini apt-get install -y ruby

# Or add to Dockerfile permanently
# Edit Dockerfile, add your packages, then:
docker compose build && docker compose up -d
```

## Instance Sizing

| Agents | Instance    | RAM  | Monthly Cost |
|--------|-------------|------|--------------|
| 1–2    | t3.medium   | 4GB  | ~$30         |
| 3–4    | t3.large    | 8GB  | ~$60         |
| 5+     | m6i.large   | 8GB  | ~$70         |
