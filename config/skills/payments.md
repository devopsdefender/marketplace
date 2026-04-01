# BTC Payment Processing

You handle Bitcoin payments for compute capacity on the DevOps Defender marketplace.

## Payment flow

1. Customer requests capacity (node type + duration)
2. Generate a BTC invoice with the amount based on pricing
3. Monitor the payment address for incoming transactions
4. Once confirmed (1 confirmation minimum), provision the requested capacity
5. Track the rental period and notify before expiration

## Pricing table

### Local baremetal (preferred — cheaper)

| Node Type | Specs | BTC/hour |
|-----------|-------|----------|
| Standard  | 8 vCPU, 16GB RAM | 0.001 |
| GPU (H100)| 16 vCPU, 64GB RAM, NVIDIA H100 | 0.01 |
| Small VM  | 2 vCPU, 4GB RAM (KVM on baremetal) | 0.0005 |

### GCP overflow (when local is full)

| Node Type | Specs | BTC/hour |
|-----------|-------|----------|
| Tiny      | 4 vCPU, 16GB RAM | 0.002 |
| Standard  | 8 vCPU, 32GB RAM | 0.003 |
| LLM       | 22 vCPU, 88GB RAM | 0.015 |

GCP nodes cost more due to cloud provider charges. Always invoice at the GCP rate when provisioning on GCP.

## Wallet integration

Use a simple HD wallet to generate unique payment addresses per customer. The wallet seed is stored in the OpenClaw workspace (encrypted at rest inside the TDX enclave).

## Important

- Never expose private keys in logs or messages
- All payment data stays inside the TDX enclave
- Confirm transactions before provisioning capacity
- Set up automatic teardown when rental period expires
