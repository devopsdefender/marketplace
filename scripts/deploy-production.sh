#!/bin/bash
# deploy-production.sh — Create the production marketplace TDX VM with H100 GPU.
set -euo pipefail

SSH="ssh -i /tmp/deploy-key -o StrictHostKeyChecking=no ${SSH_USER}@${SSH_HOST}"
SCP="scp -i /tmp/deploy-key -o StrictHostKeyChecking=no"
REGISTER_HOST="app.${DD_DOMAIN}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

$SSH "test -f ${BASE_IMAGE} || sudo curl -fsSL -o ${BASE_IMAGE} ${BASE_IMAGE_URL}"

DISK="/var/lib/libvirt/images/${VM_NAME}.qcow2"
$SSH "sudo qemu-img create -f qcow2 -b ${BASE_IMAGE} -F qcow2 ${DISK} 200G"

cat > /tmp/user-data <<USERDATA
#cloud-config
write_files:
  - path: /opt/dd/startup.sh
    permissions: '0755'
    content: |
$(sed 's/^/      /' "${SCRIPT_DIR}/vm-startup-production.sh")

runcmd:
  - DD_AGENT_URL=${DD_AGENT_URL} DD_OWNER=devopsdefender DD_ENV=production DD_REGISTER_URL=wss://${REGISTER_HOST}/register OPENCLAW_IMAGE=${OPENCLAW_IMAGE} OPENAI_API_KEY=${OPENAI_API_KEY:-} OLLAMA_MODEL=${OLLAMA_MODEL} /opt/dd/startup.sh
USERDATA

cat > /tmp/meta-data <<METADATA
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
METADATA

SEED_ISO="/var/lib/libvirt/images/${VM_NAME}-seed.iso"
$SCP /tmp/user-data /tmp/meta-data "${SSH_USER}@${SSH_HOST}:/tmp/"
$SSH "cd /tmp && sudo genisoimage -output ${SEED_ISO} -volid cidata -joliet -rock user-data meta-data"

$SSH "sudo virt-install \
  --name ${VM_NAME} \
  --ram 65536 \
  --vcpus 16 \
  --machine q35 \
  --disk path=${DISK},format=qcow2 \
  --disk path=${SEED_ISO},device=cdrom \
  --os-variant ubuntu24.04 \
  --network bridge=virbr0 \
  --graphics none \
  --boot firmware=efi \
  --launchSecurity type=tdx \
  --host-device 0d:00.0 \
  --import \
  --noautoconsole"

echo "VM ${VM_NAME} created (production, H100 GPU)"
