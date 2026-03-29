# DD Marketplace

A compute marketplace built on [DevOps Defender](https://devopsdefender.com) + [OpenClaw](https://openclaw.ai). Rent TDX-verified enclave capacity, pay with BTC.

This repo is also the reference example for building apps on DD + OpenClaw.

## How it works

1. **DD deploys the orchestrator** — an OpenClaw instance that manages all other instances
2. **Orchestrator deploys specialized instances** — capacity manager, coding environment, etc.
3. **Customers pay with BTC** — wallet integration inside the enclave (keys never leave hardware)
4. **Nodes register with DD** — each provisioned VM becomes a DD agent with attestation

```
CI (GitHub Actions)
  └── deploys Orchestrator OpenClaw (port 8080)
        ├── deploys Capacity OpenClaw (port 8081) — VM management + BTC payments
        ├── deploys Coding OpenClaw (port 8082) — Claude coding in TDX enclave
        └── deploys ... (future instances)
```

## Quick start

### 1. Fork this repo

### 2. Set GitHub secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `BAREMETAL_SSH_KEY` | Yes | SSH key for the OVH deployment host |

### 3. Open a PR

Triggers the deploy: provisions a DD agent VM, deploys the orchestrator, which then deploys all configured instances.

### 4. Connect

Your marketplace is live at the Cloudflare tunnel URL assigned by DD.

## Adding a new instance

Create a directory under `config/instances/` with:

```
config/instances/my-instance/
├── instance.json     # app_name, image, ports, description
├── defaults.env      # environment variables
└── skills/           # optional — markdown skill files
    └── my-skill.md
```

The orchestrator picks it up automatically on the next deploy. No other changes needed.

## Project structure

```
config/
├── orchestrator/           # Orchestrator OpenClaw config
│   ├── defaults.env
│   └── skills/
│       └── manage-instances.md
└── instances/              # One directory per specialized instance
    ├── capacity/           # VM management + BTC payments
    │   ├── instance.json
    │   ├── defaults.env
    │   └── skills/
    └── coding/             # Claude coding environment
        ├── instance.json
        └── defaults.env
infra/                      # Infrastructure as Code
├── ansible/                # Playbooks for baremetal provisioning
├── packer/                 # VM image building
└── scripts/                # VM lifecycle (launch, stop, status)
```

## Architecture

- **DD Control Plane** — GCP, manages agent registration and Cloudflare tunnels
- **DD Agent** — OVH baremetal, runs OpenClaw containers via libvirt/KVM
- **Orchestrator OpenClaw** — manages instance lifecycle via the DD deploy API
- **Specialized instances** — each runs inside a TDX enclave with its own skills
