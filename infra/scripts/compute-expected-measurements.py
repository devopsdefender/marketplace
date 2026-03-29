#!/usr/bin/env python3
"""Compute expected TDX measurements at deploy time.

Called by the Ansible playbook after templating agent.json. Combines
build-time binary hashes with the deploy-time config to produce the
expected RTMR[2] value that the control plane should verify.

Usage:
  python3 compute-expected-measurements.py \
    --image-measurements /var/lib/devopsdefender/images/image-measurements.json \
    --agent-config /tmp/dd-deploy/agent.json \
    --output /tmp/dd-deploy/expected-measurements.json
"""

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone


def sha384_bytes(data: bytes) -> bytes:
    return hashlib.sha384(data).digest()


def canonical_json(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def main():
    parser = argparse.ArgumentParser(description="Compute expected TDX measurements")
    parser.add_argument("--image-measurements", required=True,
                        help="Path to image-measurements.json from Packer build")
    parser.add_argument("--agent-config", required=True,
                        help="Path to rendered agent.json")
    parser.add_argument("--output", required=True,
                        help="Output path for expected-measurements.json")
    args = parser.parse_args()

    with open(args.image_measurements) as f:
        image_meas = json.load(f)

    with open(args.agent_config, "rb") as f:
        config_bytes = f.read()

    # The sealed state is a constant for a correctly sealed VM
    sealed_state = {
        "ssh_host_keys_exist": False,
        "ssh_service_active": False,
        "ssh_service_masked": True,
        "ssh_socket_masked": True,
        "sshd_service_masked": True,
    }
    sealed_hash = sha384_bytes(canonical_json(sealed_state))
    config_hash = sha384_bytes(config_bytes)
    binary_hash = bytes.fromhex(image_meas["binary_manifest_hash"])

    # Compute cumulative RTMR[2]: same order as measure-boot.sh
    rtmr = b"\x00" * 48
    for h in [sealed_hash, config_hash, binary_hash]:
        rtmr = sha384_bytes(rtmr + h)

    result = {
        "schema_version": 1,
        "computed_at": datetime.now(timezone.utc).isoformat(),
        "sealed_state_hash": sealed_hash.hex(),
        "config_hash": config_hash.hex(),
        "binary_manifest_hash": image_meas["binary_manifest_hash"],
        "binary_manifest": image_meas["binary_manifest"],
        "expected_rtmr2": rtmr.hex(),
    }

    with open(args.output, "w") as f:
        json.dump(result, f, indent=2)

    print(f"Expected RTMR[2]: {rtmr.hex()}")
    print(f"Written to {args.output}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
