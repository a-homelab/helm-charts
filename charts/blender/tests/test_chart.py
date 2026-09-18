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
    assert volumes["user-scripts"]["emptyDir"] == {}
    init_env = {item["name"]: item["value"] for item in pod["initContainers"][0]["env"]}
    assert init_env["MCP_ENABLED"] == "false"


def test_nvidia_and_mcp_example():
    resources = render(
        "-f", str(CHART / "examples/nvidia-values.yaml"), "--set", "mcp.enabled=true"
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
        "components.main.kind=StatefulSet",
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
    assert "schema" in result.stderr.lower()
    assert setting.split("=")[0].split(".")[-1] in result.stderr


def test_bootstrap_files_and_checksum_follow_values():
    resources = render()
    assert resources["ConfigMap"]["data"] == {
        name: (CHART / "files" / name).read_text()
        for name in ("prepare.py", "mcp_autostart.py", "verify_gpu.py")
    }
    changed = render(
        "--set-string",
        "appResources.configMap.bootstrap.data.prepare\\.py=custom bootstrap",
    )
    assert changed["ConfigMap"]["data"]["prepare.py"] == "custom bootstrap"
    before = resources["Deployment"]["spec"]["template"]["metadata"]["annotations"]
    after = changed["Deployment"]["spec"]["template"]["metadata"]["annotations"]
    assert before["checksum/blender-bootstrap"] != after["checksum/blender-bootstrap"]


def test_prepare_inherits_image_and_accepts_resource_overrides():
    resources = render(
        "--set-string",
        "components.main.container.image.tag=custom",
        "--set-string",
        "components.main.container.env.PUID=1234",
        "--set-string",
        "components.main.container.env.PGID=5678",
        "--set-string",
        "components.main.initContainers.prepare.resources.limits.memory=512Mi",
    )
    pod = resources["Deployment"]["spec"]["template"]["spec"]
    init = pod["initContainers"][0]
    assert init["image"] == pod["containers"][0]["image"]
    assert init["image"].endswith(":custom")
    assert init["resources"]["limits"]["memory"] == "512Mi"
    env = {item["name"]: item["value"] for item in init["env"]}
    assert (env["PUID"], env["PGID"]) == ("1234", "5678")


def test_disabled_mcp_does_not_require_valid_pins():
    resources = render("--set", "mcp.revision=unused", "--set", "mcp.sha256=unused")
    pod = resources["Deployment"]["spec"]["template"]["spec"]
    env = {item["name"]: item["value"] for item in pod["initContainers"][0]["env"]}
    assert env["MCP_ENABLED"] == "false"
