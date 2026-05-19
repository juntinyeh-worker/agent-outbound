# OpenAB Multi-Agent Demo — Single Bot, Multiple Backend Agents

One Discord bot, one router agent, multiple specialized backend agents collaborating via MCP.

## Architecture

```
Human → Discord → Router Agent (OpenAB) → Backend Agents (MCP)
                                          ├── Planner (Gemini)
                                          ├── Developer (Claude)
                                          └── Reviewer (Gemini)
```

- **Router**: Holds the bot token, receives messages, decides which agent to call
- **Backend agents**: Headless (no Discord), called by router as MCP tool servers
- **1 bot token** — clean UX, one bot in the channel

## Quick Start

```bash
cd ~/openab-demo-multi-agent
cp .env.example .env
vim .env        # 1 bot token + API keys
./start.sh
```

## Requirements

- EC2: `t3.large` (8GB RAM)
- 1 Discord bot token
- API keys: Gemini (router + planner + reviewer), Anthropic (developer)
- Images built from source (same as openab-ec2-demo)

## File Structure

```
openab-ec2-demo-multi-agent/
├── docker-compose.yml       # 4 containers: router + 3 backend agents
├── start.sh                 # Validate, render, launch
├── .env.example             # Secrets template
├── config/
│   ├── router.toml          # OpenAB config for router (Discord connection)
│   └── mcp-router.json      # MCP endpoints (points to backend containers)
└── prompts/
    ├── planner.md           # Planner agent system prompt
    ├── developer.md         # Developer agent system prompt
    └── reviewer.md          # Reviewer agent system prompt
```

## How It Works

1. You @mention the bot in Discord
2. Router agent receives the message
3. Router decides which backend agent(s) to call (via MCP tools)
4. Backend agent processes and returns result
5. Router synthesizes and replies in Discord

## Customization

- **Change agent roles**: Edit files in `prompts/`
- **Add more agents**: Add a service in `docker-compose.yml` + entry in `mcp-router.json`
- **Swap models**: Change image (`openab-gemini` ↔ `openab-claude`) per service
