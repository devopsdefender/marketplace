import requests

from config import DD_CONTROL_PLANE_URL


def get_ready_agents():
    """List agents registered with the DD control plane."""
    resp = requests.get(f"{DD_CONTROL_PLANE_URL}/api/v1/agents", timeout=10)
    resp.raise_for_status()
    return [a for a in resp.json() if a.get("registration_state") == "ready"]


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
