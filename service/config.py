import os

DD_CONTROL_PLANE_URL = os.environ.get("DD_CONTROL_PLANE_URL", "")
DATABASE_PATH = os.environ.get("DATABASE_PATH", "/data/capacity.db")
SERVICE_PORT = int(os.environ.get("PORT", "5000"))
REQUIRE_ATTESTATION = os.environ.get("REQUIRE_ATTESTATION", "false").lower() == "true"

NODE_TYPES = {
    "standard": {
        "name": "Standard",
        "vcpu": 8,
        "ram_gb": 16,
        "gpu": None,
        "btc_per_hour": "0.001",
    },
    "gpu": {
        "name": "GPU (H100)",
        "vcpu": 16,
        "ram_gb": 64,
        "gpu": "NVIDIA H100",
        "btc_per_hour": "0.01",
    },
}
