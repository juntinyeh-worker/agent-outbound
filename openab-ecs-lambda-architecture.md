# OpenAB ECS Fargate + Lambda Architecture

> Serverless-first deployment — Admin on Lambda, Workers on ECS Fargate

## Overview

A middle-ground architecture between the single-EC2 POC and the full EKS production setup. The Admin agent runs as an event-driven Lambda function, while worker agents run as long-lived ECS Fargate services. No cluster management, no EC2 instances to maintain.

---

## Architecture Comparison

| | EC2 Docker Compose (POC) | ECS Fargate + Lambda | EKS (Production) |
|---|---|---|---|
| **Admin agent** | Same container | Lambda (event-driven) | Dedicated EKS cluster |
| **Worker agents** | Docker containers | ECS Fargate services | EKS pods |
| **Infra management** | Manual | Managed (no servers) | eksctl / Helm |
| **Scaling** | Vertical (resize EC2) | Per-service (Fargate tasks) | Horizontal (nodes + pods) |
| **Cost (idle)** | ~$60/month (always on) | ~$30–50/month (Fargate only) | ~$200+/month |
| **Cost (active)** | Same | Pay-per-use Lambda + Fargate | Same |
| **HA** | None | Multi-AZ (Fargate) | Multi-AZ (EKS) |
| **Setup complexity** | Low | Medium | High |

---

## System Architecture

```mermaid
graph TB
    HUMAN["👤 Human / Admin<br/>Discord"]

    subgraph AWS["AWS"]
        subgraph ADMIN["Admin Layer (Control Plane)"]
            APIGW["API Gateway<br/>(slash commands)"]
            LAMBDA["Lambda: Admin<br/>Scale in/out · Diagnostics"]
            EVENTBRIDGE["EventBridge<br/>(scheduled health checks)"]
        end

        subgraph WORKERS["ECS Fargate Cluster (Data Plane)"]
            SVC1["Service: Gemini-1 🟦<br/>Fargate Task"]
            SVC2["Service: Gemini-2 🟦<br/>Fargate Task"]
            SVC3["Service: Claude-1 🟣<br/>Fargate Task"]
            SVC4["Service: Claude-2 🟣<br/>Fargate Task"]
        end

        subgraph STORAGE["Storage"]
            EFS["EFS<br/>(persistent /home per agent)"]
            SSM["SSM Parameter Store<br/>(secrets)"]
            ECR["ECR<br/>(agent images)"]
        end

        subgraph EXTERNAL["External"]
            DISCORD["Discord API"]
            GEMINI_API["Gemini API"]
            ANTHROPIC_API["Anthropic API"]
            GITHUB["GitHub"]
        end
    end

    HUMAN -->|"@mention bot"| DISCORD
    DISCORD -->|"Bot Gateway (WSS)"| SVC1 & SVC2 & SVC3 & SVC4

    HUMAN -->|"/admin command"| APIGW --> LAMBDA
    EVENTBRIDGE -->|"schedule"| LAMBDA
    LAMBDA -->|"update-service<br/>desired-count 0↔1"| WORKERS
    LAMBDA -->|"describe-tasks<br/>get-log-events"| WORKERS
    LAMBDA -->|"post status"| DISCORD

    SVC1 & SVC2 -->|"API"| GEMINI_API
    SVC3 & SVC4 -->|"API"| ANTHROPIC_API
    SVC1 & SVC2 & SVC3 & SVC4 -->|"git"| GITHUB
    SVC1 & SVC2 & SVC3 & SVC4 --- EFS
    SVC1 & SVC2 & SVC3 & SVC4 -->|"read secrets"| SSM
    ECR -.->|"pull"| WORKERS
```

---

## Component Breakdown

### Admin Agent (Lambda)

The Admin Lambda is **not** a conversational agent — it's a control-plane function that manages the worker fleet.

| Aspect | Detail |
|--------|--------|
| **Runtime** | Lambda (Python or Node.js) |
| **Trigger** | EventBridge schedule + manual invocation (Discord slash command or CLI) |
| **Responsibilities** | Scale workers in/out (desired count 0↔1), real-time diagnostics |
| **State** | Stateless — reads ECS service status, CloudWatch metrics |
| **Timeout** | 15 min max |
| **Cost** | Near-zero (pay per invocation) |

**What the Admin Lambda does:**

| Action | When | ECS API Call |
|--------|------|-------------|
| **Scale out** (start worker) | Demand detected or manual trigger | `update-service --desired-count 1` |
| **Scale in** (stop idle worker) | Worker idle for N minutes | `update-service --desired-count 0` |
| **Diagnose** | On-demand (admin request) | `describe-tasks`, `get-log-events` |
| **Health check** | Scheduled (every 5 min) | `describe-services`, restart unhealthy |

