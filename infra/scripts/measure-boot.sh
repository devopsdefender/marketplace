#!/usr/bin/env python3
"""Boot measurement script for TDX attestation.

Runs as ExecStartPre before dd-agent. Measures sealed state, agent config,
and critical binaries into RTMR[2] via /dev/tdx_guest. On non-TDX VMs,
writes the measurement file but skips the ioctl.

Measurement order (deterministic, changing order changes RTMR[2]):
  0: sealed_state  — SSH service states
  1: agent_config  — /etc/devopsdefender/agent.json
  2: binary_manifest — dd-agent, cloudflared hashes
"""

import ctypes
import ctypes.util
import fcntl
import hashlib
import json
import logging
import os
import struct
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
log = logging.getLogger("measure-boot")

RTMR_INDEX = 2
TDX_GUEST_DEVICE = "/dev/tdx_guest"
MEASUREMENTS_PATH = "/run/devopsdefender/measurements.json"
AGENT_CONFIG_PATH = "/etc/devopsdefender/agent.json"
IMAGE_MEASUREMENTS_PATH = "/etc/devopsdefender/image-measurements.json"

CRITICAL_BINARIES = ["/usr/local/bin/dd-agent", "/usr/bin/cloudflared"]

# TDX ioctl: TDX_CMD_EXTEND_RTMR = _IOW('T', 3, struct tdx_extend_rtmr_req)
# struct tdx_extend_rtmr_req { __u32 rtmr_index; __u8 data[48]; }
# _IOW('T', 3, 52) = direction=1 (write), size=52, type='T'(0x54), nr=3
TDX_CMD_EXTEND_RTMR = 0x40345403


def sha384_bytes(data: bytes) -> bytes:
    return hashlib.sha384(data).digest()


def sha384_hex(data: bytes) -> str:
    return hashlib.sha384(data).hexdigest()


def canonical_json(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def systemctl_is(query: str, unit: str) -> str:
    """Run systemctl is-enabled/is-active, return output or 'unknown'."""
    try:
        result = subprocess.run(
            ["systemctl", query, unit],
            capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip()
    except Exception:
        return "unknown"


def measure_sealed_state() -> tuple[bytes, dict]:
    """Measure SSH service states. A sealed VM always produces the same hash."""
    details = {
        "ssh_host_keys_exist": any(Path("/etc/ssh").glob("ssh_host_*")),
        "ssh_service_active": systemctl_is("is-active", "ssh.service") == "active",
        "ssh_service_masked": systemctl_is("is-enabled", "ssh.service") == "masked",
        "ssh_socket_masked": systemctl_is("is-enabled", "ssh.socket") == "masked",
        "sshd_service_masked": systemctl_is("is-enabled", "sshd.service") == "masked",
    }
    data = canonical_json(details)
    return sha384_bytes(data), details


def measure_agent_config() -> tuple[bytes, str]:
    """SHA-384 of the raw agent config file."""
    config_path = Path(AGENT_CONFIG_PATH)
    if not config_path.exists():
        log.warning("Agent config not found at %s", AGENT_CONFIG_PATH)
        return sha384_bytes(b""), AGENT_CONFIG_PATH
    raw = config_path.read_bytes()
    return sha384_bytes(raw), AGENT_CONFIG_PATH


def measure_binaries() -> tuple[bytes, dict]:
    """SHA-384 manifest of critical binaries."""
    manifest = {}
    for path in sorted(CRITICAL_BINARIES):
        if os.path.isfile(path):
            with open(path, "rb") as f:
                manifest[path] = sha384_hex(f.read())
        else:
            manifest[path] = "missing"
            log.warning("Binary not found: %s", path)
    data = canonical_json(manifest)
    return sha384_bytes(data), manifest


def extend_rtmr(digest: bytes):
    """Extend RTMR[2] via /dev/tdx_guest ioctl."""
    if not os.path.exists(TDX_GUEST_DEVICE):
        log.warning("TDX not available (%s not found), skipping RTMR extension", TDX_GUEST_DEVICE)
        return False

    # struct tdx_extend_rtmr_req: u32 rtmr_index + 48 bytes data
    buf = struct.pack("I", RTMR_INDEX) + digest[:48]
    arr = (ctypes.c_char * len(buf)).from_buffer_copy(buf)

    try:
        fd = os.open(TDX_GUEST_DEVICE, os.O_RDWR)
        try:
            fcntl.ioctl(fd, TDX_CMD_EXTEND_RTMR, arr)
        finally:
            os.close(fd)
        return True
    except OSError as e:
        log.error("Failed to extend RTMR[%d]: %s", RTMR_INDEX, e)
        return False


def compute_cumulative_rtmr(hashes: list[bytes]) -> str:
    """Compute what RTMR[2] should be after all extensions."""
    rtmr = b"\x00" * 48
    for h in hashes:
        rtmr = sha384_bytes(rtmr + h)
    return rtmr.hex()


def main():
    tdx_available = os.path.exists(TDX_GUEST_DEVICE)
    log.info("TDX available: %s", tdx_available)

    # Measurement 0: sealed state
    sealed_hash, sealed_details = measure_sealed_state()
    log.info("Sealed state hash: %s", sealed_hash.hex())
    if tdx_available:
        extend_rtmr(sealed_hash)

    # Measurement 1: agent config
    config_hash, config_path = measure_agent_config()
    log.info("Agent config hash: %s", config_hash.hex())
    if tdx_available:
        extend_rtmr(config_hash)

    # Measurement 2: binary manifest
    binary_hash, binary_manifest = measure_binaries()
    log.info("Binary manifest hash: %s", binary_hash.hex())
    if tdx_available:
        extend_rtmr(binary_hash)

    # Compute expected cumulative RTMR[2]
    expected = compute_cumulative_rtmr([sealed_hash, config_hash, binary_hash])
    log.info("Expected RTMR[2]: %s", expected)

    # Write runtime measurements file
    measurements = {
        "schema_version": 1,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "tdx_available": tdx_available,
        "rtmr_index": RTMR_INDEX,
        "extensions": [
            {
                "order": 0,
                "label": "sealed_state",
                "hash": sealed_hash.hex(),
                "details": sealed_details,
            },
            {
                "order": 1,
                "label": "agent_config",
                "hash": config_hash.hex(),
                "source_path": config_path,
            },
            {
                "order": 2,
                "label": "binary_manifest",
                "hash": binary_hash.hex(),
                "binaries": binary_manifest,
            },
        ],
        "expected_rtmr2": expected,
    }

    os.makedirs(os.path.dirname(MEASUREMENTS_PATH), exist_ok=True)
    Path(MEASUREMENTS_PATH).write_text(json.dumps(measurements, indent=2))
    log.info("Measurements written to %s", MEASUREMENTS_PATH)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        log.exception("Measurement failed")
        sys.exit(1)
