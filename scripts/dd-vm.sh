#!/bin/bash
# dd-vm.sh — Create/list/destroy small KVM VMs on baremetal hosts.
# Each VM runs dd-agent and registers with the DD fleet.
set -euo pipefail

DD_VM_PREFIX="dd-vm"
DD_ENV="${DD_ENV:-staging}"
DD_REGISTER_URL="${DD_REGISTER_URL:-wss://app-staging.devopsdefender.com/register}"
DD_OWNER="${DD_OWNER:-devopsdefender}"
VM_IMAGE_DIR="/var/lib/libvirt/images"

# Size presets: name -> vcpus,ram_mb,disk_gb
declare -A SIZES=(
    [tiny]="1,2048,20"
    [small]="2,4096,40"
    [medium]="4,8192,80"
    [large]="8,16384,160"
)

usage() {
    cat <<EOF
Usage: dd-vm.sh <command> [options]

Commands:
  create  --name <name> --size <tiny|small|medium|large> [--env KEY=VALUE ...]
  list
  destroy --name <name>
  status  --name <name>

Sizes:
  tiny    1 vCPU,  2GB RAM,  20GB disk
  small   2 vCPU,  4GB RAM,  40GB disk
  medium  4 vCPU,  8GB RAM,  80GB disk
  large   8 vCPU, 16GB RAM, 160GB disk

Options:
  --env KEY=VALUE  Extra environment variable for dd-agent (repeatable)

Environment:
  DD_ENV           Environment (default: staging)
  DD_REGISTER_URL  Fleet registration URL
  DD_OWNER         Owner label (default: devopsdefender)
EOF
    exit 1
}

cmd_create() {
    local name="" size=""
    local -a extra_envs=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --size) size="$2"; shift 2 ;;
            --env)  extra_envs+=("$2"); shift 2 ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
    done

    [[ -z "$name" ]] && { echo "Error: --name required"; usage; }
    [[ -z "$size" ]] && { echo "Error: --size required"; usage; }
    [[ -z "${SIZES[$size]+x}" ]] && { echo "Error: unknown size '$size'. Use: tiny, small, medium, large"; exit 1; }

    local vm_name="${DD_VM_PREFIX}-${name}"
    IFS=',' read -r vcpus ram_mb disk_gb <<< "${SIZES[$size]}"

    echo "Creating VM: ${vm_name} (${size}: ${vcpus} vCPU, $((ram_mb / 1024))GB RAM, ${disk_gb}GB disk)"

    # Check if already exists
    if virsh dominfo "$vm_name" &>/dev/null; then
        echo "Error: VM '$vm_name' already exists. Use 'dd-vm.sh destroy --name $name' first."
        exit 1
    fi

    # Build env exports for the dd-agent start command
    local env_line="DD_OWNER=${DD_OWNER} DD_ENV=${DD_ENV} DD_REGISTER_URL=${DD_REGISTER_URL}"
    for e in "${extra_envs[@]}"; do
        env_line+=" ${e}"
    done

    # Generate cloud-init user data
    local userdata
    userdata=$(mktemp)
    cat > "$userdata" <<USERDATA
#cloud-config
runcmd:
  - curl -fsSL -o /usr/local/bin/dd-agent https://github.com/devopsdefender/dd/releases/latest/download/dd-agent && chmod +x /usr/local/bin/dd-agent
  - curl -fsSL -o /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && chmod +x /usr/local/bin/cloudflared
  - ${env_line} nohup /usr/local/bin/dd-agent > /var/log/dd-agent.log 2>&1 &
USERDATA

    # Create disk
    local disk_path="${VM_IMAGE_DIR}/${vm_name}.qcow2"
    qemu-img create -f qcow2 "$disk_path" "${disk_gb}G"

    # Launch VM
    virt-install \
        --name "$vm_name" \
        --ram "$ram_mb" \
        --vcpus "$vcpus" \
        --disk "path=${disk_path},format=qcow2" \
        --os-variant ubuntu24.04 \
        --network bridge=virbr0 \
        --graphics none \
        --console pty,target_type=serial \
        --cloud-init "user-data=${userdata}" \
        --noautoconsole

    rm -f "$userdata"
    echo "VM '${vm_name}' created. It will register with the fleet at ${DD_REGISTER_URL}"
}

cmd_list() {
    echo "DD VMs:"
    virsh list --all | grep "${DD_VM_PREFIX}-" || echo "  (none)"
}

cmd_destroy() {
    local name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
    done

    [[ -z "$name" ]] && { echo "Error: --name required"; usage; }

    local vm_name="${DD_VM_PREFIX}-${name}"
    echo "Destroying VM: ${vm_name}"

    virsh destroy "$vm_name" 2>/dev/null || true
    virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || true

    echo "VM '${vm_name}' destroyed."
}

cmd_status() {
    local name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
    done

    [[ -z "$name" ]] && { echo "Error: --name required"; usage; }

    local vm_name="${DD_VM_PREFIX}-${name}"
    virsh dominfo "$vm_name" 2>/dev/null || { echo "VM '${vm_name}' not found."; exit 1; }
}

# Main
[[ $# -lt 1 ]] && usage

case "$1" in
    create)  shift; cmd_create "$@" ;;
    list)    cmd_list ;;
    destroy) shift; cmd_destroy "$@" ;;
    status)  shift; cmd_status "$@" ;;
    *)       echo "Unknown command: $1"; usage ;;
esac
