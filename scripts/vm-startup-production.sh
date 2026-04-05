#!/bin/bash
# vm-startup-production.sh — Marketplace production VM startup.
# Starts dd-agent, deploys ollama (H100) + openclaw, configures models.
set -euo pipefail

echo "dd-marketplace: starting production setup"

# ── Install packages ─────────────────────────────────────────────────────
apt-get update -q
apt-get install -y podman
apt-get install -y "linux-modules-extra-$(uname -r)" "linux-headers-$(uname -r)" 2>/dev/null || true
modprobe tdx_guest 2>/dev/null || true
modprobe tsm_report 2>/dev/null || true
mount -t configfs configfs /sys/kernel/config 2>/dev/null || true
systemctl enable --now podman.socket

# ── GPU setup ────────────────────────────────────────────────────────────
# NVIDIA container toolkit repo
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
  | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
# CUDA repo (has nvidia-driver-560)
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
  -o /tmp/cuda-keyring.deb
dpkg -i /tmp/cuda-keyring.deb
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nvidia-driver-560 nvidia-container-toolkit
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

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

# ── Deploy + configure workloads via API ─────────────────────────────────
(
  for i in $(seq 1 30); do
    curl -fsS http://localhost:8080/health >/dev/null 2>&1 && break
    sleep 2
  done

  # Deploy ollama with GPU
  curl -sS -X POST http://localhost:8080/deploy \
    -H "Content-Type: application/json" \
    -d '{
      "image": "docker.io/ollama/ollama",
      "app_name": "ollama",
      "env": ["OLLAMA_HOST=0.0.0.0", "NVIDIA_VISIBLE_DEVICES=all"]
    }' && echo "ollama deployed" || echo "ollama deploy failed"

  # Wait for ollama, pull model
  sleep 10
  for i in $(seq 1 30); do
    curl -s http://localhost:11434/api/tags >/dev/null 2>&1 && break
    sleep 2
  done
  curl -sS -X POST http://localhost:11434/api/pull \
    -d "{\"name\":\"${OLLAMA_MODEL}\"}" || echo "model pull failed"

  # Deploy openclaw
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

  # Configure openclaw
  podman exec openclaw openclaw config set gateway.mode local
  podman exec openclaw openclaw config set gateway.bind lan
  podman exec openclaw openclaw config set gateway.auth.mode token
  podman exec openclaw openclaw config set gateway.auth.token dd-marketplace
  podman exec openclaw openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true

  # Set ollama (primary) + OpenAI (fallback) models
  podman exec openclaw bash -c 'cat > /tmp/batch.json <<BEOF
[
  {"path": "models.providers.ollama.baseUrl", "value": "http://localhost:11434/v1"},
  {"path": "models.providers.ollama.models", "value": [
    {"id": "'"${OLLAMA_MODEL}"'", "name": "'"${OLLAMA_MODEL}"' (local GPU)", "api": "ollama"}
  ]},
  {"path": "models.providers.openai.baseUrl", "value": "https://api.openai.com/v1"},
  {"path": "models.providers.openai.models", "value": [
    {"id": "gpt-5.4", "name": "GPT-5.4", "api": "openai-responses"},
    {"id": "gpt-5.4-mini", "name": "GPT-5.4 Mini", "api": "openai-responses"}
  ]}
]
BEOF
openclaw config set --batch-file /tmp/batch.json'

  podman restart openclaw
  echo "openclaw configured and restarted"
) &

echo "dd-marketplace: production setup complete"
