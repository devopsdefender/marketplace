# DD Marketplace

Run OpenClaw on confidential TDX hardware with a local fallback model and optional GPU inference.

## Architecture

```
Customer (browser)
  │ GitHub OAuth / password auth
  ↓
DD Agent (TDX VM on baremetal)
  ├── podman: openclaw + ollama (qwen2.5-coder:7b fallback)
  ├── vLLM (production only — Qwen3-Coder-Next on H100)
  ├── bash shell (web terminal for management)
  └── cloudflared tunnel (public hostname)
  │
  ↓ registers with
DD Fleet Dashboard (app-staging.devopsdefender.com)
```

## Environments

| Environment | Model Backend | GPU | VM Sizing |
|-------------|--------------|-----|-----------|
| **Staging** | OpenRouter (ChatGPT) + ollama fallback | None | 8GB / 4 vCPU / 80GB |
| **Production** | vLLM (Qwen3-Coder-Next on H100) + ollama fallback | H100 94GB (`0d:00.0`) | 64GB / 16 vCPU / 200GB |

## How it works

1. **CI builds** the openclaw Docker image (includes ollama + qwen2.5-coder:7b) and pushes to GHCR
2. **Deploy script** creates a TDX VM on baremetal via cloud-init
3. **VM boots**, installs podman, optionally installs vLLM + NVIDIA drivers (production)
4. **OpenClaw container** starts detached with model providers configured
5. **dd-agent** starts with `DD_BOOT_CMD=bash` — web terminal for management
6. **Agent registers** with the fleet dashboard, gets a Cloudflare Tunnel hostname

## App

Single container: `ghcr.io/devopsdefender/openclaw`

Includes:
- OpenClaw gateway
- Ollama with qwen2.5-coder:7b (fallback model, always available)
- Entrypoint starts ollama in background, then openclaw

## Deployment

Deploys automatically via GitHub Actions:
- **PR to main** → staging deploy
- **Push to main** → production deploy

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/vm-startup.sh` | Runs inside VM — installs podman, optionally vLLM, starts openclaw + dd-agent |
| `scripts/deploy-vm.sh` | Called by CI — creates disk, generates cloud-init, launches TDX VM |
| `scripts/dd-vm.sh` | Manual VM management (create/list/destroy) |

### VM sizing

| Variable | Default | Description |
|----------|---------|-------------|
| `VM_RAM` | 8192 | RAM in MB |
| `VM_VCPUS` | 4 | vCPU count |
| `VM_DISK` | 80 | Disk in GB |
| `VM_GPU` | (empty) | PCI address for GPU passthrough |
| `VLLM_MODEL` | (empty) | HuggingFace model ID for local inference |

## Skills

OpenClaw loads skills from `/var/lib/dd/shared/skills/`:

| Skill | File | Purpose |
|-------|------|---------|
| Capacity Manager | `capacity.md` | List/launch/monitor compute nodes |
| GCP Overflow | `gcp-capacity.md` | Overflow to GCP when local is full |
| Payments | `payments.md` | BTC payment processing |
| Local VMs | `local-vms.md` | Allocate KVM VMs on baremetal |

## Web terminal

Connect via `https://your-agent.devopsdefender.com/session/shell` for a VM shell. From there:

```bash
podman logs openclaw          # view openclaw output
podman exec -it openclaw sh   # shell into the container
nvidia-smi                    # check GPU (production)
curl localhost:8000/v1/models # check vLLM models (production)
```
