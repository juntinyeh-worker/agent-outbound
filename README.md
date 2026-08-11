# OpenAB + Kiro Telegram Bot (AWS sandbox)

Runs the unified [OpenAB](https://github.com/openabdev/openab) binary (which embeds
the Telegram webhook server) with **Kiro CLI** as the agent, on **ECS Fargate** in
your AWS account. Telegram requires a valid-TLS HTTPS webhook, so a **CloudFront**
distribution sits in front of an **ALB** to provide TLS via the default
`*.cloudfront.net` certificate — no custom domain required.

## Architecture

```
Telegram  ──HTTPS──▶  CloudFront (*.cloudfront.net, valid cert)
                          │  http-only origin
                          ▼
                        ALB (:80)  ──▶  ECS Fargate task
                                          openab:beta-kiro (:8080)
                                          ├─ TELEGRAM_BOT_TOKEN  (Secrets Manager)
                                          └─ KIRO_API_KEY        (Secrets Manager)
```

- **Engine:** Kiro CLI (ACP), zero-touch auth via `KIRO_API_KEY`. No Bedrock, no Gemini.
- **Secrets:** two Secrets Manager secrets, injected as env vars by ECS (task exec role
  can read only those two ARNs).
- **Task role:** intentionally has **no AWS permissions** — a Telegram-exposed agent
  should not get implicit account access. Attach a policy later if you want the agent
  to operate on AWS.

## Prerequisites

- AWS CLI configured for account `384612698411`, region `us-east-1` (Admin/deployer).
- `jq` installed.
- `~/.kiro/telegram_token` — Telegram bot token from @BotFather.
- `~/.kiro/my-kiro-worker1.key` — Kiro API key (enable API Keys in AWS Console → "Kiro",
  generate at kiro.dev).

## Deploy

```bash
# Restricted to your Telegram user ID (recommended). Get your ID from @userinfobot.
ALLOWED_USERS=123456789 ./deploy.sh

# Or open to everyone (NOT recommended for an agent with an API key):
./deploy.sh
```

The script creates the secrets, deploys the stack, then registers the Telegram webhook
and prints `getWebhookInfo`.

## Access control

- `ALLOWED_USERS` empty  → `TELEGRAM_ALLOW_ALL_USERS=true` (anyone who finds the bot can chat).
- `ALLOWED_USERS=<ids>`  → only those comma-separated Telegram numeric user IDs.

## Operate

```bash
# Tail agent logs
aws logs tail /ecs/openab-telegram-kiro --region us-east-1 --follow

# Force a new task (e.g. after changing the image)
aws ecs update-service --cluster openab-telegram-kiro-cluster \
  --service openab-telegram-kiro-svc --force-new-deployment --region us-east-1
```

## Tear down

```bash
./destroy.sh                    # deletes stack + webhook, keeps secrets
DELETE_SECRETS=true ./destroy.sh   # also deletes the two secrets
```

## Rough cost (sandbox, us-east-1)

| Resource | ~Monthly |
|---|---|
| ALB | ~$16 + LCU |
| Fargate (0.5 vCPU / 1 GB, 1 task) | ~$18 |
| CloudFront | pennies at low traffic |
| Secrets Manager (2) | ~$0.80 |
| CloudWatch Logs | usage-based |

Destroy when idle to avoid the ALB + Fargate baseline.

## Notes

- CloudFront uses managed policies **CachingDisabled** + **AllViewer** so POST bodies and
  the `X-Telegram-Bot-Api-Secret-Token` header are forwarded uncached to the origin.
- ALB health check hits `/health` on the container.
- CloudFront distribution creation/propagation is the slow part (~5–10 min).
