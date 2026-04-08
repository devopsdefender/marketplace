#!/bin/bash
# vm-startup.sh — Runs inside the marketplace VM at boot via cloud-init.
# Installs podman + dd-agent, then POSTs the openclaw workload to dd-agent's
# local /deploy endpoint.
#
# The openclaw workload itself runs inside the vanilla ollama container
# image (see /opt/dd/openclaw-deploy.json). dd-agent's /deploy endpoint
# pulls the image, starts the container with --network host, then exec's
# the post_deploy commands inside it (apt install nodejs, ollama pull
# gemma4:e2b, ollama launch openclaw --config -y, openclaw gateway).
#
# Required env vars:
#   DD_AGENT_URL        — URL to download dd-agent binary
#   DD_OWNER            — Owner label
#   DD_ENV              — Environment (staging/production)
#   DD_REGISTER_URL     — Fleet registration WebSocket URL
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

# Enable podman socket for bollard (used by dd-agent's container::pull_and_run)
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

# ── Deploy openclaw via dd-agent /deploy ─────────────────────────────────
# Same /deploy endpoint any caller would hit; running it from cloud-init
# is just a convenience for first-boot. The payload is checked into
# apps/openclaw/deploy.json and dropped into the VM by deploy-vm.sh.
(
  for i in $(seq 1 30); do
    curl -fsS http://localhost:8080/health >/dev/null 2>&1 && break
    sleep 2
  done

  curl -fsS -X POST http://localhost:8080/deploy \
    -H "Content-Type: application/json" \
    --data @/opt/dd/openclaw-deploy.json \
    && echo "openclaw deploy submitted" \
    || echo "openclaw deploy submission failed"
) &

echo "dd-marketplace: setup complete"
