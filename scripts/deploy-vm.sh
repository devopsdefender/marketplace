#!/bin/bash
# deploy-vm.sh — Create a marketplace TDX VM on the baremetal host.
# Called by CI workflows. Expects SSH access to the host.
#
# Required env vars:
#   SSH_HOST, SSH_USER  — Baremetal host SSH target
#   VM_NAME             — VM name (e.g. dd-vm-staging)
#   BASE_IMAGE          — Path to base cloud image on host
#   BASE_IMAGE_URL      — URL to download base image if missing
#   DD_AGENT_URL        — dd-agent binary download URL
#   DD_ENV              — staging or production
#   DD_DOMAIN           — Domain (e.g. devopsdefender.com)
#   OPENCLAW_IMAGE      — Container image for openclaw
#   OPENROUTER_API_KEY  — OpenClaw LLM API key
#
# Optional env vars:
#   VM_RAM              — RAM in MB (default: 8192)
#   VM_VCPUS            — vCPU count (default: 4)
#   VM_DISK             — Disk in GB (default: 80)
#   VM_GPU              — PCI address for GPU passthrough (e.g. "0d:00.0"), empty = no GPU
set -euo pipefail

VM_RAM="${VM_RAM:-8192}"
VM_VCPUS="${VM_VCPUS:-4}"
VM_DISK="${VM_DISK:-80}"
VM_GPU="${VM_GPU:-}"

SSH="ssh -i /tmp/deploy-key -o StrictHostKeyChecking=no ${SSH_USER}@${SSH_HOST}"
SCP="scp -i /tmp/deploy-key -o StrictHostKeyChecking=no"

REGISTER_HOST="${DD_ENV_PREFIX:-app-staging}.${DD_DOMAIN}"
if [ "${DD_ENV}" = "production" ]; then
  REGISTER_HOST="app.${DD_DOMAIN}"
fi

# ── Ensure base image ────────────────────────────────────────────────────
$SSH "test -f ${BASE_IMAGE} || sudo curl -fsSL -o ${BASE_IMAGE} ${BASE_IMAGE_URL}"

# ── Create disk ──────────────────────────────────────────────────────────
DISK="/var/lib/libvirt/images/${VM_NAME}.qcow2"
$SSH "sudo qemu-img create -f qcow2 -b ${BASE_IMAGE} -F qcow2 ${DISK} ${VM_DISK}G"

# ── Generate cloud-init ──────────────────────────────────────────────────
# The startup script is fetched from the repo and run with env vars.
# We write it inline here since the VM can't reach the repo at boot.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cat > /tmp/user-data <<USERDATA
#cloud-config
write_files:
  - path: /opt/dd/startup.sh
    permissions: '0755'
    content: |
$(sed 's/^/      /' "${SCRIPT_DIR}/vm-startup.sh")

runcmd:
  - DD_AGENT_URL=${DD_AGENT_URL} DD_OWNER=devopsdefender DD_ENV=${DD_ENV} DD_REGISTER_URL=wss://${REGISTER_HOST}/register OPENCLAW_IMAGE=${OPENCLAW_IMAGE} OPENAI_API_KEY=${OPENAI_API_KEY:-} /opt/dd/startup.sh
USERDATA

cat > /tmp/meta-data <<METADATA
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
METADATA

# ── Build cloud-init ISO and launch VM ───────────────────────────────────
SEED_ISO="/var/lib/libvirt/images/${VM_NAME}-seed.iso"
$SCP /tmp/user-data /tmp/meta-data "${SSH_USER}@${SSH_HOST}:/tmp/"
$SSH "cd /tmp && sudo genisoimage -output ${SEED_ISO} -volid cidata -joliet -rock user-data meta-data"

GPU_FLAG=""
if [ -n "${VM_GPU}" ]; then
  GPU_FLAG="--host-device ${VM_GPU}"
fi

$SSH "sudo virt-install \
  --name ${VM_NAME} \
  --ram ${VM_RAM} \
  --vcpus ${VM_VCPUS} \
  --machine q35 \
  --disk path=${DISK},format=qcow2 \
  --disk path=${SEED_ISO},device=cdrom \
  --os-variant ubuntu24.04 \
  --network bridge=virbr0 \
  --graphics none \
  --boot firmware=efi \
  --launchSecurity type=tdx \
  ${GPU_FLAG} \
  --import \
  --noautoconsole"

echo "VM ${VM_NAME} created"
