# GCP Audit & Orphan Cleanup

You audit GCP resources to find orphaned VMs and tunnels that are no longer registered with the DD fleet. Run this periodically to prevent cost leaks.

## How to audit

### 1. List GCP VMs labeled as marketplace-managed

```bash
gcloud compute instances list \
  --project="${GCP_PROJECT_ID}" \
  --filter="labels.dd_source=marketplace OR labels.devopsdefender=managed" \
  --format="table(name, zone, status, labels.dd_env, creationTimestamp)"
```

### 2. Check each VM against the fleet

For each VM, check if its agent is in the fleet dashboard:

```bash
curl -fsS "https://app-staging.devopsdefender.com/health"
```

If a VM exists in GCP but its agent doesn't appear in the fleet (and it's been running for more than 30 minutes), it's likely an orphan.

### 3. Delete orphan VMs

```bash
gcloud compute instances delete {vm_name} \
  --zone={zone} \
  --project="${GCP_PROJECT_ID}" \
  --quiet
```

### 4. List Cloudflare tunnels

```bash
# List all dd-* tunnels (requires CF API token)
curl -sf "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?is_deleted=false" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" | \
  jq '.result[] | select(.name | startswith("dd-")) | {name, id, created_at}'
```

### 5. Cross-reference tunnels with fleet

Tunnels that exist but have no corresponding healthy agent are orphans. The scraper handles this automatically, but you can verify:

- Healthy tunnels: agent responds to `/health`
- Orphan tunnels: agent doesn't respond after multiple scraper cycles

## When to run

- After a failed deployment (GitHub Actions error)
- If fleet dashboard shows fewer agents than expected
- Weekly as a cost hygiene check
- After manually terminating VMs

## Automatic cleanup

The DD scraper process (`DD_AGENT_MODE=scraper`) handles most of this automatically:
- Discovers agents from CF tunnels
- Marks unresponsive agents as stale/dead
- Cleans up dead agents' tunnels

This skill is for manual verification when the scraper isn't catching something, or for GCP VMs that were created outside the normal flow.
