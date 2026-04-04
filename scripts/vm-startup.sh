#!/bin/bash
# vm-startup.sh — Runs inside the marketplace VM at boot via cloud-init.
# Installs podman, starts dd-agent, deploys openclaw and optionally ollama
# via the local dd-agent API.
#
# Required env vars:
#   DD_AGENT_URL        — URL to download dd-agent binary
#   DD_OWNER            — Owner label
#   DD_ENV              — Environment (staging/production)
#   DD_REGISTER_URL     — Fleet registration WebSocket URL
#   OPENCLAW_IMAGE      — Container image (e.g. ghcr.io/openclaw/openclaw:latest)
#   OPENAI_API_KEY      — OpenAI API key
#
# Optional env vars:
#   OLLAMA_MODEL        — If set, deploy ollama container with this model
#   VM_GPU              — If set, install NVIDIA drivers for GPU access
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

# GPU support (production)
if [ -n "${VM_GPU:-}" ]; then
  apt-get install -y nvidia-driver-560 nvidia-container-toolkit
  nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
fi

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

# ── Deploy workloads via localhost API ───────────────────────────────────
(
  # Wait for agent
  for i in $(seq 1 30); do
    curl -fsS http://localhost:8080/health >/dev/null 2>&1 && break
    sleep 2
  done

  # Deploy ollama (if model specified)
  if [ -n "${OLLAMA_MODEL:-}" ]; then
    GPU_ENV=""
    if [ -n "${VM_GPU:-}" ]; then
      GPU_ENV=",\"NVIDIA_VISIBLE_DEVICES=all\""
    fi
    curl -sS -X POST http://localhost:8080/deploy \
      -H "Content-Type: application/json" \
      -d "{
        \"image\": \"docker.io/ollama/ollama\",
        \"app_name\": \"ollama\",
        \"env\": [\"OLLAMA_HOST=0.0.0.0\"${GPU_ENV}]
      }" && echo "ollama deployed" || echo "ollama deploy failed"

    # Wait for ollama, then pull model
    sleep 10
    for i in $(seq 1 30); do
      curl -s http://localhost:11434/api/tags >/dev/null 2>&1 && break
      sleep 2
    done
    curl -sS -X POST http://localhost:11434/api/pull -d "{\"name\":\"${OLLAMA_MODEL}\"}" || echo "model pull failed"
  fi

  # Deploy openclaw
  curl -sS -X POST http://localhost:8080/deploy \
    -H "Content-Type: application/json" \
    -d "{
      \"image\": \"${OPENCLAW_IMAGE}\",
      \"app_name\": \"openclaw\",
      \"env\": [\"OPENAI_API_KEY=${OPENAI_API_KEY:-}\"]
    }" && echo "openclaw deployed" || echo "openclaw deploy failed"
) &

echo "dd-marketplace: setup complete"
