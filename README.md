# DD Marketplace

Run AI workloads on confidential hardware. Deploy OpenClaw, Claude Code, and signal-cli as apps on a DD agent — all sharing the same machine, seeing each other's processes, communicating via shared filesystem.

## Apps

| App | Image | Description |
|-----|-------|-------------|
| OpenClaw | `ghcr.io/devopsdefender/openclaw` | AI orchestrator with skills |
| Claude Code | `ghcr.io/devopsdefender/claude-code` | Coding assistant |
| signal-cli | `ghcr.io/devopsdefender/signal-cli` | Signal messaging |

## Architecture

```
Customer (browser/CLI)
  │ Noise-encrypted WebSocket
  ↓
DD Agent (TDX baremetal or GCP VM)
  ├── openclaw        ← AI orchestrator (OpenRouter API)
  ├── signal-cli      ← Signal messaging daemon
  ├── /shared/skills/ ← capacity, payments, gcp-capacity, local-vms
  └── all share: PID, network, /shared filesystem
  │
  ↓ registers with
DD Fleet Dashboard (app-staging.devopsdefender.com)
```

## How it works

1. **Baremetal hosts** run `dd-agent` which registers with the DD fleet dashboard
2. **OpenClaw** auto-deploys as the primary workload with OpenRouter API access
3. **signal-cli** deploys alongside for messaging
4. **Skills** are copied to `/shared/skills/` — OpenClaw loads them for capacity management, payments, and provisioning
5. All apps share PID namespace, network, and filesystem — like programs on a real computer inside a TDX enclave

## Deployment

The marketplace deploys automatically via GitHub Actions:

- **On push to main**: Builds app images, deploys to staging
- **Manual dispatch**: Choose staging or production

### What happens on deploy

1. Build OpenClaw + signal-cli images, push to GHCR
2. SSH to baremetal host (staging: 57.130.10.246, production: 162.222.34.121)
3. Copy skills to `/var/lib/dd/shared/skills/`
4. Start `dd-agent` with OpenClaw as primary boot workload + signal-cli as second workload
5. Agent registers with DD fleet, gets Cloudflare tunnel
6. OpenClaw has access to OpenRouter API and DD register for provisioning

### Environment variables

| Var | Purpose |
|-----|---------|
| `DD_BOOT_IMAGE` | Primary workload OCI image |
| `DD_BOOT_ENV` | Semicolon-separated KEY=VALUE pairs for primary workload |
| `DD_BOOT_IMAGE_2` | Second workload OCI image |
| `DD_REGISTER_URL` | Fleet registration WebSocket URL |
| `OPENROUTER_API_KEY` | AI model access for OpenClaw |

## Skills

OpenClaw loads skills from `/var/lib/dd/shared/skills/`:

| Skill | File | Purpose |
|-------|------|---------|
| Capacity Manager | `capacity.md` | List/launch/monitor compute nodes |
| GCP Overflow | `gcp-capacity.md` | Overflow to GCP when local is full |
| Payments | `payments.md` | BTC payment processing |
| Local VMs | `local-vms.md` | Allocate small KVM VMs on baremetal |

## Quick start (manual)

### Connect to an agent

```bash
dd connect --to your-agent.devopsdefender.com
```

### Deploy apps

```
dd> deploy ghcr.io/devopsdefender/openclaw --tty
dd> deploy ghcr.io/devopsdefender/signal-cli
dd> jobs
  [1] openclaw        running
  [2] signal-cli      running
```

### Use them

```
dd> fg openclaw
> use claude to summarize the latest signal messages
> launch a small vm for customer-123
> check fleet capacity
```

### Browser access

Open `https://your-agent.devopsdefender.com/session/openclaw` for a web terminal.

## Adding your own node

```bash
# Any machine with dd-agent + cloudflared
DD_OWNER=your-github-username \
DD_REGISTER_URL=wss://app-staging.devopsdefender.com/register \
dd-agent

# GCP with TDX
gcloud compute instances create my-node \
  --machine-type=c3-standard-4 \
  --confidential-compute-type=TDX \
  --maintenance-policy=TERMINATE
```

The agent registers with the fleet, gets a Cloudflare tunnel, and appears in the dashboard.
