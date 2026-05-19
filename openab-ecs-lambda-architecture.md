# OpenAB ECS Fargate + Lambda Architecture

> Serverless-first deployment — Admin on Lambda, 2 Workers on ECS Fargate

## Overview

A lightweight serverless architecture: Admin runs as a Lambda function (control plane), worker agents run as ECS Fargate services (data plane). No servers to manage, pay only for what you use.

---

## Architecture Comparison

| | EC2 Docker Compose (POC) | ECS Fargate + Lambda | EKS (Production) |
|---|---|---|---|
| **Admin** | Same container | Lambda (event-driven) | Dedicated EKS cluster |
| **Workers** | Docker containers | ECS Fargate services | EKS pods |
| **Infra management** | Manual | Managed (no servers) | eksctl / Helm |
| **Scaling** | Vertical | Per-service (desired 0↔1) | Horizontal |
| **Cost (idle)** | ~$60/month | ~$15–30/month | ~$200+/month |
| **HA** | None | Multi-AZ (Fargate) | Multi-AZ (EKS) |

---

## System Architecture

```mermaid
graph TB
    HUMAN["👤 Human / Admin<br/>Discord"]

    subgraph AWS["AWS"]
        subgraph ADMIN["Control Plane"]
            LAMBDA["Lambda: Admin Agent<br/>(OpenAB + Agent CLI)<br/>Natural language → ECS management"]
        end

        subgraph WORKERS["ECS Fargate Cluster"]
            SVC1["Service: Agent-1<br/>(Kiro / Gemini / Claude)"]
            SVC2["Service: Agent-2<br/>(Kiro / Gemini / Claude)"]
        end

        subgraph STORAGE["Storage"]
            EFS["EFS<br/>(persistent /home)"]
            SSM["SSM Parameter Store<br/>(secrets)"]
            ECR["ECR<br/>(agent images)"]
        end
    end

    subgraph EXTERNAL["External Services"]
        DISCORD["Discord API"]
        LLM["LLM API<br/>(Gemini / Anthropic / Kiro)"]
        GITHUB["GitHub"]
    end

    HUMAN -->|"@mention worker"| DISCORD
    DISCORD -->|"Bot Gateway (WSS)"| SVC1 & SVC2

    HUMAN -->|"@mention admin<br/>(natural language)"| DISCORD
    DISCORD -->|"invoke"| LAMBDA
    LAMBDA -->|"update-service<br/>desired-count 0↔1"| WORKERS
    LAMBDA -->|"describe-tasks<br/>get-log-events"| WORKERS
    LAMBDA -->|"reply"| DISCORD

    SVC1 & SVC2 -->|"API"| LLM
    SVC1 & SVC2 -->|"git"| GITHUB
    SVC1 & SVC2 --- EFS
    SVC1 & SVC2 -->|"read secrets"| SSM
    ECR -.->|"pull"| WORKERS & LAMBDA
```

---

## Component Breakdown

### Admin (Lambda) — Control Plane

The Admin Lambda runs **the same OpenAB + Agent container image** as the workers. It's a full conversational agent that you talk to in natural language via Discord — it just happens to run on Lambda instead of Fargate.

You tell it things like:
- "stop agent-2, it's not needed right now"
- "start agent-1 back up"
- "what's the status of all agents?"
- "agent-1 seems stuck, check its logs"

The agent interprets your intent and calls the ECS API accordingly.

| Aspect | Detail |
|--------|--------|
| **Runtime** | Lambda container image (same `openab` + agent CLI) |
| **Trigger** | Discord message (via bot gateway / webhook) |
| **How it works** | Natural language → Agent reasons → calls ECS/CloudWatch APIs as tools |
| **Cost** | ~$0/month (runs only when you message it) |

```mermaid
graph LR
    HUMAN["👤 Human"] -->|"natural language<br/>via Discord"| ADMIN["Lambda: Admin Agent<br/>(OpenAB + Kiro/Gemini/Claude)"]
    ADMIN -->|"update-service<br/>desired-count 0↔1"| ECS["ECS API"]
    ADMIN -->|"describe-tasks<br/>get-log-events"| CW["CloudWatch"]
    ADMIN -->|"reply in<br/>natural language"| HUMAN
```

**Why Lambda for Admin:**
- Admin conversations are short-lived (ask a question, get an answer, done)
- No need to keep a Fargate task running 24/7 for occasional admin requests
- Same agent image — no special code, just different IAM permissions
- Cost: effectively $0 (Lambda container invocations are cheap)

### Workers (ECS Fargate) — Data Plane

Each worker is an ECS service running one Fargate task. Pick any agent CLI per service.

| Aspect | Detail |
|--------|--------|
| **Image options** | `openab` (Kiro), `openab-gemini`, `openab-claude` |
| **Networking** | awsvpc, outbound-only via NAT Gateway |
| **Storage** | EFS mount at `/home/node` or `/home/agent` |
| **Secrets** | SSM → injected as env vars |
| **Scaling** | Binary: desired-count 0 (off) or 1 (on) |

```mermaid
graph TB
    subgraph ECS["ECS Fargate Cluster"]
        subgraph SVC1["Service: agent-1"]
            TASK1["Task<br/>0.5 vCPU / 1–2GB"]
        end
        subgraph SVC2["Service: agent-2"]
            TASK2["Task<br/>0.5 vCPU / 1–2GB"]
        end
    end
    EFS["EFS"] --- TASK1 & TASK2
```

---

## Networking

