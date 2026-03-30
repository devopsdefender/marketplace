#!/usr/bin/env bash
# Launch a DD agent VM on GCP with TDX confidential compute.
# Used as overflow when local baremetal capacity is full.
set -euo pipefail

NODE_SIZE="standard"
CP_URL=""
ZONE="${GCP_ZONE:-us-central1-c}"
PROJECT="${GCP_PROJECT_ID:-}"
IMAGE_FAMILY="${DD_GCP_IMAGE_FAMILY:-dd-agent-main}"
IMAGE_PROJECT="${DD_GCP_IMAGE_PROJECT:-$PROJECT}"
DD_ENV="${DD_ENV:-staging}"
CUSTOMER_ID=""
INTEL_API_KEY="${INTEL_API_KEY:-}"

usage() {
  cat <<EOF
Usage: $0 [options]
  --customer-id ID     Customer identifier (required)
  --node-size SIZE     tiny|standard|llm (default: standard)
  --cp-url URL         DD control plane URL (required)
  --zone ZONE          GCP zone (default: us-central1-c)
  --project PROJECT    GCP project ID (default: \$GCP_PROJECT_ID)
  --image-family FAM   Image family (default: dd-agent-main)
  --env ENV            staging|production (default: staging)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --customer-id) CUSTOMER_ID="$2"; shift 2 ;;
    --node-size)   NODE_SIZE="$2"; shift 2 ;;
    --cp-url)      CP_URL="$2"; shift 2 ;;
    --zone)        ZONE="$2"; shift 2 ;;
    --project)     PROJECT="$2"; shift 2 ;;
    --image-family) IMAGE_FAMILY="$2"; shift 2 ;;
    --env)         DD_ENV="$2"; shift 2 ;;
    --help|-h)     usage ;;
    *)             echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [ -z "$CUSTOMER_ID" ] || [ -z "$CP_URL" ] || [ -z "$PROJECT" ]; then
  echo "Error: --customer-id, --cp-url, and --project (or GCP_PROJECT_ID) are required" >&2
  usage
fi

# Map node_size to GCP machine type
case "$NODE_SIZE" in
  tiny)     MACHINE_TYPE="c3-standard-4"  ;;
  standard) MACHINE_TYPE="c3-standard-8"  ;;
  llm)      MACHINE_TYPE="c3-standard-22" ;;
  *)        echo "Error: unknown node_size '$NODE_SIZE'" >&2; exit 1 ;;
esac

VM_NAME="dd-marketplace-${CUSTOMER_ID}-$(date +%s)"
REGION="${ZONE%-*}"

# Build the agent startup script
STARTUP_SCRIPT=$(cat <<STARTUP
#!/usr/bin/env bash
set -euo pipefail
mkdir -p /etc/devopsdefender
cat > /etc/devopsdefender/agent.json <<'AGENT_CONFIG'
{
  "mode": "agent",
  "control_plane_url": "${CP_URL}",
  "node_size": "${NODE_SIZE}",
  "datacenter": "gcp-${ZONE}",
  "cloud_provider": "gcp",
  "availability_zone": "${ZONE}",
  "region": "${REGION}",
  "dd_env": "${DD_ENV}",
  "intel_api_key": "${INTEL_API_KEY}"
}
AGENT_CONFIG
chmod 0600 /etc/devopsdefender/agent.json
systemctl daemon-reload || true
systemctl disable --now devopsdefender-control-plane.service || true
systemctl enable devopsdefender-agent.service || true
systemctl restart devopsdefender-agent.service || true
STARTUP
)

echo "==> Launching GCP VM: ${VM_NAME}"
echo "    Machine type: ${MACHINE_TYPE}"
echo "    Zone: ${ZONE}"
echo "    Image family: ${IMAGE_FAMILY}"
echo "    Node size: ${NODE_SIZE}"
echo "    Control plane: ${CP_URL}"

gcloud compute instances create "$VM_NAME" \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --machine-type="$MACHINE_TYPE" \
  --confidential-compute-type=TDX \
  --image-family="$IMAGE_FAMILY" \
  --image-project="$IMAGE_PROJECT" \
  --boot-disk-size=100GB \
  --boot-disk-type=pd-balanced \
  --metadata=startup-script="$STARTUP_SCRIPT" \
  --labels="devopsdefender=managed,dd_role=agent,dd_env=${DD_ENV},dd_node_size=${NODE_SIZE},dd_source=marketplace,dd_customer=${CUSTOMER_ID}" \
  --provisioning-model=STANDARD \
  --no-restart-on-failure \
  --format=json \
  | jq '{name: .[0].name, zone: .[0].zone, status: .[0].status}'

echo "==> VM created. Agent will auto-register with control plane."
echo "    Delete with: gcloud compute instances delete ${VM_NAME} --zone=${ZONE} --project=${PROJECT} --quiet"

# Output metadata for tracking
cat <<INFO
{
  "vm_name": "${VM_NAME}",
  "customer_id": "${CUSTOMER_ID}",
  "node_size": "${NODE_SIZE}",
  "machine_type": "${MACHINE_TYPE}",
  "zone": "${ZONE}",
  "project": "${PROJECT}",
  "provider": "gcp",
  "cp_url": "${CP_URL}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
INFO
