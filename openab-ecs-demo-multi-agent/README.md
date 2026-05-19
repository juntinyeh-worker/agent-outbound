# OpenAB Multi-Agent on ECS Fargate

Single bot, router + 3 backend agents on ECS Fargate with Service Connect for service discovery.

## Architecture

```
Human → Discord → Router (Fargate) → Backend Agents (Fargate, via Service Connect)
                                      ├── planner.openab.local:8080
                                      ├── developer.openab.local:8080
                                      └── reviewer.openab.local:8080
```

## Deploy

```bash
cp .env.example .env
vim .env          # fill in AWS region, bot token, API keys
./deploy.sh       # builds images, creates VPC/EFS/ECS, deploys 4 services
```

## What It Creates

| Resource | Purpose |
|----------|---------|
| VPC + private subnets + NAT | Network isolation, outbound internet |
| EFS | Persistent `/home` per agent |
| ECR repos (×2) | openab-gemini, openab-claude images |
| SSM Parameters | Secrets (bot token, API keys) |
| ECS Cluster + Service Connect | Service discovery (`*.openab.local`) |
| 4 Fargate services | router, planner, developer, reviewer |

## Service Discovery

Router finds backend agents via ECS Service Connect DNS:

```
http://planner.openab.local:8080/mcp
http://developer.openab.local:8080/mcp
http://reviewer.openab.local:8080/mcp
```

No hardcoded IPs — DNS resolves automatically within the cluster.

## Cost Estimate

| Component | Monthly |
|-----------|---------|
| Fargate (4 × 0.5 vCPU, 1–2GB) | ~$40–60 |
| NAT Gateway | ~$5–10 |
| EFS | ~$1 |
| ECR + SSM + Logs | ~$2 |
| **Total** | **~$50–75/month** |

## Operations

```bash
# View services
aws ecs list-services --cluster openab-multi-agent --region us-east-1

# Logs
aws logs tail /ecs/openab-router --region us-east-1 --follow

# Stop a backend agent (save cost)
aws ecs update-service --cluster openab-multi-agent --service openab-planner --desired-count 0 --region us-east-1

# Restart
aws ecs update-service --cluster openab-multi-agent --service openab-planner --desired-count 1 --region us-east-1

# Tear down everything
./destroy.sh
```

## vs EC2 Docker Compose Version

| | EC2 (openab-ec2-demo-multi-agent) | ECS (this) |
|---|---|---|
| Service discovery | Docker DNS (`http://planner:8080`) | CloudMap (`http://planner.openab.local:8080`) |
| Persistence | Docker volumes | EFS |
| Secrets | `.env` file | SSM Parameter Store |
| HA | None | Multi-AZ |
| Cost | ~$60/month (instance) | ~$50–75/month |
| Setup | 1 minute | ~5 minutes |
