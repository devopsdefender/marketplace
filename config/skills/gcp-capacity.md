# GCP Overflow Capacity

You manage GCP-based compute nodes as overflow when local baremetal capacity is full. GCP nodes run as TDX-verified confidential VMs on Google Cloud.

## When to use GCP

- Local baremetal hosts are at capacity
- Customer specifically requests cloud-based capacity
- Customer needs a zone/region not served by local hardware

## How to launch a GCP node

```bash
gcloud compute instances create "dd-${DD_ENV}-$(uuidgen)" \
  --project="$GCP_PROJECT_ID" \
  --zone=us-central1-c \
  --machine-type=c3-standard-4 \
  --confidential-compute-type=TDX \
  --maintenance-policy=TERMINATE \
  --boot-disk-size=256GB \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --labels=devopsdefender=managed,dd_env=${DD_ENV},dd_source=marketplace \
  --tags=dd-agent
```

After VM boots, install dd-agent and register with the fleet:

```bash
# Download dd-agent
curl -fsSL -o /usr/local/bin/dd-agent \
  https://github.com/devopsdefender/dd/releases/latest/download/dd-agent
chmod +x /usr/local/bin/dd-agent

# Download cloudflared
curl -fsSL -o /usr/local/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

# Start agent — registers with fleet, gets tunnel
DD_OWNER=devopsdefender \
DD_ENV=${DD_ENV} \
DD_REGISTER_URL=wss://app-staging.devopsdefender.com/register \
nohup dd-agent > /var/log/dd-agent.log 2>&1 &
```

### Node sizes on GCP

| Node Size | GCP Machine Type | vCPU | RAM | BTC/hour |
|-----------|-----------------|------|-----|----------|
| tiny      | c3-standard-4   | 4    | 16GB | 0.002   |
| standard  | c3-standard-8   | 8    | 32GB | 0.003   |
| llm       | c3-standard-22  | 22   | 88GB | 0.015   |

## How to list GCP nodes

```bash
gcloud compute instances list \
  --project="${GCP_PROJECT_ID}" \
  --filter="labels.dd_source=marketplace" \
  --format="table(name, zone, machineType.basename(), status, labels.dd_env)"
```

## How to stop a GCP node

```bash
gcloud compute instances delete {vm_name} \
  --zone={zone} \
  --project="${GCP_PROJECT_ID}" \
  --quiet
```

## Important

- All GCP nodes have TDX confidential compute enabled — same security as local nodes
- Always use `dd_source=marketplace` label for cleanup identification
- Set up automatic deletion when rental expires to avoid runaway costs
- GCP project credentials are available via `GCP_PROJECT_ID` env var
