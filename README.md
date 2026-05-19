# Agent Outbound

Public deliverables from the OpenAB worker agents.

## Branches

| Branch | Description |
|--------|-------------|
| [`main`](https://github.com/juntinyeh-worker/agent-outbound/tree/main) | EC2 demo (2x Gemini + 2x Claude) + architecture docs |
| [`openab-macos-kiro`](https://github.com/juntinyeh-worker/agent-outbound/tree/openab-macos-kiro) | Native macOS setup for OpenAB + Kiro CLI (no Docker, builds from source) |
| [`OpenAB-SWTeam-multirole`](https://github.com/juntinyeh-worker/agent-outbound/tree/OpenAB-SWTeam-multirole) | 6-agent AI software team on EKS (PM, Architect, Dev, QA, CloudOps, Audit) with structured delivery pipeline |
| [`OpenAB-SWTeam-discord-automation`](https://github.com/juntinyeh-worker/agent-outbound/tree/OpenAB-SWTeam-discord-automation) | Same 6-agent team + fully automated Discord bot creation via Amazon Bedrock AgentCore Browser + Nova Act |

## Contents (main branch)

### [openab-ec2-demo/](./openab-ec2-demo/)

One-line installer to deploy 2x Gemini + 2x Claude agents on a single EC2 instance.

```bash
curl -fsSL https://raw.githubusercontent.com/juntinyeh-worker/agent-outbound/main/openab-ec2-demo/install.sh | bash
```

- Builds images from source (no registry auth needed)
- Docker Compose with 4 agents
- Optional GitHub + Atlassian (Jira/Confluence) integration via MCP
- 4GB swap setup included

### [openab-cluster-architecture.md](./openab-cluster-architecture.md)

Architecture overview of the OpenAB EKS cluster deployment (production).

### [openab-ecs-lambda-architecture.md](./openab-ecs-lambda-architecture.md)

Architecture overview of the ECS Fargate + Lambda deployment (serverless, Admin on Lambda, Workers on Fargate).

### [openab-ec2-architecture.md](./openab-ec2-architecture.md)

Architecture overview of the Docker Compose single-EC2 deployment (POC/demo).

### [worker-agent-workflow.md](./worker-agent-workflow.md)

Documentation on how worker agents operate — memory, workspaces, task handoffs.
