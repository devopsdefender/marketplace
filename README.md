# DD Marketplace

A compute marketplace built on [DevOps Defender](https://devopsdefender.com) + [OpenClaw](https://openclaw.ai). Rent TDX-verified enclave capacity, pay with BTC.

This repo is also the reference example for building apps on DD + OpenClaw.

## How it works

1. **DD deploys OpenClaw** — the marketplace orchestrator runs inside a TDX enclave
2. **OpenClaw manages capacity** — uses skills (markdown) to provision and manage confidential VMs
3. **Customers pay with BTC** — wallet integration inside the enclave (keys never leave hardware)
4. **Nodes register with DD** — each provisioned VM becomes a DD agent with attestation

```
Customer ──BTC──> Marketplace (OpenClaw on TDX)
                       │
                       ├── Launch confidential VM on local GPU host
                       ├── Agent registers with DD control plane
                       ├── Customer deploys workload to their enclave
                       └── Teardown on rental expiry
```

## Quick start

### 1. Fork this repo

### 2. Set GitHub secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `BAREMETAL_SSH_KEY` | Yes | SSH key for the OVH deployment host |

### 3. Open a PR

Triggers the deploy: provisions a DD agent VM, deploys OpenClaw with marketplace skills.

### 4. Connect

Your marketplace is live at the Cloudflare tunnel URL assigned by DD.

## Skills

Skills are markdown files in `config/skills/` that define what OpenClaw can do:

- **`capacity.md`** — Manage compute nodes (launch, stop, monitor VMs)
- **`payments.md`** — BTC payment processing for capacity rentals
- **`attestation.md`** — Scalable heartbeat, metrics, logs, and attestation aggregation

To add a new skill, create a markdown file describing the capability. OpenClaw loads it automatically.

## Apps

### Attestation Aggregator

A TDX-attested service that sits between DD agents and the control plane, enabling telemetry and attestation at scale. Instead of every agent maintaining a direct connection to CP for heartbeats, metrics, logs, and attestation quotes, agents report to a local aggregator which batches and forwards everything.

```
Agents (hundreds) ──> Aggregator (TDX-attested) ──batch──> Control Plane
```

**Trust model:** The aggregator runs inside a TDX enclave and attests itself to the control plane at startup. CP issues a short-lived relay token; all forwarded batches are signed with it. If the aggregator is compromised, the token is revoked.

See `apps/attestation-aggregator/` for the source and `config/skills/attestation.md` for the OpenClaw skill definition.

## Building your own DD + OpenClaw app

This repo shows the pattern:

1. Write your skills as markdown in `config/skills/`
2. Set `config/defaults.env` for OpenClaw bootstrap
3. The deploy workflow handles everything: VM provisioning, agent registration, OpenClaw deployment
4. Fork, customize skills, push — you have your own DD-powered app

## Architecture

- **DD Control Plane** — GCP, manages agent registration and Cloudflare tunnels
- **DD Agent** — OVH baremetal, runs the OpenClaw container via libvirt/KVM
- **OpenClaw** — AI orchestrator inside TDX enclave, executes skills
- **Capacity** — Local confidential VMs launched by OpenClaw on demand
