use axum::{
    extract::State,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    env,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::RwLock;
use tracing::{error, info, warn};

mod attestation;

#[derive(Clone)]
struct AppState {
    inner: Arc<RwLock<AggregatorState>>,
    config: AggregatorConfig,
}

#[derive(Clone)]
struct AggregatorConfig {
    cp_url: String,
    flush_interval: Duration,
    heartbeat_interval: Duration,
    max_batch_size: usize,
    attestation_refresh: Duration,
}

struct AggregatorState {
    heartbeats: HashMap<String, AgentHeartbeat>,
    metrics_buffer: Vec<MetricEntry>,
    logs_buffer: Vec<LogEntry>,
    attestation_cache: HashMap<String, AttestationRecord>,
    relay_token: Option<String>,
    self_attestation_status: AttestationStatus,
    start_time: Instant,
    last_cp_flush: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AgentHeartbeat {
    agent_id: String,
    timestamp: DateTime<Utc>,
    status: String,
    uptime_secs: u64,
    cpu_percent: f64,
    memory_used_mb: u64,
    memory_total_mb: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct MetricEntry {
    agent_id: String,
    timestamp: DateTime<Utc>,
    name: String,
    value: f64,
    labels: HashMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct LogEntry {
    agent_id: String,
    timestamp: DateTime<Utc>,
    level: String,
    message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AttestationRecord {
    agent_id: String,
    timestamp: DateTime<Utc>,
    quote_hash: String,
    verified: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
enum AttestationStatus {
    Pending,
    Valid,
    Failed,
}

// --- Request / Response types ---

#[derive(Deserialize)]
struct HeartbeatRequest {
    agent_id: String,
    status: String,
    uptime_secs: u64,
    cpu_percent: f64,
    memory_used_mb: u64,
    memory_total_mb: u64,
}

#[derive(Deserialize)]
struct MetricsRequest {
    agent_id: String,
    metrics: Vec<MetricItem>,
}

#[derive(Deserialize)]
struct MetricItem {
    name: String,
    value: f64,
    #[serde(default)]
    labels: HashMap<String, String>,
}

#[derive(Deserialize)]
struct LogsRequest {
    agent_id: String,
    entries: Vec<LogItem>,
}

#[derive(Deserialize)]
struct LogItem {
    level: String,
    message: String,
    #[serde(default = "Utc::now")]
    timestamp: DateTime<Utc>,
}

#[derive(Deserialize)]
struct AttestationRequest {
    agent_id: String,
    quote: String,
}

#[derive(Serialize)]
struct StatusResponse {
    connected_agents: usize,
    heartbeats_buffered: usize,
    metrics_pending_flush: usize,
    logs_pending_flush: usize,
    last_cp_flush: Option<DateTime<Utc>>,
    self_attestation: String,
    uptime_secs: u64,
}

#[derive(Serialize)]
struct BatchPayload {
    aggregator_id: String,
    relay_token: String,
    heartbeats: Vec<AgentHeartbeat>,
    metrics: Vec<MetricEntry>,
    logs: Vec<LogEntry>,
    attestations: Vec<AttestationRecord>,
    timestamp: DateTime<Utc>,
}

// --- Handlers ---

async fn healthz(State(state): State<AppState>) -> StatusCode {
    let inner = state.inner.read().await;
    if inner.self_attestation_status == AttestationStatus::Valid {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    }
}

async fn status(State(state): State<AppState>) -> Json<StatusResponse> {
    let inner = state.inner.read().await;
    Json(StatusResponse {
        connected_agents: inner.heartbeats.len(),
        heartbeats_buffered: inner.heartbeats.len(),
        metrics_pending_flush: inner.metrics_buffer.len(),
        logs_pending_flush: inner.logs_buffer.len(),
        last_cp_flush: inner.last_cp_flush,
        self_attestation: format!("{:?}", inner.self_attestation_status).to_lowercase(),
        uptime_secs: inner.start_time.elapsed().as_secs(),
    })
}

async fn ingest_heartbeat(
    State(state): State<AppState>,
    Json(req): Json<HeartbeatRequest>,
) -> StatusCode {
    let mut inner = state.inner.write().await;
    let hb = AgentHeartbeat {
        agent_id: req.agent_id.clone(),
        timestamp: Utc::now(),
        status: req.status,
        uptime_secs: req.uptime_secs,
        cpu_percent: req.cpu_percent,
        memory_used_mb: req.memory_used_mb,
        memory_total_mb: req.memory_total_mb,
    };
    inner.heartbeats.insert(req.agent_id, hb);
    StatusCode::ACCEPTED
}

async fn ingest_metrics(
    State(state): State<AppState>,
    Json(req): Json<MetricsRequest>,
) -> StatusCode {
    let mut inner = state.inner.write().await;
    for m in req.metrics {
        inner.metrics_buffer.push(MetricEntry {
            agent_id: req.agent_id.clone(),
            timestamp: Utc::now(),
            name: m.name,
            value: m.value,
            labels: m.labels,
        });
    }
    StatusCode::ACCEPTED
}

async fn ingest_logs(
    State(state): State<AppState>,
    Json(req): Json<LogsRequest>,
) -> StatusCode {
    let mut inner = state.inner.write().await;
    for entry in req.entries {
        inner.logs_buffer.push(LogEntry {
            agent_id: req.agent_id.clone(),
            timestamp: entry.timestamp,
            level: entry.level,
            message: entry.message,
        });
    }
    StatusCode::ACCEPTED
}

async fn ingest_attestation(
    State(state): State<AppState>,
    Json(req): Json<AttestationRequest>,
) -> StatusCode {
    let quote_hash = {
        let mut hasher = Sha256::new();
        hasher.update(req.quote.as_bytes());
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, hasher.finalize())
    };

    let record = AttestationRecord {
        agent_id: req.agent_id.clone(),
        timestamp: Utc::now(),
        quote_hash,
        verified: attestation::verify_quote(&req.quote),
    };

    if !record.verified {
        warn!(agent_id = %req.agent_id, "attestation quote verification failed");
    }

    let mut inner = state.inner.write().await;
    inner.attestation_cache.insert(req.agent_id, record);
    StatusCode::ACCEPTED
}

// --- Background tasks ---

async fn flush_loop(state: AppState) {
    let client = reqwest::Client::new();
    let aggregator_id = uuid::Uuid::new_v4().to_string();

    loop {
        tokio::time::sleep(state.config.flush_interval).await;

        let batch = {
            let mut inner = state.inner.write().await;
            let relay_token = match &inner.relay_token {
                Some(t) => t.clone(),
                None => {
                    warn!("no relay token yet, skipping flush");
                    continue;
                }
            };

            let heartbeats: Vec<_> = inner.heartbeats.values().cloned().collect();
            let metrics = std::mem::take(&mut inner.metrics_buffer);
            let logs = std::mem::take(&mut inner.logs_buffer);
            let attestations: Vec<_> = inner.attestation_cache.values().cloned().collect();

            BatchPayload {
                aggregator_id: aggregator_id.clone(),
                relay_token,
                heartbeats,
                metrics,
                logs,
                attestations,
                timestamp: Utc::now(),
            }
        };

        let url = format!("{}/api/v1/aggregator/batch", state.config.cp_url);
        match client.post(&url).json(&batch).send().await {
            Ok(resp) if resp.status().is_success() => {
                let count = batch.heartbeats.len()
                    + batch.metrics.len()
                    + batch.logs.len()
                    + batch.attestations.len();
                info!(items = count, "flushed batch to control plane");
                let mut inner = state.inner.write().await;
                inner.last_cp_flush = Some(Utc::now());
            }
            Ok(resp) if resp.status().as_u16() == 401 => {
                error!("relay token rejected by CP, re-attesting");
                let mut inner = state.inner.write().await;
                inner.relay_token = None;
                inner.self_attestation_status = AttestationStatus::Pending;
            }
            Ok(resp) => {
                error!(status = %resp.status(), "CP batch endpoint returned error");
                // Put metrics/logs back so they aren't lost
                let mut inner = state.inner.write().await;
                inner.metrics_buffer.extend(batch.metrics);
                inner.logs_buffer.extend(batch.logs);
            }
            Err(e) => {
                error!(error = %e, "failed to reach control plane");
                let mut inner = state.inner.write().await;
                inner.metrics_buffer.extend(batch.metrics);
                inner.logs_buffer.extend(batch.logs);
            }
        }

        // Enforce max buffer size by dropping oldest entries
        let mut inner = state.inner.write().await;
        let max = state.config.max_batch_size;
        if inner.metrics_buffer.len() > max * 10 {
            let drain = inner.metrics_buffer.len() - max * 10;
            inner.metrics_buffer.drain(..drain);
            warn!(dropped = drain, "metrics buffer overflow, dropping oldest");
        }
        if inner.logs_buffer.len() > max * 10 {
            let drain = inner.logs_buffer.len() - max * 10;
            inner.logs_buffer.drain(..drain);
            warn!(dropped = drain, "logs buffer overflow, dropping oldest");
        }
    }
}

async fn self_attestation_loop(state: AppState) {
    let client = reqwest::Client::new();

    loop {
        {
            let inner = state.inner.read().await;
            if inner.self_attestation_status == AttestationStatus::Valid && inner.relay_token.is_some() {
                drop(inner);
                tokio::time::sleep(state.config.attestation_refresh).await;
                continue;
            }
        }

        info!("performing self-attestation with control plane");

        let quote = attestation::generate_self_quote();
        let url = format!("{}/api/v1/aggregator/attest", state.config.cp_url);
        let body = serde_json::json!({ "quote": quote });

        match client.post(&url).json(&body).send().await {
            Ok(resp) if resp.status().is_success() => {
                if let Ok(json) = resp.json::<serde_json::Value>().await {
                    if let Some(token) = json.get("relay_token").and_then(|t| t.as_str()) {
                        let mut inner = state.inner.write().await;
                        inner.relay_token = Some(token.to_string());
                        inner.self_attestation_status = AttestationStatus::Valid;
                        info!("self-attestation succeeded, relay token acquired");
                    }
                }
            }
            Ok(resp) => {
                error!(status = %resp.status(), "self-attestation rejected by CP");
                let mut inner = state.inner.write().await;
                inner.self_attestation_status = AttestationStatus::Failed;
            }
            Err(e) => {
                error!(error = %e, "failed to reach CP for self-attestation");
            }
        }

        tokio::time::sleep(Duration::from_secs(10)).await;
    }
}

// --- Stale agent reaper ---

async fn reaper_loop(state: AppState) {
    loop {
        tokio::time::sleep(state.config.heartbeat_interval * 6).await;

        let cutoff = Utc::now() - chrono::Duration::seconds(
            (state.config.heartbeat_interval.as_secs() * 6) as i64,
        );

        let mut inner = state.inner.write().await;
        let before = inner.heartbeats.len();
        inner.heartbeats.retain(|_, hb| hb.timestamp > cutoff);
        let removed = before - inner.heartbeats.len();
        if removed > 0 {
            info!(removed, "reaped stale agent heartbeats");
        }

        inner.attestation_cache.retain(|id, _| inner.heartbeats.contains_key(id));
    }
}

fn parse_env_duration(key: &str, default_ms: u64) -> Duration {
    env::var(key)
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .map(Duration::from_millis)
        .unwrap_or(Duration::from_millis(default_ms))
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "attestation_aggregator=info".into()),
        )
        .json()
        .init();

    let config = AggregatorConfig {
        cp_url: env::var("CP_URL").unwrap_or_else(|_| "https://app.devopsdefender.com".into()),
        flush_interval: parse_env_duration("FLUSH_INTERVAL_MS", 10_000),
        heartbeat_interval: parse_env_duration("HEARTBEAT_INTERVAL_MS", 5_000),
        max_batch_size: env::var("MAX_BATCH_SIZE")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(500),
        attestation_refresh: Duration::from_secs(
            env::var("ATTESTATION_REFRESH_SECS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(300),
        ),
    };

    info!(
        cp_url = %config.cp_url,
        flush_interval_ms = config.flush_interval.as_millis() as u64,
        max_batch_size = config.max_batch_size,
        "starting attestation aggregator"
    );

    let state = AppState {
        inner: Arc::new(RwLock::new(AggregatorState {
            heartbeats: HashMap::new(),
            metrics_buffer: Vec::new(),
            logs_buffer: Vec::new(),
            attestation_cache: HashMap::new(),
            relay_token: None,
            self_attestation_status: AttestationStatus::Pending,
            start_time: Instant::now(),
            last_cp_flush: None,
        })),
        config,
    };

    // Spawn background loops
    tokio::spawn(self_attestation_loop(state.clone()));
    tokio::spawn(flush_loop(state.clone()));
    tokio::spawn(reaper_loop(state.clone()));

    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/api/v1/status", get(status))
        .route("/api/v1/heartbeat", post(ingest_heartbeat))
        .route("/api/v1/metrics", post(ingest_metrics))
        .route("/api/v1/logs", post(ingest_logs))
        .route("/api/v1/attest", post(ingest_attestation))
        .with_state(state);

    let bind = env::var("BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:9090".into());
    let listener = tokio::net::TcpListener::bind(&bind).await.unwrap();
    info!(addr = %bind, "listening");
    axum::serve(listener, app).await.unwrap();
}
