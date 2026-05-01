# OpenAB Software Team — Automated Multi-Role EKS Deployment

Deploy a 6-agent AI software team on Amazon EKS with [OpenAB](https://github.com/openabdev/openab). **Discord bot creation is fully automated** using Amazon Bedrock AgentCore Browser + Nova Act.

## What You Get

```
┌─────────────────────────────────────────────────────────────┐
│                     EKS Cluster                             │
│                                                             │
│  ┌────────┐ ┌──────────┐ ┌─────┐ ┌────┐ ┌────────┐ ┌─────┐│
│  │   PM   │ │ Architect│ │ Dev │ │ QA │ │CloudOps│ │Audit││
│  └────────┘ └──────────┘ └─────┘ └────┘ └────────┘ └─────┘│
└─────────────────────────────────────────────────────────────┘

Pipeline: PM → Architect+Dev → QA → CloudOps → Review → Audit
```

## What Gets Automated

| Step | Tool | What Happens |
|---|---|---|
| Discord bot creation (×6) | AgentCore Browser + Nova Act | Creates apps, enables intents, captures tokens |
| Server invite (×6) | AgentCore Browser | Adds each bot to your Discord server |
| Channel creation | Discord REST API | Creates `#team-agents` channel |
| EKS cluster | eksctl | Creates managed node group |
| EBS CSI driver | eksctl | Enables persistent volumes |
| K8s secrets | kubectl | Stores API keys securely |
| Helm deploy (×6 agents) | Helm | Deploys OpenAB with role configs |

## Prerequisites

- AWS account with EKS/ECR/IAM + Bedrock AgentCore permissions
- CLI tools: `aws`, `eksctl`, `kubectl`, `helm`, `python3`, `pip`
- Discord account with admin access to a server
- Kiro CLI API key — [kiro.dev](https://kiro.dev)
- Nova Act API key — [nova.amazon.com/act](https://nova.amazon.com/act)

## Quick Start (3 steps)

### Step 1: Clone

```bash
git clone -b OpenAB-SWTeam-discord-automation \
  https://github.com/juntinyeh-worker/agent-outbound.git openab-team
cd openab-team
```

### Step 2: Configure

```bash
cp .env.example .env
```

Fill in `.env`:
```bash
DISCORD_EMAIL=your@email.com        # Discord login
DISCORD_PASSWORD=your-password       # Discord password
DISCORD_SERVER_ID=123456789          # Right-click server → Copy Server ID
NOVA_ACT_API_KEY=your-nova-key       # From nova.amazon.com/act
KIRO_API_KEY=your-kiro-key           # From kiro.dev
```

### Step 3: Deploy

```bash
pip install -r requirements.txt
./quickstart.sh
```

That's it. The script will:
1. **Create 6 Discord bots** via AgentCore Browser (you can watch in live view)
2. **Invite them** to your server
3. **Create** a `#team-agents` channel
4. **Spin up** an EKS cluster
5. **Deploy** all 6 agents with role-specific configurations
6. **Wait** for everything to be ready

### Already have Discord bots?

Skip the automation and provide tokens manually:

```bash
# Fill in BOT_TOKEN_* and DISCORD_CHANNEL_ID in .env, then:
./quickstart.sh --skip-discord
```

## How Discord Automation Works

```
┌──────────────────────────────────────────────────────────┐
│  setup-discord.py                                        │
│                                                          │
│  AgentCore Browser (remote Chromium in AWS)               │
│  + Nova Act (AI-driven browser automation)               │
│                                                          │
│  1. Login to discord.com/developers                      │
│  2. For each role:                                       │
│     • New Application → set name                         │
│     • Bot tab → enable Message Content Intent            │
│     • Reset Token → capture bot token                    │
│     • OAuth2 invite → add to server                      │
│  3. Create #team-agents channel (REST API)               │
│  4. Write all tokens to .env                             │
│                                                          │
│  Live view: watch the automation in AWS Console          │
└──────────────────────────────────────────────────────────┘
```

### 2FA Support

If your Discord account has 2FA enabled, the script will pause and prompt you to enter the code via the AgentCore Browser live view in the AWS Console.

### Running setup-discord.py standalone

```bash
python setup-discord.py                          # all 6 roles
python setup-discord.py --roles pm dev qa         # subset
python setup-discord.py --skip-invite             # create apps only
python setup-discord.py --channel-name my-agents  # custom channel name
```

## Files

| File | Purpose |
|---|---|
| `quickstart.sh` | Full automated deploy (Discord + EKS + Helm) |
| `setup-discord.py` | Discord bot creation via AgentCore Browser |
| `destroy.sh` | Teardown with confirmation |
| `values-team.yaml` | Helm values: 6 agents with role configs |
| `.env.example` | All required variables |
| `requirements.txt` | Python dependencies |
| `PIPELINE.md` | Delivery pipeline details |
| `SECURITY-RULES.md` | Agent security guardrails |
| `roles/` | Detailed role definitions (6 files) |

## Operations

| Task | Command |
|---|---|
| Check pods | `kubectl get pods -n openab` |
| View logs | `kubectl logs -f deployment/openab-team-dev -n openab` |
| Restart agent | `kubectl rollout restart deployment/openab-team-dev -n openab` |
| Upgrade config | `helm upgrade openab-team openab/openab -n openab -f values-team.yaml --set ...` |
| Tear down | `./destroy.sh` |

## Cost Estimate

| Resource | Spec | ~Monthly |
|---|---|---|
| EKS control plane | 1 cluster | $73 |
| EC2 nodes | 2× t3.large | $120 |
| EBS volumes | 6× 2Gi gp3 | $3 |
| AgentCore Browser | ~10 min one-time setup | < $1 |
| **Total** | | **~$196/mo** |

## Security Notes

- Discord credentials are used **only** in the AgentCore Browser session (isolated, remote)
- Credentials are **never** stored beyond the `.env` file on your local machine
- Bot tokens are injected into K8s Secrets, not stored in Helm values
- All agents have anti-injection security rules in their `agentsMd`
- `.env` is in `.gitignore` — never committed
