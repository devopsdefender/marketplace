# Baremetal Host Requirements

Hardware and configuration required to run marketplace TDX VMs with GPU passthrough.

## Hardware

- **CPU**: Intel Xeon with TDX support (e.g., Xeon Gold 6526Y / Emerald Rapids or newer)
- **GPU**: NVIDIA H100 (or compatible) for production inference
- **RAM**: 256GB+ recommended (64GB reserved for production VM, 8GB for staging)

## BIOS/UEFI Settings

Enable the following in BIOS:

| Setting | Location | Notes |
|---------|----------|-------|
| **Intel TDX** | CPU / Advanced | Required for confidential VMs |
| **Intel VT-x** | CPU / Advanced | Hardware virtualization |
| **Intel VT-d** | CPU / Advanced | IOMMU for GPU passthrough |
| **TME / MKTME** | CPU / Advanced | Total Memory Encryption — required by TDX |
| **UEFI Secure Boot** | Boot | Optional but recommended for attestation chain |
| **SR-IOV** | PCI / Advanced | If using multiple GPU partitions (optional) |

## Kernel Parameters

Required in `/etc/default/grub` (`GRUB_CMDLINE_LINUX_DEFAULT`):

```
kvm_intel.tdx=1 intel_iommu=on vfio-pci.ids=10de:2321
```

- `kvm_intel.tdx=1` — enable TDX in KVM
- `intel_iommu=on` — enable IOMMU for VFIO GPU passthrough
- `vfio-pci.ids=10de:2321` — bind H100 to vfio-pci at boot (use `lspci -nn` to find your device ID)

After editing, run `sudo update-grub && reboot`.

## Host Packages

```bash
apt-get install -y \
  qemu-kvm libvirt-daemon-system virtinst \
  genisoimage cloud-image-utils \
  ovmf
```

## VFIO DMA Entry Limit

GPU passthrough with large VMs (64GB+) requires raising the VFIO DMA mapping limit. The default (262144) only covers ~1GB at 4KB page granularity.

```bash
# Persist across reboots
echo "options vfio_iommu_type1 dma_entry_limit=16777216" | sudo tee /etc/modprobe.d/vfio-dma.conf

# Apply immediately (without reboot)
echo 16777216 | sudo tee /sys/module/vfio_iommu_type1/parameters/dma_entry_limit
```

## GPU Confidential Computing (CC) Mode — One-Time Setup

NVIDIA H100 must have CC mode enabled for GPU compute inside TDX VMs. Without CC mode, CUDA reports 0 devices even though the driver loads and `/dev/nvidia0` exists.

**VBIOS requirement**: >= 96.00.5E.00.00 (check with `nvidia-smi -q | grep VBIOS` on host)

### Install GPU admin tools

```bash
git clone https://github.com/NVIDIA/gpu-admin-tools.git /opt/gpu-admin-tools
pip3 install --break-system-packages nvidia-gpu-admin-tools
```

### Enable CC mode

```bash
# 1. Stop any VM using the GPU
sudo virsh destroy dd-vm-production

# 2. Unbind from vfio, bind to nvidia temporarily
echo 0000:0d:00.0 | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind
sudo modprobe nvidia
echo 0000:0d:00.0 | sudo tee /sys/bus/pci/drivers_probe

# 3. Disable PPCIe first (required before CC-On)
sudo python3 /opt/gpu-admin-tools/nvidia_gpu_tools.py \
  --gpu-bdf=0000:0d:00.0 \
  --set-ppcie-mode=off \
  --reset-after-ppcie-mode-switch

# 4. Enable CC-On
sudo python3 /opt/gpu-admin-tools/nvidia_gpu_tools.py \
  --gpu-bdf=0000:0d:00.0 \
  --set-cc-mode=on \
  --reset-after-cc-mode-switch

# 5. Verify
sudo python3 /opt/gpu-admin-tools/nvidia_gpu_tools.py \
  --gpu-bdf=0000:0d:00.0 --query-cc-mode
# Should show: CC mode is on

# 6. Unbind nvidia, detach for VM use
sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia
virsh nodedev-detach pci_0000_0d_00_0
```

