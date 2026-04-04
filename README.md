# DD Marketplace

Run AI workloads on confidential TDX hardware. Marketplace agents run OpenClaw via podman with a web terminal for management.

## Architecture

```
Customer (browser)
  │ GitHub OAuth / password auth
  ↓
DD Agent (TDX VM on baremetal)
  ├── podman: openclaw container (AI orchestrator, OpenRouter API)
  ├── bash shell (web terminal for management)
  └── cloudflared tunnel (public hostname)
  │
  ↓ registers with
DD Fleet Dashboard (app-staging.devopsdefender.com)
```

## How it works

1. **CI builds** the OpenClaw Docker image and pushes to GHCR
2. **Deploy script** creates a TDX VM on the baremetal host via cloud-init
3. **VM boots**, installs podman, starts OpenClaw container detached
4. **dd-agent** starts with `DD_BOOT_CMD=bash` — web terminal gives a full VM shell
5. **Agent registers** with the fleet dashboard, gets a Cloudflare Tunnel hostname

Users connect via the dashboard terminal and can run `podman logs openclaw`, `podman exec -it openclaw sh`, `ps aux`, etc.

## Apps

| App | Image | Description |
|-----|-------|-------------|
| OpenClaw | `ghcr.io/devopsdefender/openclaw` | AI orchestrator with skills and OpenRouter API access |

## Deployment

Deploys automatically via GitHub Actions:
- **PR to main** → staging deploy
- **Push to main** → production deploy

### What happens on deploy

1. Build OpenClaw image, push to GHCR
2. SSH to baremetal host
3. Create TDX VM with cloud-init (`scripts/vm-startup.sh`)
4. VM installs podman, starts OpenClaw container, starts dd-agent with bash shell
5. Agent registers with fleet, gets Cloudflare tunnel

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/vm-startup.sh` | Runs inside the VM at boot — installs podman, configures OpenClaw, starts dd-agent |
| `scripts/deploy-vm.sh` | Called by CI — creates disk, generates cloud-init, launches TDX VM |
| `scripts/dd-vm.sh` | Manual VM management (create/list/destroy KVM VMs) |

### VM sizing

Set via environment variables in the deploy workflow:

| Variable | Default | Description |
|----------|---------|-------------|
| `VM_RAM` | 8192 | RAM in MB |
| `VM_VCPUS` | 4 | vCPU count |
| `VM_DISK` | 80 | Disk in GB |
| `VM_GPU` | (empty) | PCI address for GPU passthrough (e.g. `0d:00.0`) |

### Environment variables

| Var | Purpose |
|-----|---------|
| `DD_BOOT_CMD` | Shell command for dd-agent (default: `bash`) |
| `DD_REGISTER_URL` | Fleet registration WebSocket URL |
| `OPENCLAW_IMAGE` | Container image for OpenClaw |
| `OPENROUTER_API_KEY` | AI model access for OpenClaw |

## Skills

OpenClaw loads skills from `/var/lib/dd/shared/skills/`:

| Skill | File | Purpose |
|-------|------|---------|
| Capacity Manager | `capacity.md` | List/launch/monitor compute nodes |
| GCP Overflow | `gcp-capacity.md` | Overflow to GCP when local is full |
| Payments | `payments.md` | BTC payment processing |
| Local VMs | `local-vms.md` | Allocate KVM VMs on baremetal |

## Browser access

Open `https://your-agent.devopsdefender.com/session/shell` for a web terminal on the VM.

## Adding your own node

```bash
DD_OWNER=your-github-username \
DD_REGISTER_URL=wss://app-staging.devopsdefender.com/register \
DD_BOOT_CMD=bash \
dd-agent
```

The agent registers with the fleet, gets a Cloudflare tunnel, and appears in the dashboard.
