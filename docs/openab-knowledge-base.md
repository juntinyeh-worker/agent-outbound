# OpenAB Knowledge Base — Telegram + AgentCore Integration

## What is OpenAB?

OpenAB (Open Agent Broker) is a lightweight, secure, cloud-native ACP harness written in Rust. It bridges chat platforms to AI coding agents over JSON-RPC stdio.

- **GitHub:** https://github.com/openabdev/openab
- **License:** MIT
- **Stars:** 737+

## Supported Platforms

### First-class (built-in)
- **Discord** — native WebSocket gateway
- **Slack** — native Socket Mode

### Via Gateway Adapters
- Telegram, LINE, Feishu/Lark, Google Chat, WeCom, Microsoft Teams

## Supported Agents

| Agent | CLI Command | Notes |
|-------|-------------|-------|
| Kiro (default) | `kiro-cli acp` | Native ACP |
| Claude Code | `claude-agent-acp` | Via adapter |
| Codex | `codex-acp` | Via adapter |
| Gemini | `gemini --acp` | Native |
| OpenCode | `opencode acp` | Native |
| MiMo-Code | `mimo acp` | Native |
| Kimi Code | `kimi acp` | Native |
| Copilot CLI | `copilot --acp --stdio` | Native |
| Cursor | `cursor-agent acp` | Native |
| Hermes | `hermes-acp` | Native |
| Grok Build | `grok agent stdio` | Native |
| Devin | `devin acp` | Native |
| Native Agent | `openab-agent` | Built-in Rust |

## Telegram Integration

### Deployment Modes
1. **Unified Mode** (recommended) — Single OAB binary with embedded webhook server
2. **Standalone Gateway** — Separate gateway process, OAB connects via WebSocket

### Key Telegram Features
- Rich Messages (headings, tables, code blocks) via Bot API 10.1+
- Live streaming via `sendRichMessageDraft`
- Forum topics (auto-create in supergroups)
- Inbound files: images (resized), text files (up to 20MB), voice (with STT)
- Emoji reactions: 👀→🤔→🔥→👍
- Message limit: 4096 chars (32768 with Rich Messages)
- Deny-all default access control

### Telegram vs Discord
| Feature | Discord | Telegram |
|---------|---------|----------|
| Connection | WebSocket (outbound) | Webhook (needs public HTTPS) |
| Setup | Bot token only | Bot token + webhook URL + TLS |
| Message limit | 2000 chars | 4096 / 32768 with Rich Messages |
| Outbound files | ✅ | ❌ Not yet |
| Slash commands | ✅ | ❌ |
| No public URL needed | ✅ | ❌ |

## Bedrock AgentCore Runtime

### Overview
Run any coding agent remotely on Amazon Bedrock AgentCore instead of bundling it in the OAB container.

```
OAB (~50MB) → agentcore-bridge → WebSocket (SigV4) → AgentCore microVM → Agent
```

### Benefits
- No CLI in OAB image (~50MB vs ~500MB)
- True isolation (Firecracker microVM per session)
- Persistent workspace (/mnt/workspace, 14-day retention)
- Background execution (survives pod restarts)
- Pay per CPU-second

### Configuration
```toml
[agentcore]
runtime_arn = "arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/my-agent"
shell_command = "kiro-cli acp --trust-all-tools"  # or any ACP agent
```

## Strands Agents + Bedrock + OpenAB

### Integration Pattern
Strands Agents are HTTP-based (FastAPI + `/invocations`). To integrate with OpenAB's ACP stdio protocol, use a thin ACP wrapper:

```
OpenAB → agentcore-bridge → PTY shell in microVM → acp_wrapper.py → Strands Agent → Bedrock
```

### Key Points
- Strands uses `BedrockModel` to call Claude, Nova, etc.
- ACP wrapper is ~150 lines of Python that translates JSON-RPC ↔ Strands
- AgentCore runtime container must be ARM64
- Strands is framework-agnostic for models (supports Bedrock, Anthropic, OpenAI, etc.)

## AWS ECS Deployment (oabctl)

### oabctl
Purpose-built CLI for provisioning OpenAB on ECS Fargate.

```bash
oabctl bootstrap                    # one-time infra setup
oabctl create my-bot --auto-apply   # interactive wizard + deploy
```

### Manual ECS Deployment
For sandbox environments where oabctl can't run, use CloudFormation:
- ECS Cluster (Fargate + Fargate Spot)
- Task Execution Role (ECR pull + secrets)
- Task Role (cross-region sandbox-* admin + Bedrock + AgentCore)
- ECR Repository
- Security Group (outbound-all + inbound 8080 for webhook)
- CloudWatch Log Group

### Dual-Region Pattern
- **ECS_REGION**: Where ECS/ECR are deployed
- **SANDBOX_REGION**: Where tasks have admin access to `sandbox-*` resources

## Signal Protocol (libsignal)

### Conclusion
Integration of OpenAB with Signal IM is **not practical**:
- Signal has no official bot API
- libsignal is the crypto layer only (not a client/bot framework)
- Unofficial bridges (signal-cli) are fragile
- Signal intentionally blocks bots to protect user privacy
- AGPL-3.0 license creates derivative work obligations

**Recommendation:** Use platforms with official bot APIs (Discord, Slack, Telegram).
