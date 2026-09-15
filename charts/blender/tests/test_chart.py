import subprocess
from pathlib import Path

import pytest
import yaml

CHART = Path(__file__).resolve().parents[1]


def render(*args):
    result = subprocess.run(
        ["helm", "template", "test-blender", str(CHART), "--namespace", "test", *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return {item["kind"]: item for item in yaml.safe_load_all(result.stdout) if item}


def test_cpu_workspace_has_no_gpu_or_mcp_exposure():
    resources = render()
    deployment = resources["Deployment"]["spec"]
    pod = deployment["template"]["spec"]
    container = pod["containers"][0]
    assert deployment["replicas"] == 1
    assert deployment["strategy"] == {"type": "Recreate"}
    assert not pod.get("runtimeClassName")
    assert "nvidia.com/gpu" not in container["resources"]["limits"]
    assert pod["automountServiceAccountToken"] is False
    assert "HTTPRoute" not in resources
    assert {port["port"] for port in resources["Service"]["spec"]["ports"]} == {
        3000,
        3001,
    }
    volumes = {volume["name"]: volume for volume in pod["volumes"]}
    assert volumes["shm"]["emptyDir"] == {"medium": "Memory", "sizeLimit": "1Gi"}
    assert "persistentVolumeClaim" in volumes["config"]
    assert "persistentVolumeClaim" in volumes["workspace"]
    assert "user-scripts" not in volumes


def test_nvidia_and_mcp_profile():
    resources = render(
        "-f", str(CHART / "profiles/nvidia.yaml"), "--set", "mcp.enabled=true"
    )
    pod = resources["Deployment"]["spec"]["template"]["spec"]
    container = pod["containers"][0]
    assert pod["runtimeClassName"] == "nvidia"
    assert container["resources"]["requests"]["nvidia.com/gpu"] == 1
    assert container["resources"]["limits"]["nvidia.com/gpu"] == 1
    env = {item["name"]: item["value"] for item in container["env"]}
    assert {"compute", "utility", "graphics", "video", "display"} == set(
        env["NVIDIA_DRIVER_CAPABILITIES"].split(",")
    )
    assert "NVIDIA_VISIBLE_DEVICES" not in env
    assert env["BLENDER_USER_SCRIPTS"] == "/opt/blender-user-scripts"
    init = pod["initContainers"][0]
    assert init["image"] == container["image"]
    assert {mount["mountPath"] for mount in init["volumeMounts"]} == {
        "/config",
        "/workspace",
        "/opt/blender-bootstrap",
        "/opt/blender-user-scripts",
    }
    assert all(port["port"] != 9876 for port in resources["Service"]["spec"]["ports"])


@pytest.mark.parametrize(
    "setting",
    [
        "components.main.deployment.replicas=2",
        "components.main.deployment.strategy.type=RollingUpdate",
        "components.main.hpa.enabled=true",
        "mcp.revision=main",
        "mcp.sha256=bad",
    ],
)
def test_rejects_unsafe_authoring_configuration(setting):
    result = subprocess.run(
        [
            "helm",
            "template",
            "test",
            str(CHART),
            "--set",
            "mcp.enabled=true",
            "--set",
            setting,
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "blender:" in result.stderr
