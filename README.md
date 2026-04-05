# DD Marketplace

Run OpenClaw on confidential TDX hardware with GPU inference via ollama.

## Architecture

```
Customer (browser)
  │ GitHub OAuth / password auth
  ↓
DD Agent (TDX VM on baremetal)
  ├── podman: openclaw (OpenAI + local models)
  ├── podman: ollama with qwen2.5-coder:7b (production only)
  ├── bash shell (web terminal)
  └── cloudflared tunnel (public hostname)
  │
  ↓ registers with
DD Fleet Dashboard (app.devopsdefender.com)
```

## Environments

| Environment | Models | GPU | VM Sizing |
|-------------|--------|-----|-----------|
| **Staging** | OpenAI (GPT-5.4, GPT-5.4 Mini, GPT-4o) | None | 8GB / 4 vCPU / 80GB |
| **Production** | Ollama (qwen2.5-coder:7b on H100) + OpenAI fallback | H100 94GB | 64GB / 16 vCPU / 200GB |

## Deployment

Deploys automatically via GitHub Actions:
- **PR to main** → staging deploy
- **Push to main** → production deploy

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/deploy-staging.sh` | Creates staging TDX VM via cloud-init |
| `scripts/deploy-production.sh` | Creates production TDX VM with H100 passthrough |
| `scripts/vm-startup-staging.sh` | Runs inside staging VM — installs podman, starts dd-agent, deploys + configures openclaw |
| `scripts/vm-startup-production.sh` | Same + GPU drivers, ollama deployment, model pull |

### Remote access

dd-agent exposes a `POST /exec` endpoint for running commands inside VMs from the baremetal host:

```bash
curl -s -X POST http://${VM_IP}:8080/exec \
  -H "Authorization: Bearer $DD_PASSWORD" \
  -H "Content-Type: application/json" \
  -d '{"cmd":["podman","ps","-a"]}'
```

## Baremetal Host Setup

See [images/README.md](images/README.md) for hardware requirements, BIOS settings, kernel parameters, and VFIO configuration needed to run TDX VMs with GPU passthrough.

## Sealed VM Images

The `images/` directory contains mkosi definitions for building reproducible, dm-verity protected base images. See [images/README.md](images/README.md) for details.
