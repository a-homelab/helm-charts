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
    assert not pod.get("runtimeClassName")
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
        "mcp.version=main",
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
    expected = {
        name: (CHART / "files" / name).read_text()
        for name in (
            "prepare.sh",
            "mcp_autostart.py",
            "verify_gpu.py",
            "sync_sources.sh",
        )
    }
    expected.update(
        {
            name: (CHART / "files/mcp-server" / name).read_text()
            for name in (
                "start_server.py",
                "requirements.txt",
            )
        }
    )
    assert resources["ConfigMap"]["data"] == expected
    changed = render(
        "--set-string",
        "appResources.configMap.bootstrap.data.prepare\\.sh=custom bootstrap",
    )
    assert changed["ConfigMap"]["data"]["prepare.sh"] == "custom bootstrap"
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
    resources = render("--set", "mcp.version=unused", "--set", "mcp.sha256=unused")
    pod = resources["Deployment"]["spec"]["template"]["spec"]
    env = {item["name"]: item["value"] for item in pod["initContainers"][0]["env"]}
    assert env["MCP_ENABLED"] == "false"


def test_http_sidecar_routing_workspace_and_gpu_isolation():
    resources = render(
        "-f",
        str(CHART / "examples/nvidia-values.yaml"),
        "--set",
        "mcp.enabled=true",
        "--set",
        "components.main.routes.mcp.enabled=true",
        "--set",
        "components.main.routes.mcp.hostnames[0]=blender.example.com",
    )
    pod = resources["Deployment"]["spec"]["template"]["spec"]
    sidecar = next(c for c in pod["containers"] if c["name"] == "mcp")
    assert sidecar["image"] == pod["containers"][0]["image"]
    assert "nvidia.com/gpu" not in sidecar["resources"]["limits"]
    mounts = {m["mountPath"]: m["name"] for m in sidecar["volumeMounts"]}
    assert mounts == {
        "/workspace": "workspace",
        "/tmp": "mcp-tmp",
        "/config": "config",
        "/opt/blender-bootstrap": "bootstrap",
    }
    assert sidecar["command"] == [
        "/lsiopy/bin/python3",
        "/opt/blender-bootstrap/start_server.py",
    ]
    assert sidecar["workingDir"] == "/workspace"
    assert sidecar["startupProbe"]["failureThreshold"] == 180
    assert sidecar["startupProbe"]["tcpSocket"]["port"] == "mcp"
    assert "livenessProbe" not in sidecar
    assert sidecar["securityContext"]["readOnlyRootFilesystem"] is True
    env = {e["name"]: e for e in sidecar["env"]}
    assert env["BLENDER_MCP_HOST"]["value"] == "127.0.0.1"
    assert "MCP_AUTH_TOKEN" not in env
    assert {p["port"] for p in resources["Service"]["spec"]["ports"]} == {
        3000,
        3001,
        8000,
    }
    rule = resources["HTTPRoute"]["spec"]["rules"][0]
    assert rule["backendRefs"][0]["port"] == 8000
    assert rule["matches"] == [{"path": {"type": "Exact", "value": "/"}}]
    assert rule["timeouts"]["backendRequest"] == "350s"


@pytest.mark.parametrize(
    "args",
    [
        ["--set", "mcp.server.enabled=true"],
        ["--set", "components.main.routes.mcp.enabled=true"],
    ],
)
def test_rejects_removed_server_toggle_and_route_without_mcp(args):
    result = subprocess.run(
        ["helm", "template", "test", str(CHART), *args],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "schema" in result.stderr.lower()


@pytest.mark.parametrize("enabled", [False, True])
def test_single_toggle_controls_addon_and_http_server(enabled):
    resources = render("--set", f"mcp.enabled={str(enabled).lower()}")
    pod = resources["Deployment"]["spec"]["template"]["spec"]
    assert [c["name"] for c in pod["containers"]] == (
        ["main", "mcp"] if enabled else ["main"]
    )
    assert (
        8000 in {p["port"] for p in resources["Service"]["spec"]["ports"]}
    ) == enabled
    assert ("mcp-tmp" in {v["name"] for v in pod["volumes"]}) == enabled
    env = {e["name"]: e["value"] for e in pod["initContainers"][0]["env"]}
    assert env["MCP_ENABLED"] == str(enabled).lower()
    assert "HTTPRoute" not in resources


@pytest.mark.parametrize("tag", ["future-blender", "sha256:" + "a" * 64])
def test_sidecar_inherits_image_and_persistent_cache_identity(tag):
    resources = render(
        "--set",
        "mcp.enabled=true",
        "--set-string",
        f"components.main.container.image.tag={tag}",
        "--set-string",
        "components.main.container.env.PUID=1234",
        "--set-string",
        "components.main.container.env.PGID=5678",
    )
    pod = resources["Deployment"]["spec"]["template"]["spec"]
    main, sidecar = pod["containers"]
    assert main["image"] == sidecar["image"] == pod["initContainers"][0]["image"]
    assert sidecar["securityContext"]["runAsUser"] == 1234
    assert sidecar["securityContext"]["runAsGroup"] == 5678
    prepare_env = {e["name"]: e["value"] for e in pod["initContainers"][0]["env"]}
    assert prepare_env["MCP_ENABLED"] == "true"
    assert prepare_env["MCP_IMAGE"] == main["image"]
    assert pod["initContainers"][0]["command"] == [
        "/bin/bash",
        "/opt/blender-bootstrap/prepare.sh",
    ]
    mounts = {m["name"]: m["mountPath"] for m in sidecar["volumeMounts"]}
    assert mounts["config"] == "/config"
    config = next(v for v in pod["volumes"] if v["name"] == "config")
    assert "persistentVolumeClaim" in config
