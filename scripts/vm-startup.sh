#!/bin/bash
# vm-startup.sh — Runs inside the marketplace VM at boot via cloud-init.
# Installs deps, optionally starts vLLM for local inference, and starts dd-agent.
#
# Required env vars (set by cloud-init):
#   DD_AGENT_URL        — URL to download dd-agent binary
#   DD_OWNER            — Owner label (e.g. "devopsdefender")
#   DD_ENV              — Environment (staging/production)
#   DD_REGISTER_URL     — Fleet registration WebSocket URL
#   OPENCLAW_IMAGE      — Container image (e.g. ghcr.io/devopsdefender/openclaw:latest)
#   OPENROUTER_API_KEY  — API key for OpenClaw's LLM backend (staging)
#
# Optional env vars:
#   VLLM_MODEL          — If set, install NVIDIA drivers + vLLM and serve this model locally
set -euo pipefail

echo "dd-marketplace: starting VM setup"

# ── Install packages ─────────────────────────────────────────────────────
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

# ── Local model inference (production with GPU) ──────────────────────────
if [ -n "${VLLM_MODEL:-}" ]; then
  echo "dd-marketplace: setting up vLLM with ${VLLM_MODEL}"

  # Install NVIDIA drivers and Python
  apt-get install -y nvidia-driver-560 python3-pip
  pip3 install vllm --break-system-packages

  # Start vLLM
  nohup vllm serve "${VLLM_MODEL}" \
    --tensor-parallel-size 1 \
    --gpu-memory-utilization 0.9 \
    --port 8000 \
    > /var/log/vllm.log 2>&1 &

  # Wait for vLLM to be ready (model loading can take a few minutes)
  echo "dd-marketplace: waiting for vLLM to load model..."
  for i in $(seq 1 120); do
    curl -s http://localhost:8000/health >/dev/null 2>&1 && break
    sleep 5
  done
  echo "dd-marketplace: vLLM ready"
fi

# ── Start openclaw container (detached) ──────────────────────────────────
PODMAN_ARGS="-d --name openclaw -p 18789:18789"
PODMAN_ARGS="${PODMAN_ARGS} -e OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}"

# If vLLM is running, openclaw can reach it via host network
if [ -n "${VLLM_MODEL:-}" ]; then
  PODMAN_ARGS="${PODMAN_ARGS} --network host"
fi

podman run ${PODMAN_ARGS} "${OPENCLAW_IMAGE}"
echo "dd-marketplace: openclaw container started"

# ── Start dd-agent with a shell ──────────────────────────────────────────
DD_OWNER="${DD_OWNER}" \
DD_ENV="${DD_ENV}" \
DD_REGISTER_URL="${DD_REGISTER_URL}" \
DD_BOOT_CMD=bash \
DD_BOOT_APP=shell \
nohup /usr/local/bin/dd-agent > /var/log/dd-agent.log 2>&1 &

echo "dd-marketplace: setup complete"
