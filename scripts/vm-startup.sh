#!/bin/bash
# vm-startup.sh — Runs inside the marketplace VM at boot via cloud-init.
# Installs deps, starts dd-agent immediately, then sets up openclaw + ollama.
#
# Required env vars (set by cloud-init):
#   DD_AGENT_URL        — URL to download dd-agent binary
#   DD_OWNER            — Owner label (e.g. "devopsdefender")
#   DD_ENV              — Environment (staging/production)
#   DD_REGISTER_URL     — Fleet registration WebSocket URL
#   OPENCLAW_IMAGE      — Container image (e.g. ghcr.io/openclaw/openclaw:latest)
#   OPENROUTER_API_KEY  — API key for OpenClaw's LLM backend (staging)
#
# Optional env vars:
#   VLLM_MODEL          — If set, install NVIDIA drivers + vLLM and serve this model locally
set -euo pipefail

echo "dd-marketplace: starting VM setup"

# ── Install core packages ────────────────────────────────────────────────
apt-get update -q
apt-get install -y podman

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

# ── Start dd-agent FIRST (so health checks pass while rest installs) ─────
DD_OWNER="${DD_OWNER}" \
DD_ENV="${DD_ENV}" \
DD_REGISTER_URL="${DD_REGISTER_URL}" \
DD_BOOT_CMD=bash \
DD_BOOT_APP=shell \
nohup /usr/local/bin/dd-agent > /var/log/dd-agent.log 2>&1 &

echo "dd-marketplace: dd-agent started"

# ── Install ollama (fallback model) ──────────────────────────────────────
curl -fsSL -o /usr/local/bin/ollama https://ollama.com/download/ollama-linux-amd64
chmod +x /usr/local/bin/ollama

ollama serve &
sleep 3
ollama pull qwen2.5-coder:7b
echo "dd-marketplace: ollama ready (fallback: qwen2.5-coder:7b)"

# ── Local model inference (production with GPU) ──────────────────────────
if [ -n "${VLLM_MODEL:-}" ]; then
  echo "dd-marketplace: setting up vLLM with ${VLLM_MODEL}"

  apt-get install -y nvidia-driver-560 python3-pip
  pip3 install vllm --break-system-packages

  nohup vllm serve "${VLLM_MODEL}" \
    --tensor-parallel-size 1 \
    --gpu-memory-utilization 0.9 \
    --port 8000 \
    > /var/log/vllm.log 2>&1 &

  echo "dd-marketplace: waiting for vLLM to load model..."
  for i in $(seq 1 120); do
    curl -s http://localhost:8000/health >/dev/null 2>&1 && break
    sleep 5
  done
  echo "dd-marketplace: vLLM ready"
fi

# ── Write openclaw config ────────────────────────────────────────────────
mkdir -p /etc/openclaw

if [ -n "${VLLM_MODEL:-}" ]; then
  # Production: vLLM on H100 primary, ollama fallback
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
      "local": { "baseUrl": "http://localhost:8000/v1" },
      "ollama": { "baseUrl": "http://localhost:11434/v1" }
    }
  }
}
CONF
else
  # Staging: OpenRouter primary, ollama fallback
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
      "ollama": { "baseUrl": "http://localhost:11434/v1" }
    }
  }
}
CONF
fi

# ── Start openclaw container ─────────────────────────────────────────────
podman run -d --name openclaw \
  --network host \
  -v /etc/openclaw/openclaw.json:/home/node/.openclaw/openclaw.json:ro \
  -e OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
  "${OPENCLAW_IMAGE}"

echo "dd-marketplace: setup complete"