After CC-On, `nvidia-smi` on the host will show "No devices found" — this is expected. The GPU is exclusively for confidential VMs.

### Query CC mode without nvidia driver

```bash
sudo python3 /opt/gpu-admin-tools/nvidia_gpu_tools.py \
  --gpu-bdf=0000:0d:00.0 --query-cc-mode
```

## Guest NVIDIA Driver (inside TDX VM)

Standard Ubuntu pre-built nvidia modules (`linux-modules-nvidia-*`) do **not** support CC mode. You must use the CUDA repo's `nvidia-driver-570-open` (DKMS) which has CC support.

### What works

```bash
# LKCA modprobe hook — loads crypto modules before nvidia (required for CC attestation)
cat > /etc/modprobe.d/nvidia-lkca.conf <<'EOF'
install nvidia /sbin/modprobe ecdsa_generic; /sbin/modprobe ecdh; /sbin/modprobe --ignore-install nvidia
EOF

# Install from CUDA repo (not Ubuntu repo)
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
  -o /tmp/cuda-keyring.deb
dpkg -i /tmp/cuda-keyring.deb
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-driver-570-open

# Load driver (LKCA hook triggers ecdsa/ecdh automatically)
modprobe nvidia

# Set GPU ready state (required for CC before any compute)
nvidia-persistenced --uvm-persistence-mode || true
nvidia-smi conf-compute -srs 1

# Verify
nvidia-smi  # Should show H100 with ~94GB VRAM
```

### What doesn't work (and why)

| Approach | Result | Why |
|----------|--------|-----|
| `linux-modules-nvidia-570-server-open` (Ubuntu pre-built) | Driver loads, NVML returns 0 devices | No CC support in pre-built modules |
| `linux-modules-nvidia-580-server-open` (Ubuntu pre-built) | "does not include required GPU" | H100 NVL (10de:2321) not in open module device list |
| `linux-modules-nvidia-580-server` (proprietary pre-built) | Driver loads, NVML 0 devices | No CC support |
| `nvidia-driver-560` (CUDA repo DKMS) | Secure Boot rejects unsigned module | DKMS-built modules aren't signed for Secure Boot |
| CC-Off on host | CUDA reports 0 devices in TDX VM | GPU refuses compute without CC in confidential environment |
| CC-DevTools on host | Driver loads, `/dev/nvidia0` exists, 0 devices | NVML/CUDA can't enumerate without full CC |
| `OLLAMA_LLM_LIBRARY=cuda_v12` | Still 0 devices | CUDA driver API itself can't see GPU, not just NVML |

### Reference

Based on [Canonical TDX + NVIDIA H100 setup](https://github.com/canonical/tdx) (`gpu-cc/h100/setup-gpus.sh` and `setup-tdx-guest.sh`).

## GPU Passthrough Verification

```bash
# Confirm H100 is bound to vfio-pci
lspci -nnk -s 0d:00.0
# Should show: Kernel driver in use: vfio-pci

# Confirm IOMMU groups
find /sys/kernel/iommu_groups/ -type l | sort -V

# Query CC mode (doesn't need nvidia driver)
sudo python3 /opt/gpu-admin-tools/nvidia_gpu_tools.py \
  --gpu-bdf=0000:0d:00.0 --query-cc-mode
```

## TDX Verification

```bash
# Check TDX is enabled in KVM
dmesg | grep -i tdx
# Should show: TDX initialized

# Test a TDX VM
sudo virt-install --name tdx-test --ram 2048 --vcpus 2 \
  --disk none --boot firmware=efi --launchSecurity type=tdx \
  --import --noautoconsole
sudo virsh destroy tdx-test && sudo virsh undefine tdx-test
```

## Sealed VM Images (mkosi)

The `mkosi.conf` in this directory builds a reproducible, dm-verity protected Ubuntu 24.04 base image. The roothash is measured into the TDX attestation quote, making the VM contents remotely verifiable.

```bash
# Build the sealed image (requires mkosi)
sudo mkosi -f
```

Output: `dd-marketplace.raw` — a GPT disk with systemd-boot, dm-verity, and dd-agent as the main service.
