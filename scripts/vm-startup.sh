#!/bin/bash
# vm-startup.sh — Runs inside the marketplace VM at boot via cloud-init.
# Installs podman, starts dd-agent, deploys openclaw via the local API.
#
# Required env vars:
#   DD_AGENT_URL        — URL to download dd-agent binary
#   DD_OWNER            — Owner label
#   DD_ENV              — Environment (staging/production)
#   DD_REGISTER_URL     — Fleet registration WebSocket URL
#   OPENCLAW_IMAGE      — Container image (e.g. ghcr.io/openclaw/openclaw:latest)
#   OPENAI_API_KEY      — OpenAI API key
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

# Enable podman socket for bollard
systemctl enable --now podman.socket

# ── Install binaries ─────────────────────────────────────────────────────
curl -fsSL -o /usr/local/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

curl -fsSL -o /usr/local/bin/dd-agent "${DD_AGENT_URL}"
chmod +x /usr/local/bin/dd-agent

# ── Start dd-agent with bash shell ───────────────────────────────────────
DD_OWNER="${DD_OWNER}" \
DD_ENV="${DD_ENV}" \
DD_REGISTER_URL="${DD_REGISTER_URL}" \
DD_BOOT_CMD=bash \
DD_BOOT_APP=shell \
nohup /usr/local/bin/dd-agent > /var/log/dd-agent.log 2>&1 &

# ── Deploy openclaw via localhost API ────────────────────────────────────
(
  for i in $(seq 1 30); do
    curl -fsS http://localhost:8080/health >/dev/null 2>&1 && break
    sleep 2
  done
  curl -sS -X POST http://localhost:8080/deploy \
    -H "Content-Type: application/json" \
    -d "{
      \"image\": \"${OPENCLAW_IMAGE}\",
      \"app_name\": \"openclaw\",
      \"env\": [\"OPENAI_API_KEY=${OPENAI_API_KEY}\"]
    }" && echo "openclaw deployed" || echo "openclaw deploy failed"
) &

echo "dd-marketplace: setup complete"