```mermaid
graph TB
    subgraph VPC["VPC"]
        subgraph PUBLIC["Public Subnet"]
            NAT["NAT Gateway"]
        end
        subgraph PRIVATE["Private Subnets (multi-AZ)"]
            TASK1["Agent-1"]
            TASK2["Agent-2"]
        end
        EFS["EFS Mount Targets"]
    end

    TASK1 & TASK2 -->|"outbound 443"| NAT --> INTERNET["Internet<br/>Discord · LLM APIs · GitHub"]
    TASK1 & TASK2 --- EFS
```

- No inbound ports — agents connect outbound to Discord WebSocket
- Private subnets — not directly internet-accessible
- NAT Gateway — outbound internet access

---

## Secrets Management

```mermaid
graph LR
    SSM["SSM Parameter Store"]
    SSM -->|"/openab/discord/bot-token-1"| A1["Agent-1"]
    SSM -->|"/openab/discord/bot-token-2"| A2["Agent-2"]
    SSM -->|"/openab/api/llm-key"| A1 & A2
    SSM -->|"/openab/github/pat"| A1 & A2
```

---

## Task Definition (Example)

```json
{
  "family": "openab-agent",
  "cpu": "512",
  "memory": "1024",
  "networkMode": "awsvpc",
  "containerDefinitions": [{
    "name": "openab",
    "image": "<account>.dkr.ecr.<region>.amazonaws.com/openab-gemini:latest",
    "command": ["openab", "run", "-c", "/etc/openab/config.toml"],
    "secrets": [
      {"name": "DISCORD_BOT_TOKEN", "valueFrom": "/openab/discord/bot-token-1"},
      {"name": "GEMINI_API_KEY", "valueFrom": "/openab/api/gemini-key"},
      {"name": "GH_TOKEN", "valueFrom": "/openab/github/pat"}
    ],
    "mountPoints": [{"sourceVolume": "home", "containerPath": "/home/node"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/openab-agent-1",
        "awslogs-region": "<region>",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }],
  "volumes": [{
    "name": "home",
    "efsVolumeConfiguration": {
      "fileSystemId": "fs-xxxxxxxx",
      "rootDirectory": "/agent1"
    }
  }]
}
```

---

## Operations Flow

```mermaid
sequenceDiagram
    participant Human
    participant Discord
    participant Admin as Lambda (Admin Agent)
    participant ECS as ECS API
    participant CW as CloudWatch

    Note over Admin: Scale-out
    Human->>Discord: "@admin start agent-1 please"
    Discord->>Admin: Message (natural language)
    Admin->>Admin: Reason: user wants agent-1 running
    Admin->>ECS: update-service(agent-1, desired=1)
    Admin->>Discord: "Done — agent-1 is starting up, should be ready in ~30s"

    Note over Admin: Scale-in
    Human->>Discord: "@admin stop agent-2, we don't need it tonight"
    Discord->>Admin: Message
    Admin->>ECS: update-service(agent-2, desired=0)
    Admin->>Discord: "Stopped agent-2. It won't incur charges until restarted."

    Note over Admin: Diagnostics
    Human->>Discord: "@admin agent-1 seems stuck, can you check?"
    Discord->>Admin: Message
    Admin->>ECS: describe-tasks(agent-1)
    Admin->>CW: get-log-events(agent-1, last 50 lines)
    Admin->>Discord: "agent-1 is RUNNING with 2 active sessions. Last log shows a rate limit from Gemini API — it should recover automatically."
```

---

## Scaling Model

The Admin agent controls worker lifecycle via natural language → ECS API:

| State | Desired Count | Cost | Response Time |
|-------|--------------|------|---------------|
| **Running** | 1 | Fargate charges | Instant |
| **Stopped** | 0 | $0 | ~30s cold start |

**Example conversations with Admin:**

| You say | Admin does |
|---------|-----------|
| "start agent-1" | `update-service --desired-count 1` |
| "shut down everything for the night" | All services → `desired-count 0` |
| "what's running right now?" | `describe-services` → reports status |
| "agent-2 isn't responding, check it" | `describe-tasks` + `get-log-events` → diagnoses |
| "restart agent-1" | `desired-count 0`, wait, `desired-count 1` |

**Optional: automated scale-in** — add EventBridge trigger (every 5 min) to invoke the Admin agent with a system message like "check if any workers are idle and stop them if so."

---

## Cost Estimate (2 agents)

| Component | Monthly Cost |
|-----------|-------------|
| Fargate (2 tasks × 0.5 vCPU × 1GB, 24/7) | ~$15–25 |
| EFS (2GB) | ~$0.50 |
| NAT Gateway | ~$5 |
| Lambda (<1000 invocations) | ~$0 |
| SSM / ECR / CloudWatch | ~$2 |
| **Total** | **~$25–35/month** |

With auto scale-in (agents stopped at night): **~$15–20/month**.

---

## Agent Flexibility

Each ECS service independently chooses its agent CLI:

| Service | Image | Agent CLI | Use Case |
|---------|-------|-----------|----------|
| agent-1 | `openab` | kiro-cli | AWS-focused tasks |
| agent-1 | `openab-gemini` | gemini | General coding |
| agent-1 | `openab-claude` | claude-code | Complex reasoning |

Mix and match — just change the image in the task definition.

---

## Migration Path

```
EC2 Docker Compose (POC)     →  same images, move .env to SSM, volumes to EFS
        ↓
ECS Fargate + Lambda         →  task definitions become pod specs
        ↓
EKS (Full Kubernetes)
```
