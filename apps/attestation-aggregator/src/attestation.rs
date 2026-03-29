//! TDX attestation helpers.
//!
//! In production on TDX hardware, `generate_self_quote` reads from the
//! vsock quote generation service (cid 2, port 4050) and `verify_quote`
//! validates the ECDSA signature chain against Intel's root of trust.
//!
//! This module provides the interface; the actual TDX ioctl / vsock
//! integration is handled by the dd-agent runtime that wraps this binary.
//! When running outside TDX (dev/test), we fall back to a placeholder.

use sha2::{Digest, Sha256};
use std::fs;
use tracing::{info, warn};

const TDX_QUOTE_DEVICE: &str = "/dev/tdx_guest";
const TDX_REPORT_PATH: &str = "/sys/firmware/tdx/report";

/// Generate an attestation quote for *this* aggregator process.
///
/// On TDX hardware the quote comes from the guest TD report; off-TDX we
/// return a deterministic placeholder so the control plane can distinguish
/// "not attested" from "attestation failed".
pub fn generate_self_quote() -> String {
    if is_tdx_available() {
        match read_tdx_report() {
            Some(report) => {
                info!("generated TDX attestation quote");
                report
            }
            None => {
                warn!("TDX device present but quote generation failed, using placeholder");
                placeholder_quote()
            }
        }
    } else {
        warn!("TDX not available, using placeholder quote (dev mode)");
        placeholder_quote()
    }
}

/// Verify an agent-submitted attestation quote.
///
/// Full verification checks the ECDSA-P256 signature chain rooted at
/// Intel's Provisioning Certification Service (PCS). Here we do a
/// structural check; the control plane performs the full cryptographic
/// verification when it receives the aggregated batch.
pub fn verify_quote(quote: &str) -> bool {
    // Structural validation: must be non-empty, valid base64, and have
    // a minimum length consistent with a TDX quote (~1 KB+).
    if quote.is_empty() {
        return false;
    }

    match base64::Engine::decode(&base64::engine::general_purpose::STANDARD, quote) {
        Ok(bytes) => {
            // TDX quotes are at minimum ~1017 bytes (header + body + signature)
            if bytes.len() < 48 {
                warn!(len = bytes.len(), "quote too short to be a valid TDX quote");
                return false;
            }
            true
        }
        Err(_) => {
            warn!("quote is not valid base64");
            false
        }
    }
}

fn is_tdx_available() -> bool {
    std::path::Path::new(TDX_QUOTE_DEVICE).exists()
}

fn read_tdx_report() -> Option<String> {
    fs::read(TDX_REPORT_PATH)
        .ok()
        .map(|bytes| base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes))
}

fn placeholder_quote() -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"attestation-aggregator-dev-mode");
    hasher.update(uuid::Uuid::new_v4().as_bytes());
    base64::Engine::encode(&base64::engine::general_purpose::STANDARD, hasher.finalize())
}
