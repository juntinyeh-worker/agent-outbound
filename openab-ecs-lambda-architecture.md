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
        subgraph ADMIN["Admin Layer"]
            APIGW["API Gateway<br/>(Discord Interactions Endpoint)"]
            LAMBDA["Lambda: AdminAgent<br/>Task dispatch · Cluster management"]
            SQS["SQS Queues<br/>(per-worker task routing)"]
        end

        subgraph WORKERS["ECS Fargate Cluster"]
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

    HUMAN -->|"@mention"| DISCORD
    DISCORD -->|"Bot Gateway (WSS)"| SVC1 & SVC2 & SVC3 & SVC4
    DISCORD -->|"Interactions webhook"| APIGW --> LAMBDA

    LAMBDA -->|"dispatch tasks"| SQS
    SQS -->|"consume"| SVC1 & SVC2 & SVC3 & SVC4

    LAMBDA -->|"manage services"| WORKERS

    SVC1 & SVC2 -->|"API"| GEMINI_API
    SVC3 & SVC4 -->|"API"| ANTHROPIC_API
    SVC1 & SVC2 & SVC3 & SVC4 -->|"git"| GITHUB
    SVC1 & SVC2 & SVC3 & SVC4 --- EFS
    LAMBDA & SVC1 & SVC2 & SVC3 & SVC4 -->|"read secrets"| SSM
    ECR -.->|"pull"| WORKERS
```

---

## Component Breakdown

### Admin Agent (Lambda)

| Aspect | Detail |
|--------|--------|
| **Runtime** | Lambda (Node.js or custom runtime) |
| **Trigger** | API Gateway (Discord Interactions endpoint) + EventBridge (scheduled) |
| **Responsibilities** | Task dispatch, worker health checks, scaling decisions |
| **State** | Stateless — reads/writes to DynamoDB or GitHub |
| **Timeout** | 15 min max (sufficient for dispatch, not for long tasks) |
| **Cost** | Near-zero when idle (pay per invocation) |

```mermaid
graph LR
    DISCORD["Discord<br/>Interactions Webhook"] --> APIGW["API Gateway"]
    APIGW --> LAMBDA["Lambda: Admin"]
    EVENTBRIDGE["EventBridge<br/>Schedule (health check)"] --> LAMBDA
    LAMBDA --> SQS["SQS<br/>(task queues)"]
    LAMBDA --> ECS["ECS API<br/>(scale/restart)"]
    LAMBDA --> SSM["SSM<br/>(config)"]
```

**Why Lambda for Admin:**
- Admin tasks are short-lived (dispatch a task, check health, scale a service)
- No need to keep a process running 24/7 just for occasional admin commands
- Cost: ~$0/month for typical admin usage (few hundred invocations)

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

## Admin Lambda: Task Dispatch Flow

```mermaid
sequenceDiagram
    participant Human
    participant Discord
    participant Lambda as Lambda (Admin)
    participant SQS
    participant Worker as ECS Worker

    Human->>Discord: /assign task to gemini-1
    Discord->>Lambda: Interaction webhook
    Lambda->>Lambda: Parse command, select worker
    Lambda->>SQS: Enqueue task message
    Lambda->>Discord: "✅ Task dispatched to gemini-1"
    Worker->>SQS: Poll queue
    Worker->>Worker: Execute task
    Worker->>Discord: Post result in thread
```

---

## Scaling Model

| Action | How |
|--------|-----|
| Add a worker | New ECS service + task definition |
| Remove a worker | Set desired count = 0 |
| Pause all workers | `aws ecs update-service --desired-count 0` |
| Resume | `aws ecs update-service --desired-count 1` |
| Scale a worker (more resources) | Update task definition CPU/memory |

The Admin Lambda can automate these via the ECS API — e.g., scale down workers at night, scale up on demand.

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
