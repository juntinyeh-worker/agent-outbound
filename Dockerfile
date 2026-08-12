# Strands Worker Agent — AgentCore Runtime Container
# Runs on AWS Bedrock AgentCore in a Firecracker microVM.
# OpenAB connects via agentcore-acp bridge (WebSocket → HTTP :8080).

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

WORKDIR /app

# Install Python dependencies
COPY requirements.txt requirements.txt
RUN python3 -m pip install --no-cache-dir -r requirements.txt

# OpenTelemetry for observability (optional but recommended)
RUN python3 -m pip install --no-cache-dir aws-opentelemetry-distro>=0.10.1

# Environment
ENV AWS_REGION=us-east-1 \
    AWS_DEFAULT_REGION=us-east-1 \
    AGENT_WORKSPACE=/home/agent/workspace \
    AGENT_MEMORY_FILE=/home/agent/workspace/.agent_memory.json \
    PYTHONUNBUFFERED=1

# Create non-root user
RUN useradd -m -u 1000 -d /home/agent agent && \
    mkdir -p /home/agent/workspace && \
    chown -R agent:agent /home/agent

USER agent

# Expose AgentCore HTTP port
EXPOSE 8080

# Copy application code
COPY --chown=agent:agent . .

# Entrypoint: run with OpenTelemetry instrumentation
CMD ["opentelemetry-instrument", "python3", "-m", "main"]