```mermaid
graph LR
    EVENTBRIDGE["EventBridge<br/>Schedule (every 5 min)"] --> LAMBDA["Lambda: Admin"]
    SLASH["Discord Slash Command<br/>/admin scale gemini-1 up"] --> APIGW["API Gateway"] --> LAMBDA
    LAMBDA -->|"update-service<br/>desired-count 0 or 1"| ECS["ECS API"]
    LAMBDA -->|"describe-tasks<br/>get-log-events"| CW["CloudWatch"]
    LAMBDA -->|"post status"| DISCORD["Discord Channel"]
```

**Why Lambda for Admin:**
- Admin operations are infrequent and short-lived (set desired count, read logs)
- No need to keep a process running 24/7 just to occasionally flip a switch
- Workers handle their own Discord conversations — Admin doesn't route messages
- Cost: ~$0/month (a few hundred invocations at most)

**Scale-in/out logic (example):**
```
IF worker has no active sessions for 30 min → set desired-count = 0
IF message arrives for a stopped worker → set desired-count = 1, reply "starting up..."
```

### Worker Agents (ECS Fargate)

| Aspect | Detail |
|--------|--------|
| **Runtime** | ECS Fargate (long-running service) |
| **Image** | Same `openab-gemini` / `openab-claude` from ECR |
| **Networking** | awsvpc mode, outbound-only (NAT Gateway or VPC endpoints) |
| **Storage** | EFS mount for persistent `/home` |
| **Secrets** | SSM Parameter Store → injected as env vars |
| **Scaling** | Desired count per service (1 task = 1 agent) |

```mermaid
graph TB
    subgraph ECS["ECS Fargate Cluster"]
        subgraph SVC_G1["Service: gemini-1"]
            TASK_G1["Task<br/>0.5 vCPU / 1GB"]
        end
        subgraph SVC_G2["Service: gemini-2"]
            TASK_G2["Task<br/>0.5 vCPU / 1GB"]
        end
        subgraph SVC_C1["Service: claude-1"]
            TASK_C1["Task<br/>0.5 vCPU / 2GB"]
        end
        subgraph SVC_C2["Service: claude-2"]
            TASK_C2["Task<br/>0.5 vCPU / 2GB"]
        end
    end

    EFS["EFS File System"] --- TASK_G1 & TASK_G2 & TASK_C1 & TASK_C2
```

---

## Networking

```mermaid
graph TB
    subgraph VPC["VPC"]
        subgraph PUBLIC["Public Subnets"]
            NAT["NAT Gateway"]
        end
        subgraph PRIVATE["Private Subnets (multi-AZ)"]
            TASK1["Fargate Task 1"]
            TASK2["Fargate Task 2"]
            TASK3["Fargate Task 3"]
            TASK4["Fargate Task 4"]
        end
        EFS["EFS Mount Targets"]
    end

    TASK1 & TASK2 & TASK3 & TASK4 -->|"outbound 443"| NAT
    NAT --> INTERNET["Internet<br/>Discord · LLM APIs · GitHub"]
    TASK1 & TASK2 & TASK3 & TASK4 --- EFS
```

- **No inbound ports** — agents connect outbound to Discord WebSocket
- **Private subnets** — tasks not directly internet-accessible
- **NAT Gateway** — provides outbound internet access
- **EFS** — mounted in same AZs as Fargate tasks

---

## Secrets Management

```mermaid
graph LR
    SSM["SSM Parameter Store"]
    SSM -->|"/openab/discord/bot-token-gemini1"| G1["Gemini-1"]
    SSM -->|"/openab/discord/bot-token-gemini2"| G2["Gemini-2"]
    SSM -->|"/openab/discord/bot-token-claude1"| C1["Claude-1"]
    SSM -->|"/openab/discord/bot-token-claude2"| C2["Claude-2"]
    SSM -->|"/openab/api/gemini-key"| G1 & G2
    SSM -->|"/openab/api/anthropic-key"| C1 & C2
```

Secrets stored in SSM Parameter Store (SecureString), injected into task definitions as environment variables. No `.env` files on disk.

---

## Task Definition (Example)

