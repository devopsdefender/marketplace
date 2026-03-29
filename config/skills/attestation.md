# Attestation Aggregator

You manage the attestation aggregator service for the DevOps Defender marketplace. This service enables scalable heartbeats, metrics, logs, and passive attestation by acting as a trusted intermediary between DD agents and the control plane.

## Why this exists

Direct agent-to-control-plane attestation works at small scale, but breaks down when hundreds of agents each maintain individual connections, send heartbeats, stream logs, and submit attestation quotes. The aggregator solves this by:

1. Running **inside a TDX enclave itself** — the control plane attests the aggregator once, then trusts aggregated data it forwards
2. **Batching heartbeats** — agents send heartbeats to the local aggregator instead of the CP
3. **Aggregating metrics and logs** — compressed, deduplicated telemetry forwarded on a cadence
4. **Passive attestation relay** — agents periodically re-attest to the aggregator, which bundles and forwards attestation summaries to CP

## Architecture

```
Agents (many)                    Aggregator (attested)              Control Plane
┌──────────┐                    ┌─────────────────────┐           ┌──────────────┐
│ dd-agent │──heartbeat──────>  │                     │           │              │
│ dd-agent │──metrics────────>  │  attestation-agg    │──batch──> │   DD CP      │
│ dd-agent │──logs───────────>  │  (TDX enclave)      │           │              │
│ dd-agent │──attest-quote───>  │                     │           │              │
└──────────┘                    └─────────────────────┘           └──────────────┘
```

## How to deploy the aggregator

The aggregator runs as a containerized service on a DD agent node with TDX enabled:

```bash
curl -X POST "${CP_URL}/api/v1/deploy" \
  -H "Content-Type: application/json" \
  -d '{
    "image": "ghcr.io/devopsdefender/attestation-aggregator:latest",
    "app_name": "attestation-aggregator",
    "app_version": "latest",
    "env": [
      "AGGREGATOR_MODE=relay",
      "CP_URL=https://app.devopsdefender.com",
      "HEARTBEAT_INTERVAL_MS=5000",
      "FLUSH_INTERVAL_MS=10000",
      "MAX_BATCH_SIZE=500",
      "ATTESTATION_REFRESH_SECS=300"
    ],
    "ports": ["9090:9090"]
  }'
```

## Configuring agents to use the aggregator

Point agents at the aggregator instead of CP for telemetry:

```json
{
  "mode": "agent",
  "control_plane_url": "https://app.devopsdefender.com",
  "aggregator_url": "http://aggregator.local:9090",
  "telemetry_target": "aggregator"
}
```

## Health and status

The aggregator exposes its own health endpoint:

```bash
curl http://aggregator.local:9090/healthz
```

And a metrics summary:

```bash
curl http://aggregator.local:9090/api/v1/status
```

This returns:
```json
{
  "connected_agents": 47,
  "heartbeats_buffered": 128,
  "metrics_pending_flush": 2304,
  "last_cp_flush": "2026-03-29T10:15:00Z",
  "self_attestation": "valid",
  "uptime_secs": 86400
}
```

## Trust model

1. CP attests the aggregator at startup via TDX quote verification
2. Aggregator receives a short-lived **relay token** from CP upon successful attestation
3. All forwarded batches are signed with the relay token
4. CP validates relay token on each batch — if the aggregator is compromised, the token is revoked
5. Aggregator re-attests on a configurable cadence (default: every 5 minutes)

## Scaling

- One aggregator per datacenter / rack is typical
- Each aggregator handles up to 500 agents
- For larger deployments, run multiple aggregators — CP deduplicates
- Aggregators do NOT talk to each other (star topology, CP is hub)
