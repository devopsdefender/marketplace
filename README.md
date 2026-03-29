# DD Marketplace

A compute marketplace built on [DevOps Defender](https://devopsdefender.com). Rent TDX-verified enclave capacity, pay with BTC.

## How it works

1. **DD provisions a baremetal agent** — KVM/libvirt VM on OVH with TDX attestation
2. **CI deploys the capacity service** — a Flask API for managing rentals
3. **Customers request capacity** — choose node type, get a BTC invoice
4. **Payment triggers provisioning** — workload deployed to the DD agent automatically

```
CI (GitHub Actions)
  ├── deploy-vm: provisions DD agent on baremetal
  ├── build-service: builds capacity service container
  └── deploy-marketplace: deploys container via DD deploy API

Customer → POST /api/rentals → BTC invoice → payment → workload provisioned
```

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/capacity` | Node types and pricing |
| `POST` | `/api/rentals` | Create rental: `{node_type, hours}` |
| `GET` | `/api/rentals/<id>` | Rental status |
| `GET` | `/api/invoices/<id>` | Invoice status |
| `POST` | `/api/invoices/<id>/simulate-payment` | Dev: simulate BTC payment |
| `GET` | `/health` | Health check |

## Pricing

| Node Type | Specs | BTC/hour |
|-----------|-------|----------|
| Standard | 8 vCPU, 16GB RAM | 0.001 |
| GPU (H100) | 16 vCPU, 64GB RAM, NVIDIA H100 | 0.01 |

## Quick start

### 1. Fork this repo

### 2. Set GitHub secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `BAREMETAL_SSH_KEY` | Yes | SSH key for the OVH deployment host |

### 3. Open a PR

Triggers the deploy: provisions a DD agent VM, builds the capacity service container, deploys it.

### Local development

```bash
cd service
pip install -r requirements.txt
DD_CONTROL_PLANE_URL=http://localhost:9999 DATABASE_PATH=/tmp/capacity.db python app.py
```

## Project structure

```
service/                    # Capacity management service (Flask)
├── app.py                  # Entry point
├── config.py               # Node types, pricing
├── models.py               # DB models (Invoice, Rental)
├── routes.py               # HTTP API
├── payments.py             # BTC payment stub
├── provisioner.py          # DD deploy API client
├── scheduler.py            # Background tasks
├── Dockerfile
└── requirements.txt
infra/                      # Infrastructure as Code
├── ansible/                # Baremetal provisioning
├── packer/                 # VM image building
└── scripts/                # VM lifecycle (launch, stop, status)
```

## Architecture

- **DD Control Plane** — GCP, manages agent registration and Cloudflare tunnels
- **DD Agent** — OVH baremetal, runs containers via libvirt/KVM
- **Capacity Service** — Flask API managing rentals, payments, and provisioning
