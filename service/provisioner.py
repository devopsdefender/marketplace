import logging

import requests

from config import DD_CONTROL_PLANE_URL, REQUIRE_ATTESTATION

log = logging.getLogger(__name__)


def verify_agent_attestation(agent_id):
    """Check if an agent has valid TDX attestation via the control plane."""
    try:
        resp = requests.get(
            f"{DD_CONTROL_PLANE_URL}/api/v1/agents/{agent_id}/attestation",
            timeout=10,
        )
        if resp.status_code == 404:
            return False
        resp.raise_for_status()
        return resp.json().get("status") == "verified"
    except Exception:
        log.exception("Attestation check failed for agent %s", agent_id)
        return False


def get_ready_agents():
    """List agents registered with the DD control plane.

    When REQUIRE_ATTESTATION is enabled, only returns agents with
    verified TDX attestation.
    """
    resp = requests.get(f"{DD_CONTROL_PLANE_URL}/api/v1/agents", timeout=10)
    resp.raise_for_status()
    agents = [a for a in resp.json() if a.get("registration_state") == "ready"]
    if REQUIRE_ATTESTATION:
        agents = [a for a in agents if verify_agent_attestation(a.get("id"))]
    return agents


def deploy_workload(app_name, image, ports=None, env=None):
    """Deploy a customer workload via the DD deploy API."""
    payload = {
        "image": image,
        "app_name": app_name,
        "app_version": "latest",
        "env": env or [],
        "skills": [],
        "ports": ports or [],
    }
    resp = requests.post(
        f"{DD_CONTROL_PLANE_URL}/api/v1/deploy",
        json=payload,
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def list_apps():
    """List running apps on the DD agent."""
    resp = requests.get(f"{DD_CONTROL_PLANE_URL}/api/v1/apps", timeout=10)
    resp.raise_for_status()
    return resp.json()
