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
            APIGW["API Gateway<br/>(slash commands)"]
            LAMBDA["Lambda: Admin<br/>Scale in/out · Diagnostics"]
            EVENTBRIDGE["EventBridge<br/>(scheduled health checks)"]
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

    HUMAN -->|"@mention bot"| DISCORD
    DISCORD -->|"Bot Gateway (WSS)"| SVC1 & SVC2

    HUMAN -->|"/admin command"| APIGW --> LAMBDA
    EVENTBRIDGE -->|"schedule"| LAMBDA
    LAMBDA -->|"update-service<br/>desired-count 0↔1"| WORKERS
    LAMBDA -->|"describe-tasks<br/>get-log-events"| WORKERS
    LAMBDA -->|"post status"| DISCORD

    SVC1 & SVC2 -->|"API"| LLM
    SVC1 & SVC2 -->|"git"| GITHUB
    SVC1 & SVC2 --- EFS
    SVC1 & SVC2 -->|"read secrets"| SSM
    ECR -.->|"pull"| WORKERS
```

---

## Component Breakdown

### Admin (Lambda) — Control Plane

The Admin Lambda is **not** a conversational agent. It manages the worker fleet.

| Aspect | Detail |
|--------|--------|
| **Runtime** | Lambda (Python or Node.js) |
| **Trigger** | EventBridge (scheduled) + API Gateway (Discord slash commands) |
| **Responsibilities** | Scale workers in/out, health checks, diagnostics |
| **Cost** | ~$0/month (pay per invocation) |

```mermaid
graph LR
    EVENTBRIDGE["EventBridge<br/>(every 5 min)"] --> LAMBDA["Lambda: Admin"]
    SLASH["/admin command"] --> APIGW["API Gateway"] --> LAMBDA
    LAMBDA -->|"desired-count 0↔1"| ECS["ECS API"]
    LAMBDA -->|"logs / metrics"| CW["CloudWatch"]
    LAMBDA -->|"post status"| DISCORD["Discord"]
```

**What it does:**

| Action | Trigger | API Call |
|--------|---------|---------|
| Start a worker | `/admin start agent-1` | `update-service --desired-count 1` |
| Stop idle worker | Scheduled (idle > 30 min) | `update-service --desired-count 0` |
| Diagnose | `/admin diagnose agent-1` | `describe-tasks` + `get-log-events` |
| Health check | Scheduled (every 5 min) | `describe-services`, restart unhealthy |

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
    participant Lambda as Lambda (Admin)
    participant ECS as ECS API
    participant CW as CloudWatch

    Note over Lambda: Scale-out
    Human->>Discord: /admin start agent-1
    Discord->>Lambda: Slash command
    Lambda->>ECS: update-service(agent-1, desired=1)
    Lambda->>Discord: "✅ agent-1 starting (~30s)"

    Note over Lambda: Scale-in (automated)
    Lambda->>CW: check active sessions
    Lambda->>Lambda: agent-2 idle > 30 min
    Lambda->>ECS: update-service(agent-2, desired=0)
    Lambda->>Discord: "💤 agent-2 stopped (idle)"

    Note over Lambda: Diagnostics
    Human->>Discord: /admin diagnose agent-1
    Discord->>Lambda: Slash command
    Lambda->>ECS: describe-tasks(agent-1)
    Lambda->>CW: get-log-events(last 50 lines)
    Lambda->>Discord: "agent-1: RUNNING, 2 sessions, no errors"
```

---

## Scaling Model

| State | Desired Count | Cost | Response Time |
|-------|--------------|------|---------------|
| **Running** | 1 | Fargate charges | Instant |
| **Stopped** | 0 | $0 | ~30s cold start |

**Commands:**

| Command | Effect |
|---------|--------|
| `/admin start agent-1` | desired-count = 1 |
| `/admin stop agent-2` | desired-count = 0 |
| `/admin stop-all` | All → 0 |
| `/admin start-all` | All → 1 |
| `/admin status` | Show running/stopped state |
| `/admin diagnose agent-1` | Task status + recent logs |

**Auto scale-in:** EventBridge → Lambda every 5 min. If idle > 30 min → stop.

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