```json
{
  "family": "openab-gemini",
  "cpu": "512",
  "memory": "1024",
  "networkMode": "awsvpc",
  "containerDefinitions": [{
    "name": "openab-gemini",
    "image": "<account>.dkr.ecr.<region>.amazonaws.com/openab-gemini:latest",
    "essential": true,
    "command": ["openab", "run", "-c", "/etc/openab/config.toml"],
    "secrets": [
      {"name": "DISCORD_BOT_TOKEN", "valueFrom": "/openab/discord/bot-token-gemini1"},
      {"name": "GEMINI_API_KEY", "valueFrom": "/openab/api/gemini-key"},
      {"name": "GH_TOKEN", "valueFrom": "/openab/github/pat"}
    ],
    "mountPoints": [{
      "sourceVolume": "agent-home",
      "containerPath": "/home/node"
    }],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/openab-gemini-1",
        "awslogs-region": "<region>",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }],
  "volumes": [{
    "name": "agent-home",
    "efsVolumeConfiguration": {
      "fileSystemId": "fs-xxxxxxxx",
      "rootDirectory": "/gemini1"
    }
  }]
}
```

---

## Cost Estimate (4 agents)

| Component | Monthly Cost |
|-----------|-------------|
| Fargate (4 tasks × 0.5 vCPU × 1–2GB, 24/7) | ~$40–60 |
| EFS (5GB, infrequent access) | ~$1 |
| NAT Gateway (outbound traffic) | ~$5–10 |
| Lambda (Admin, <1000 invocations) | ~$0 |
| SSM Parameter Store | ~$0 |
| ECR (image storage) | ~$1 |
| CloudWatch Logs | ~$2 |
| **Total** | **~$50–75/month** |

---

## Admin Lambda: Operations Flow

```mermaid
sequenceDiagram
    participant Human
    participant Discord
    participant Lambda as Lambda (Admin)
    participant ECS as ECS API
    participant CW as CloudWatch

    Note over Lambda: Scale-out (on demand)
    Human->>Discord: /admin start gemini-1
    Discord->>Lambda: Slash command webhook
    Lambda->>ECS: update-service(gemini-1, desired=1)
    Lambda->>Discord: "✅ gemini-1 starting up (~30s)"

    Note over Lambda: Scale-in (scheduled)
    Lambda->>ECS: describe-services (all workers)
    Lambda->>CW: get-metric (active sessions)
    Lambda->>Lambda: gemini-2 idle > 30 min
    Lambda->>ECS: update-service(gemini-2, desired=0)
    Lambda->>Discord: "💤 gemini-2 scaled to 0 (idle)"

    Note over Lambda: Diagnostics (on demand)
    Human->>Discord: /admin diagnose claude-1
    Discord->>Lambda: Slash command webhook
    Lambda->>ECS: describe-tasks(claude-1)
    Lambda->>CW: get-log-events(claude-1, last 50 lines)
    Lambda->>Discord: "claude-1: RUNNING, 2 sessions, last error: none"
```

---

## Scaling Model

The Admin Lambda controls worker lifecycle via ECS `update-service`:

| State | Desired Count | Cost | Latency |
|-------|--------------|------|---------|
| **Running** (active) | 1 | Fargate charges apply | Instant response |
| **Stopped** (idle) | 0 | $0 | ~30s cold start on next request |

**Admin commands (via Discord slash commands or EventBridge):**

| Command | Action |
|---------|--------|
| `/admin start gemini-1` | `desired-count = 1` |
| `/admin stop gemini-2` | `desired-count = 0` |
| `/admin stop-all` | All services → `desired-count = 0` |
| `/admin start-all` | All services → `desired-count = 1` |
| `/admin status` | List all services + running/stopped state |
| `/admin diagnose claude-1` | Fetch task status + recent logs |

**Automated scale-in (EventBridge → Lambda, every 5 min):**
- Check each worker's active session count (via CloudWatch or OpenAB metrics)
- If idle > configurable threshold (e.g., 30 min) → set desired-count = 0
- Saves cost during off-hours without manual intervention

---

## vs EKS: When to Use This

| Choose ECS Fargate + Lambda when... | Choose EKS when... |
|---|---|
| Team doesn't know Kubernetes | Team already uses K8s |
| Want zero server management | Need custom scheduling/operators |
| 2–6 agents | 10+ agents |
| Cost-sensitive | Need advanced networking (service mesh) |
| Simple scaling (per-service) | Complex multi-tenant isolation |

---

## Migration Path

```
EC2 Docker Compose (POC)
        ↓ ready for production
ECS Fargate + Lambda (Serverless)
        ↓ outgrow Fargate limits
EKS (Full Kubernetes)
```

The same Docker images work across all three. The main changes are:
- **EC2 → ECS**: Move `.env` to SSM, Docker volumes to EFS, compose to task definitions
- **ECS → EKS**: Task definitions become pod specs, EFS stays, add Helm chart
