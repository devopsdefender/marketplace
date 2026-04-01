# Local VM Provisioning

You manage small KVM virtual machines on the marketplace's baremetal hosts. These are cheaper than full agent VMs and good for lightweight workloads.

## Available baremetal hosts

| Host | IP | RAM | CPUs | Role |
|------|-----|-----|------|------|
| Staging | 57.130.10.246 | 64GB | 16 | Dev/test workloads |
| Production | 162.222.34.121 | 200GB | 48 | Customer workloads + GPU |

## VM sizes

| Size | vCPUs | RAM | Disk | Use case |
|------|-------|-----|------|----------|
| tiny | 1 | 2GB | 20GB | Simple services, signal-cli |
| small | 2 | 4GB | 40GB | Claude Code, API servers |
| medium | 4 | 8GB | 80GB | OpenClaw + tools |
| large | 8 | 16GB | 160GB | Multi-app workloads |

## How to allocate a VM

Use the `dd-vm.sh` script (installed at `/usr/local/bin/dd-vm.sh` on baremetal hosts):

```bash
# Create a small VM for a customer
dd-vm.sh create --name customer-123 --size small

# List all VMs
dd-vm.sh list

# Check VM status
dd-vm.sh status --name customer-123

# Destroy a VM
dd-vm.sh destroy --name customer-123
```

Each VM automatically:
1. Downloads dd-agent + cloudflared
2. Registers with the DD fleet via `DD_REGISTER_URL`
3. Appears in the fleet dashboard
4. Gets scraped by the scraper for health monitoring

## Capacity planning

Each baremetal host reserves resources for:
- The host dd-agent (1 vCPU, 2GB RAM)
- The primary workloads (OpenClaw, signal-cli, etc.)
- KVM overhead (~10%)

**Staging (64GB, 16 CPUs):**
- Available for VMs: ~50GB RAM, 12 CPUs
- Can run: ~12 small VMs or ~6 medium VMs

**Production (200GB, 48 CPUs):**
- Available for VMs: ~170GB RAM, 40 CPUs
- Can run: ~40 small VMs or ~20 medium VMs

## Pricing

| Size | BTC/hour |
|------|----------|
| tiny | 0.0003 |
| small | 0.0005 |
| medium | 0.001 |
| large | 0.002 |

Local VMs are the cheapest option — no cloud provider markup.
