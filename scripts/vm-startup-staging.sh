#!/bin/bash
# vm-startup-staging.sh — Marketplace staging VM startup.
# Starts dd-agent, deploys openclaw, configures OpenAI models.
set -euo pipefail

echo "dd-marketplace: starting staging setup"

# ── Install packages ─────────────────────────────────────────────────────
apt-get update -q
apt-get install -y podman
apt-get install -y "linux-modules-extra-$(uname -r)" 2>/dev/null || true
modprobe tdx_guest 2>/dev/null || true
modprobe tsm_report 2>/dev/null || true
mount -t configfs configfs /sys/kernel/config 2>/dev/null || true
systemctl enable --now podman.socket

# ── Install binaries ─────────────────────────────────────────────────────
curl -fsSL -o /usr/local/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

curl -fsSL -o /usr/local/bin/dd-agent "${DD_AGENT_URL}"
chmod +x /usr/local/bin/dd-agent

# ── Start dd-agent ───────────────────────────────────────────────────────
DD_OWNER="${DD_OWNER}" \
DD_ENV="${DD_ENV}" \
DD_REGISTER_URL="${DD_REGISTER_URL}" \
DD_PASSWORD="${DD_PASSWORD}" \
DD_BOOT_CMD=bash \
DD_BOOT_APP=shell \
nohup /usr/local/bin/dd-agent > /var/log/dd-agent.log 2>&1 &

# ── Deploy + configure openclaw via API ──────────────────────────────────
(
  for i in $(seq 1 30); do
    curl -fsS http://localhost:8080/health >/dev/null 2>&1 && break
    sleep 2
  done

  # Deploy openclaw container
  curl -sS -X POST http://localhost:8080/deploy \
    -H "Content-Type: application/json" \
    -d "{
      \"image\": \"${OPENCLAW_IMAGE}\",
      \"app_name\": \"openclaw\",
      \"env\": [\"OPENAI_API_KEY=${OPENAI_API_KEY:-}\"]
    }" && echo "openclaw deployed" || echo "openclaw deploy failed"

  # Wait for openclaw container to be running
  echo "waiting for openclaw container..."
  for i in $(seq 1 60); do
    podman exec openclaw echo ready >/dev/null 2>&1 && break
    sleep 5
  done

  # Configure openclaw via config set commands
  podman exec openclaw openclaw config set gateway.mode local
  podman exec openclaw openclaw config set gateway.bind lan
  podman exec openclaw openclaw config set gateway.auth.mode token
  podman exec openclaw openclaw config set gateway.auth.token dd-marketplace
  podman exec openclaw openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true

  # Set OpenAI models via batch
  podman exec openclaw bash -c 'cat > /tmp/batch.json <<BEOF
[
  {"path": "models.providers.openai.baseUrl", "value": "https://api.openai.com/v1"},
  {"path": "models.providers.openai.models", "value": [
    {"id": "gpt-5.4", "name": "GPT-5.4", "api": "openai-responses"},
    {"id": "gpt-5.4-mini", "name": "GPT-5.4 Mini", "api": "openai-responses"},
    {"id": "gpt-4o", "name": "GPT-4o", "api": "openai-responses"}
  ]}
]
BEOF
openclaw config set --batch-file /tmp/batch.json'

  # Restart to apply config
  podman restart openclaw
  echo "openclaw configured and restarted"
) &

echo "dd-marketplace: staging setup complete"
