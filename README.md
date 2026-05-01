# OpenAB Software Team — Multi-Role EKS Deployment Pack

Deploy a 6-agent AI software team on Amazon EKS with [OpenAB](https://github.com/openabdev/openab). Each agent has a distinct role in a structured delivery pipeline.

## What You Get

```
┌─────────────────────────────────────────────────────────────┐
│                     EKS Cluster                             │
│                                                             │
│  ┌────────┐ ┌──────────┐ ┌─────┐ ┌────┐ ┌────────┐ ┌─────┐│
│  │   PM   │ │ Architect│ │ Dev │ │ QA │ │CloudOps│ │Audit││
│  └────────┘ └──────────┘ └─────┘ └────┘ └────────┘ └─────┘│
│                                                             │
│  Each agent = Deployment + ConfigMap + Secret + PVC         │
│  Each agent = Discord bot + role-specific AGENTS.md         │
└─────────────────────────────────────────────────────────────┘
```

### Delivery Pipeline

```
Stage 1        Stage 2           Stage 3     Stage 4       Stage 5              Stage 6
  PM    ──→  Architect + Dev  ──→   QA   ──→  CloudOps  ──→  Architect+QA+PM  ──→  Audit
(plan)       (design+build)     (test)     (deploy)       (review gate)        (compliance)
```

## Files in This Pack

| File | Purpose |
|---|---|
| `quickstart.sh` | Automated 6-step deploy script |
| `destroy.sh` | Teardown script with confirmation |
| `values-team.yaml` | Helm values with all 6 agents + role configs |
| `.env.example` | Template for all required variables |
| `PIPELINE.md` | Delivery pipeline details |
| `SECURITY-RULES.md` | Agent security guardrails |
| `roles/agent.PM.md` | PM role definition |
| `roles/agent.Architect.md` | Architect role definition |
| `roles/agent.Full-stack-dev.md` | Developer role definition |
| `roles/agent.QA.md` | QA role definition |
| `roles/agent.CloudOps.md` | CloudOps role definition |
| `roles/agent.Compliance-auditor.md` | Auditor role definition |

## Prerequisites

- AWS account with EKS/ECR/IAM permissions
- CLI tools: `aws`, `eksctl`, `kubectl`, `helm`
- Discord server (admin access)
- Kiro CLI API key — [kiro.dev](https://kiro.dev)

## Quick Start (5 steps)

### Step 1: Clone this pack

```bash
git clone -b OpenAB-SWTeam-multirole https://github.com/juntinyeh-worker/agent-outbound.git openab-team
cd openab-team
```

### Step 2: Create 6 Discord bots

Go to [Discord Developer Portal](https://discord.com/developers/applications) and create one bot per role:

| Bot Name | Role |
|---|---|
| `Team-PM` | Project Manager |
| `Team-Architect` | Architect |
| `Team-Dev` | Full-Stack Developer |
| `Team-QA` | QA Engineer |
| `Team-CloudOps` | CloudOps Engineer |
| `Team-Auditor` | Compliance Auditor |

For each bot:
1. **New Application** → name it
2. **Bot** tab → enable **Message Content Intent** + **Server Members Intent**
3. **Bot** tab → **Reset Token** → copy token
4. **OAuth2 → URL Generator** → scope: `bot` → permissions:
   - Send Messages, Send Messages in Threads, Create Public Threads
   - Read Message History, Add Reactions, Manage Messages
5. Open the generated URL → invite bot to your server

### Step 3: Configure

```bash
cp .env.example .env
```

Edit `.env` and fill in:
- `AWS_REGION` / `CLUSTER_NAME`
- `DISCORD_CHANNEL_ID` — right-click channel → Copy Channel ID
- `KIRO_API_KEY` — from [kiro.dev](https://kiro.dev)
- `BOT_TOKEN_PM` through `BOT_TOKEN_AUDITOR` — from Step 2
- `GH_TOKEN` (optional) — for persistent agent memory

### Step 4: Deploy

```bash
./quickstart.sh
```

This will:
1. Create an EKS cluster (or use existing)
2. Install EBS CSI driver for persistent volumes
3. Create namespace + Kubernetes secrets
4. Deploy 6 agents via Helm
5. Wait for all pods to be ready
6. Print auth instructions

### Step 5: Authenticate agents

```bash
# Run for each agent (follow device-code flow in browser)
kubectl exec -it deployment/openab-team-pm -n openab -- kiro-cli login --use-device-flow
kubectl exec -it deployment/openab-team-architect -n openab -- kiro-cli login --use-device-flow
kubectl exec -it deployment/openab-team-dev -n openab -- kiro-cli login --use-device-flow
kubectl exec -it deployment/openab-team-qa -n openab -- kiro-cli login --use-device-flow
kubectl exec -it deployment/openab-team-cloudops -n openab -- kiro-cli login --use-device-flow
kubectl exec -it deployment/openab-team-auditor -n openab -- kiro-cli login --use-device-flow

# Restart all agents to pick up auth
kubectl rollout restart deployment -n openab -l app.kubernetes.io/instance=openab-team
```

### Done! Test it

In your Discord channel:
```
@Team-PM What is your role?
@Team-Dev What is your role?
```

Start a project:
```
@Team-PM I need a REST API that returns weather data. Create requirements and hand off to the team.
```

## Post-Deploy: Bot-to-Bot Communication

After all bots are online, enable them to @mention each other:

1. In Discord, right-click each bot → **Copy User ID**
2. Add all IDs to `trustedBotIds` in `values-team.yaml`:
   ```yaml
   trustedBotIds:
     - "PM_BOT_ID"
     - "ARCHITECT_BOT_ID"
     - "DEV_BOT_ID"
     - "QA_BOT_ID"
     - "CLOUDOPS_BOT_ID"
     - "AUDITOR_BOT_ID"
   ```
3. Upgrade: `helm upgrade openab-team openab/openab -n openab -f values-team.yaml --set ...`

## Operations

| Task | Command |
|---|---|
| Check pods | `kubectl get pods -n openab` |
| View logs | `kubectl logs -f deployment/openab-team-dev -n openab` |
| Restart agent | `kubectl rollout restart deployment/openab-team-dev -n openab` |
| Upgrade config | `helm upgrade openab-team openab/openab -n openab -f values-team.yaml --set ...` |
| Scale nodes | `eksctl scale nodegroup --cluster openab-team --nodes 3` |
| Tear down | `./destroy.sh` |

## Cost Estimate

| Resource | Spec | ~Monthly |
|---|---|---|
| EKS control plane | 1 cluster | $73 |
| EC2 nodes | 2× t3.large | $120 |
| EBS volumes | 6× 2Gi gp3 | $3 |
| **Total** | | **~$196/mo** |

## Roles Reference

See `roles/` directory for detailed role definitions, or `PIPELINE.md` for the full delivery pipeline.

| Role | Pipeline Stage | Key Responsibility |
|---|---|---|
| PM | 1, 5 | Requirements, scope, priorities |
| Architect | 2, 5 | System design, API contracts, review lead |
| Dev | 2 | Frontend + backend + agent implementation |
| QA | 3, 5 | Testing, security testing, bug reports |
| CloudOps | 4 | Infrastructure deploy, monitoring, rollback |
| Auditor | 6 | Compliance audit, final sign-off |
