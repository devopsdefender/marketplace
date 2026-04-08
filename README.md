# DD Marketplace

Run OpenClaw on confidential TDX hardware against a local CPU-served Gemma model.

## Architecture

```
Customer (browser)
  │ GitHub OAuth / password auth
  ↓
DD Agent (TDX VM on baremetal)
  ├── podman: docker.io/ollama/ollama (vanilla, pinned tag)
  │     └─ inside: ollama serve (gemma4:e2b) + openclaw gateway
  ├── bash shell (web terminal for management)
  └── cloudflared tunnel (public hostname)
  │
  ↓ registers with
DD Fleet Dashboard (app-staging.devopsdefender.com)
```

The marketplace VM boots to a generic state — podman + dd-agent — with no
workload-specific code in cloud-init. openclaw is then installed via dd-agent's
standard `POST /deploy` endpoint, against the vanilla `ollama/ollama` image. The
deploy spec lives at `apps/openclaw/deploy.json`; dd-agent pulls the image, starts
the container with `--network host`, then exec's the `post_deploy` commands inside
it (install nodejs, `ollama pull gemma4:e2b`, `ollama launch openclaw --config -y
--model gemma4:e2b`, `openclaw gateway --force`).

This keeps the attestation boundary at the container image hash: anything inside
the running container is bounded by a known-pristine ollama image.

## Environments

| Environment | Model | GPU | VM Sizing |
|-------------|-------|-----|-----------|
| **Staging** | gemma4:e2b (CPU) | None | 24GB / 16 vCPU / 80GB |
| **Production** | gemma4:e2b (CPU) | None | 32GB / 16 vCPU / 120GB |

CPU inference of gemma4:e2b runs ~5–15 tok/s on modern x86 with AVX2.

## How it works

1. **CI** (`production-deploy.yml` / `staging-deploy.yml`) creates a TDX VM on the
   baremetal host via `scripts/deploy-vm.sh`.
2. **VM boots** under cloud-init: `vm-startup.sh` installs podman, dd-agent, and
   cloudflared, then starts dd-agent.
3. **Cloud-init runcmd** waits for `localhost:8080/health` and POSTs
   `apps/openclaw/deploy.json` to `localhost:8080/deploy`.
4. **dd-agent** pulls `docker.io/ollama/ollama@sha256:87d71eb5…` (the
   `0.20.3` index digest, pinned for attestation), starts it with `--network
   host`, then runs the `post_deploy` exec sequence inside the container to
   install nodejs, pull `gemma4:e2b`, configure openclaw, and start the gateway
   daemon.
5. **dd-agent registers** with the fleet dashboard and gets a Cloudflare Tunnel
   hostname.

## Workload deploy spec

`apps/openclaw/deploy.json` is the source of truth for what runs on the VM. Same
JSON shape any caller of dd-agent's `/deploy` endpoint would use — colocating it
with the marketplace repo just makes it reviewable in PRs.

## Deployment

| Trigger | Workflow | Environment |
|---------|----------|-------------|
| PR to main | `staging-deploy.yml` | Staging |
| Push to main | `production-deploy.yml` | Production |

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/vm-startup.sh` | Runs inside VM — installs podman + dd-agent, POSTs the openclaw deploy spec |
| `scripts/deploy-vm.sh` | Called by CI — creates disk, generates cloud-init, launches TDX VM |
| `scripts/dd-vm.sh` | Manual VM management (create/list/destroy) |

### VM sizing

| Variable | Default | Description |
|----------|---------|-------------|
| `VM_RAM` | 8192 | RAM in MB |
| `VM_VCPUS` | 4 | vCPU count |
| `VM_DISK` | 80 | Disk in GB |
| `VM_GPU` | (empty) | PCI address for GPU passthrough |

## Web terminal

Connect via `https://your-agent.devopsdefender.com/session/shell` for a VM shell.
From there:

```bash
podman logs openclaw                 # view container output
podman exec -it openclaw sh          # shell into the openclaw/ollama container
podman exec openclaw ollama ps       # see what models are loaded
podman exec openclaw curl localhost:18789/  # poke the openclaw gateway
```
