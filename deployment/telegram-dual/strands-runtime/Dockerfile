# Strands Agent Runtime for Amazon Bedrock AgentCore
# Platform: linux/arm64 (required by AgentCore)
FROM --platform=linux/arm64 ghcr.io/astral-sh/uv:python3.11-bookworm-slim

WORKDIR /app

# Copy dependency files first for layer caching
COPY pyproject.toml ./

# Install dependencies
RUN uv sync --frozen --no-cache 2>/dev/null || uv pip install --system \
    "strands-agents>=0.3.0" \
    "strands-agents-tools>=0.1.0" \
    "boto3>=1.35.0"

# Copy application code
COPY acp_wrapper.py ./
COPY healthcheck.py ./

# Environment defaults
ENV BEDROCK_MODEL_ID="us.anthropic.claude-sonnet-4-20250514" \
    AWS_REGION="us-east-1" \
    AGENT_NAME="strands-bedrock-agent" \
    AGENT_VERSION="0.1.0" \
    HEALTH_PORT="8080" \
    LOG_LEVEL="WARNING"

EXPOSE 8080

# Health server runs as main process; ACP wrapper is invoked via PTY shell
CMD ["python3", "/app/healthcheck.py"]
