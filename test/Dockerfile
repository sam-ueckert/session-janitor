# Session-janitor plugin test container
#
# Runs a minimal OpenClaw gateway with no channel integrations, loads the
# session-janitor plugin, and exposes the chat-completions API on port 18799.
# The test script exercises the plugin hooks by sending turns and asserting
# that before_agent_finalize triggers sidecar + trim correctly.
#
# Build:  docker build -t oc-janitor-test .   (from repo root)
# Run:    docker compose -f test/docker-compose.yml up --build

FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip jq curl procps inotify-tools \
    && rm -rf /var/lib/apt/lists/*

# Pin to the same openclaw version running on swabby-ts
ARG OPENCLAW_VERSION=2026.5.28
RUN npm install -g openclaw@${OPENCLAW_VERSION} --prefix /usr/local

RUN useradd -m -s /bin/bash janitor

USER janitor
RUN mkdir -p /home/janitor/.openclaw-test/agents/main/sessions \
             /home/janitor/.openclaw-test/agents/main/agent \
             /home/janitor/.openclaw-test/credentials \
             /home/janitor/.openclaw-test/logs \
             /home/janitor/.openclaw-test/memory \
             /home/janitor/.openclaw-test/extensions
USER root

# Copy the session-janitor repo into the image
COPY --chown=janitor:janitor . /home/janitor/session-janitor/

# Generate a static gateway token for tests
ENV OC_TEST_TOKEN=janitor-test-token-abc123
ENV OC_ANTHROPIC_KEY=${OC_ANTHROPIC_KEY:-}
ENV HOME=/home/janitor

COPY --chown=janitor:janitor test/openclaw.json /home/janitor/.openclaw-test/openclaw.json
COPY --chown=janitor:janitor test/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER janitor
WORKDIR /home/janitor

ENV PATH="/usr/local/bin:/usr/bin:/bin"
EXPOSE 18799

CMD ["/entrypoint.sh"]
