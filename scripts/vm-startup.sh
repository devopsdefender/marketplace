#!/bin/bash
# vm-startup.sh — Runs inside the marketplace VM at boot via cloud-init.
# Installs deps, configures openclaw, and starts dd-agent.
#
# Required env vars (set by cloud-init):
#   DD_AGENT_URL        — URL to download dd-agent binary
#   DD_OWNER            — Owner label (e.g. "devopsdefender")
#   DD_ENV              — Environment (staging/production)
#   DD_REGISTER_URL     — Fleet registration WebSocket URL
#   OPENCLAW_IMAGE      — Container image (e.g. ghcr.io/devopsdefender/openclaw:latest)
#   OPENROUTER_API_KEY  — API key for OpenClaw's LLM backend
set -euo pipefail

echo "dd-marketplace: starting VM setup"

# ── Install packages ─────────────────────────────────────────────────────
apt-get update -q
apt-get install -y podman tmux

# TDX attestation modules (optional, fails gracefully on non-TDX VMs)
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

# ── Configure OpenClaw ───────────────────────────────────────────────────
mkdir -p /etc/openclaw
cat > /etc/openclaw/openclaw.json <<'CONF'
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "dd-marketplace"
    },
    "controlUi": {
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
CONF

# ── Start dd-agent ───────────────────────────────────────────────────────
# Boot command: tmux session running openclaw via podman.
# When users connect via the dashboard terminal, they attach to this session.
BOOT_CMD="tmux new-session -s openclaw 'podman run --rm --name openclaw \
  -p 18789:18789 \
  -v /etc/openclaw/openclaw.json:/home/node/.openclaw/openclaw.json:ro \
  -e OPENROUTER_API_KEY=${OPENROUTER_API_KEY} \
  ${OPENCLAW_IMAGE}'"

DD_OWNER="${DD_OWNER}" \
DD_ENV="${DD_ENV}" \
DD_REGISTER_URL="${DD_REGISTER_URL}" \
DD_BOOT_CMD="${BOOT_CMD}" \
DD_BOOT_APP=openclaw \
nohup /usr/local/bin/dd-agent > /var/log/dd-agent.log 2>&1 &

echo "dd-marketplace: setup complete"
