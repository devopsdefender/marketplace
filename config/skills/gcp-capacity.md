# GCP Overflow Capacity

You manage GCP-based compute nodes as overflow when local baremetal capacity is full. GCP nodes run as TDX-verified confidential VMs on Google Cloud, using the same DD agent images as local nodes.

## When to use GCP

- Local baremetal hosts are at capacity (all VM slots occupied)
- Customer specifically requests cloud-based capacity
- Customer needs a zone/region not served by local hardware

## How to launch a GCP node

```bash
./infra/scripts/gcp-vm-launch.sh \
  --customer-id {customer_id} \
  --node-size standard \
  --cp-url https://app.devopsdefender.com \
  --zone us-central1-c \
  --env production
```

### Node sizes on GCP

| Node Size | GCP Machine Type | vCPU | RAM | BTC/hour |
|-----------|-----------------|------|-----|----------|
| tiny      | c3-standard-4   | 4    | 16GB | 0.002   |
| standard  | c3-standard-8   | 8    | 32GB | 0.003   |
| llm       | c3-standard-22  | 22   | 88GB | 0.015   |

GCP nodes cost more than local nodes due to cloud provider charges.

## How to list GCP nodes

```bash
gcloud compute instances list \
  --project="${GCP_PROJECT_ID}" \
  --filter="labels.dd_source=marketplace" \
  --format="table(name, zone, machineType.basename(), status, labels.dd_customer, labels.dd_node_size)"
```

## How to stop a GCP node

```bash
gcloud compute instances delete {vm_name} \
  --zone={zone} \
  --project="${GCP_PROJECT_ID}" \
  --quiet
```

## After launch

The agent auto-registers with the DD control plane. Verify:

```bash
curl https://app.devopsdefender.com/api/v1/agents | \
  jq '.[] | select(.datacenter | startswith("gcp-")) | {id: .id[0:8], node_size, datacenter}'
```

## Important

- GCP nodes have TDX confidential compute enabled — same security as local nodes
- Always use `dd_source=marketplace` label so nodes can be identified and cleaned up
- Set up automatic deletion when rental expires to avoid runaway costs
- GCP project credentials are available via `GCP_PROJECT_ID` env var
