# Custom OpenAB image with Python runtime + package manager for additional runtimes
# Usage: docker build --build-arg BASE_IMAGE=ghcr.io/openabdev/openab-gemini:latest -t openab-custom .
ARG BASE_IMAGE=ghcr.io/openabdev/openab:latest
FROM ${BASE_IMAGE}

USER root

# Install Python + pip + common tools; keep apt lists for future installs
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

# Allow installing additional runtimes at runtime via apt
# Pre-cache the apt lists so `apt-get install` works without `apt-get update`
RUN apt-get update && apt-get clean

# Switch back to non-root user (node for most agents, agent for kiro)
ARG USERNAME=node
USER ${USERNAME}
