# DD Marketplace

Run AI workloads on confidential hardware. Deploy OpenClaw, Claude Code, and signal-cli as apps on a DD agent — all sharing the same machine, seeing each other's processes, communicating via shared filesystem.

## Apps

| App | Image | Description |
|-----|-------|-------------|
| OpenClaw | `ghcr.io/devopsdefender/openclaw` | AI orchestrator with skills |
| Claude Code | `ghcr.io/devopsdefender/claude-code` | Coding assistant |
| signal-cli | `ghcr.io/devopsdefender/signal-cli` | Signal messaging |

## Quick start

### 1. Connect to a DD agent

```bash
dd connect --to your-agent.devopsdefender.com
```

### 2. Deploy apps

```
dd> deploy ghcr.io/devopsdefender/openclaw --tty
dd> deploy ghcr.io/devopsdefender/claude-code --tty
dd> deploy ghcr.io/devopsdefender/signal-cli
dd> jobs
  [1] openclaw        running
  [2] claude-code     running
  [3] signal-cli      running
```

### 3. Use them

All apps share the same machine:
- Same network — OpenClaw talks to Claude Code on localhost
- Same filesystem — write to `/shared`, every app can read it
- Same PID namespace — `ps aux` shows all running apps
- Signal-cli writes messages to `/shared/inbox`, Claude reads them

```
dd> fg openclaw
> use claude to summarize the latest signal messages
```

### 4. Browser access

Open `https://your-agent.devopsdefender.com/session/openclaw` for a web terminal.

## How it works

DD agents are remote shells on TDX confidential VMs. Apps are OCI images that get pulled and run as processes (not containers). Everything shares everything — like programs on a real computer, but the computer is a hardware-verified enclave.

```
You (browser/CLI)
  │ Noise-encrypted WebSocket
  ↓
DD Agent (TDX confidential VM)
  ├── openclaw      ← AI orchestrator
  ├── claude-code   ← coding assistant
  ├── signal-cli    ← messaging
  └── all share: PID, network, /shared filesystem
```

## Attestation

When you connect via the Noise channel, the agent proves it's running on real TDX hardware. The attestation is verified before any data is sent.

## Adding your own node

Boot the DD base image on any TDX-capable machine:

```bash
# GCP
gcloud compute instances create my-node \
  --machine-type=c3-standard-4 \
  --confidential-compute-type=TDX

# Or any machine with dd-agent installed
DD_OWNER=your-github-username dd-agent
```

Then deploy apps to it with `dd deploy`.
