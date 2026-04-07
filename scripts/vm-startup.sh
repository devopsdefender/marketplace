#!/bin/bash
# vm-startup.sh — Runs inside the marketplace VM at boot via cloud-init.
# Installs dd-agent + ollama, then `ollama launch openclaw --model gemma4`.
#
# Required env vars:
#   DD_AGENT_URL        — URL to download dd-agent binary
#   DD_OWNER            — Owner label
#   DD_ENV              — Environment (staging/production)
#   DD_REGISTER_URL     — Fleet registration WebSocket URL
#
# Optional:
#   OLLAMA_MODEL        — Ollama model (default: gemma4)
set -euo pipefail

OLLAMA_MODEL="${OLLAMA_MODEL:-gemma4}"

echo "dd-marketplace: starting VM setup"

# ── TDX attestation modules (optional) ──────────────────────────────────
apt-get update -q
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

# Install ollama
curl -fsSL https://ollama.com/install.sh | sh

# ── Start dd-agent with bash shell ───────────────────────────────────────
DD_OWNER="${DD_OWNER}" \
DD_ENV="${DD_ENV}" \
DD_REGISTER_URL="${DD_REGISTER_URL}" \
DD_BOOT_CMD=bash \
DD_BOOT_APP=shell \
nohup /usr/local/bin/dd-agent > /var/log/dd-agent.log 2>&1 &

# ── Launch openclaw on top of ollama gemma4 ─────────────────────────────
(
  # Wait for ollama service to be listening
  for i in $(seq 1 30); do
    curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1 && break
    sleep 2
  done

  # ollama pulls the model and launches openclaw wired to it
  nohup ollama launch openclaw --model "${OLLAMA_MODEL}" \
    > /var/log/openclaw.log 2>&1 &
  echo "ollama launch openclaw --model ${OLLAMA_MODEL} started"
) &

echo "dd-marketplace: setup complete"
