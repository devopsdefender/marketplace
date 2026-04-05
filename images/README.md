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

## GPU Passthrough Verification

```bash
# Confirm H100 is bound to vfio-pci
lspci -nnk -s 0d:00.0
# Should show: Kernel driver in use: vfio-pci

# Confirm IOMMU groups
find /sys/kernel/iommu_groups/ -type l | sort -V
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
