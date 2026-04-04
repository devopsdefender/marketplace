#!/bin/bash
# vm-startup.sh — Runs inside the marketplace VM at boot via cloud-init.
# Installs podman, starts dd-agent, runs openclaw with OpenRouter.
#
# Required env vars:
#   DD_AGENT_URL        — URL to download dd-agent binary
#   DD_OWNER            — Owner label
#   DD_ENV              — Environment (staging/production)
#   DD_REGISTER_URL     — Fleet registration WebSocket URL
#   OPENCLAW_IMAGE      — Container image (e.g. ghcr.io/openclaw/openclaw:latest)
#   OPENROUTER_API_KEY  — OpenRouter API key
set -euo pipefail

echo "dd-marketplace: starting VM setup"

# ── Install packages ─────────────────────────────────────────────────────
apt-get update -q
apt-get install -y podman

# TDX attestation modules (optional)
apt-get install -y "linux-modules-extra-$(uname -r)" 2>/dev/null || true
modprobe tdx_guest 2>/dev/null || true
modprobe tsm_report 2>/dev/null || true
mount -t configfs configfs /sys/kernel/config 2>/dev/null || true

# ── Install binaries ─────────────────────────────────────────────────────
curl -fsSL -o /usr/local/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

curl -fsSL -o /usr/local/bin/dd-agent "${DD_AGENT_URL}"
chmod +x /usr/local/bin/dd-agent

# ── Start dd-agent (health checks pass while openclaw pulls) ─────────────
DD_OWNER="${DD_OWNER}" \
DD_ENV="${DD_ENV}" \
DD_REGISTER_URL="${DD_REGISTER_URL}" \
DD_BOOT_CMD=bash \
DD_BOOT_APP=shell \
nohup /usr/local/bin/dd-agent > /var/log/dd-agent.log 2>&1 &

echo "dd-marketplace: dd-agent started"

# ── Write openclaw config ────────────────────────────────────────────────
mkdir -p /etc/openclaw
cat > /etc/openclaw/openclaw.json <<'CONF'
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "auth": { "mode": "token", "token": "dd-marketplace" },
    "controlUi": { "dangerouslyAllowHostHeaderOriginFallback": true }
  },
  "models": {
    "providers": {
      "openrouter": {
        "baseUrl": "https://openrouter.ai/api/v1",
        "models": [
          { "id": "openai/gpt-4o", "name": "GPT-4o", "api": "openai-responses" },
          { "id": "openai/gpt-4o-mini", "name": "GPT-4o Mini", "api": "openai-responses" },
          { "id": "anthropic/claude-sonnet-4", "name": "Claude Sonnet", "api": "openai-responses" }
        ]
      }
    }
  }
}
CONF

# ── Start openclaw ───────────────────────────────────────────────────────
# Writable state dir so openclaw can create identity/ etc.
mkdir -p /var/lib/openclaw
cp /etc/openclaw/openclaw.json /var/lib/openclaw/openclaw.json
chown -R 1000:1000 /var/lib/openclaw

podman run -d --name openclaw \
  --restart unless-stopped \
  --network host \
  -v /var/lib/openclaw:/home/node/.openclaw \
  -e OPENROUTER_API_KEY="${OPENROUTER_API_KEY}" \
  "${OPENCLAW_IMAGE}"

echo "dd-marketplace: setup complete"
