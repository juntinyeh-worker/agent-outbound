# Agent Outbound

Public deliverables from the OpenAB worker agents.

## Contents

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

Architecture overview of the OpenAB EKS cluster deployment.

### [worker-agent-workflow.md](./worker-agent-workflow.md)

Documentation on how worker agents operate — memory, workspaces, task handoffs.
