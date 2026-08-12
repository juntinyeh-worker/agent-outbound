# Strands Worker Agent + ACP Adapter + OpenAB
# Self-contained: runs OpenAB (Discord/Telegram) with Strands agent (tools, memory)
# No external AgentCore needed — everything in one container.

FROM public.ecr.aws/amazonlinux/amazonlinux:2023

# Install system dependencies
RUN dnf upgrade -y --security && \
    dnf install -y \
      python3.11 python3.11-pip \
      git \
      shadow-utils \
      tar gzip unzip curl \
    && dnf clean all && \
    alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1

# Install OpenAB binary
RUN curl -sL "https://github.com/openabdev/openab/releases/latest/download/openab-x86_64-unknown-linux-gnu.tar.gz" \
    | tar -xz -C /usr/local/bin/ openab && \
    chmod +x /usr/local/bin/openab

WORKDIR /app

# Install Python dependencies
COPY requirements.txt requirements.txt
RUN python3 -m pip install --no-cache-dir -r requirements.txt

# Environment
ENV AWS_REGION=us-east-1 \
    AWS_DEFAULT_REGION=us-east-1 \
    AGENT_WORKSPACE=/home/agent/workspace \
    AGENT_MEMORY_FILE=/home/agent/workspace/.agent_memory.json \
    PYTHONUNBUFFERED=1 \
    BEDROCK_MODEL_ID=us.anthropic.claude-sonnet-4-20250514-v1:0

# Create non-root user
RUN useradd -m -u 1000 -d /home/agent agent && \
    mkdir -p /home/agent/workspace /home/agent/.openab && \
    chown -R agent:agent /home/agent

USER agent

EXPOSE 8080

# Copy application code
COPY --chown=agent:agent . .

# Make ACP adapter executable
RUN chmod +x /app/strands_acp.py

# Default: run OpenAB with strands-acp as the agent
# Override CMD or mount a config.toml at /etc/openab/config.toml
CMD ["openab", "run", "-c", "/etc/openab/config.toml"]
