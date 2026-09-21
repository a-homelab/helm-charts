import json
import subprocess
from pathlib import Path

import pytest
import yaml

CHART = Path(__file__).resolve().parents[1]


def render(*args):
    result = subprocess.run(
        ["helm", "template", "test-opencode", str(CHART), "--namespace", "test", *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return [item for item in yaml.safe_load_all(result.stdout) if item]


def one(resources, kind):
    return next(item for item in resources if item["kind"] == kind)


def test_server_defaults_are_private_persistent_and_unprivileged():
    resources = render()
    deployment = one(resources, "Deployment")["spec"]
    pod = deployment["template"]["spec"]
    assert "command" not in pod["containers"][0]
    assert "args" not in pod["containers"][0]
    assert deployment["replicas"] == 1
    assert deployment["strategy"] == {"type": "Recreate"}
    assert not pod["automountServiceAccountToken"]
    assert [item["name"] for item in pod["initContainers"]] == ["workspace"]
    assert pod["containers"][0]["image"].startswith(
        "ghcr.io/a-homelab/opencode-container:"
    )
    assert not any(item["kind"] == "HTTPRoute" for item in resources)
    assert pod["containers"][0]["securityContext"]["runAsNonRoot"]
    assert pod["containers"][0]["securityContext"]["readOnlyRootFilesystem"]
    assert one(resources, "Service")["spec"]["type"] == "ClusterIP"
    claims = [item for item in resources if item["kind"] == "PersistentVolumeClaim"]
    assert len(claims) == 2
    assert all(
        item["metadata"]["annotations"]["argocd.argoproj.io/sync-options"]
        == "Prune=false,Delete=false"
        for item in claims
    )


def test_github_private_key_is_only_mounted_by_token_renewer():
    resources = render(
        "--set",
        "git.enabled=true",
        "--set",
        "git.owner=example",
        "--set",
        "git.repositories[0].name=notes",
        "--set",
        "git.repositories[0].path=notes",
    )
    pod = one(resources, "Deployment")["spec"]["template"]["spec"]
    token, workspace = pod["initContainers"]
    assert token["name"] == "github-token"
    assert token["restartPolicy"] == "Always"
    assert token["startupProbe"]["exec"]["command"][-1] == "check"
    assert workspace["name"] == "workspace"
    assert [c["name"] for c in pod["containers"]] == ["main"]
    assert "restartPolicy" not in workspace
    assert token["image"] == workspace["image"] == pod["containers"][0]["image"]
    assert all(
        c["imagePullPolicy"] == "IfNotPresent"
        for c in [token, workspace, *pod["containers"]]
    )
    assert "github-app" in {mount["name"] for mount in token["volumeMounts"]}
    for container in [workspace, *pod["containers"]]:
        mounts = {mount["name"]: mount for mount in container["volumeMounts"]}
        assert "github-app" not in mounts
        assert mounts["github-token"]["readOnly"]
    assert (
        next(v for v in pod["volumes"] if v["name"] == "github-token")["emptyDir"][
            "medium"
        ]
        == "Memory"
    )


@pytest.mark.parametrize(
    "setting",
    [
        "components.main.deployment.replicas=2",
        "components.main.deployment.strategy.type=RollingUpdate",
        "components.main.hpa.enabled=true",
        "server.existingSecret=legacy",
        "git.enabled=true",
        "git.mcp.enabled=true",
        "tools.packages[0]=--allow-untrusted",
        "tools.packages[0]=git;whoami",
    ],
)
def test_invalid_configuration_is_rejected(setting):
    result = subprocess.run(
        ["helm", "template", "test", str(CHART), "--set", setting],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0


def test_scripts_in_configmap_match_sources():
    resources = render()
    data = next(
        item["data"]
        for item in resources
        if item["kind"] == "ConfigMap" and "git.json" in item["data"]
    )
    pod = one(resources, "Deployment")["spec"]["template"]["spec"]
    volume = next(v for v in pod["volumes"] if v["name"] == "bootstrap")
    mounted = {item["path"]: data[item["key"]] for item in volume["configMap"]["items"]}
    for path in (CHART / "files").rglob("*"):
        if path.suffix not in {".py", ".sh"}:
            continue
        assert mounted[path.relative_to(CHART / "files").as_posix()] == path.read_text()
    assert not any(path.startswith("skills/") for path in mounted)


def test_global_instructions_and_skills_use_a_readonly_config_directory():
    resources = render("-f", str(CHART / "examples/immutable-config-values.yaml"))
    pod = one(resources, "Deployment")["spec"]["template"]["spec"]
    container = pod["containers"][0]
    mount = next(m for m in container["volumeMounts"] if m["name"] == "configuration")
    assert mount["mountPath"] == "/opt/opencode-config"
    assert mount["readOnly"]
    assert "subPath" not in mount
    assert not any(
        item["mountPath"].startswith("/opt/opencode-defaults")
        for item in container["volumeMounts"]
    )
    env = {e["name"]: e.get("value") for e in container["env"]}
    assert "OPENCODE_CONFIG_DIR" not in env
    assert env["OPENCODE_CONFIG"] == "/opt/opencode-config/opencode.json"
    assert env["OPENCODE_CONFIG_PROJECT_DISABLE"] == "true"
    volume = next(v for v in pod["volumes"] if v["name"] == "configuration")
    config = next(
        r["data"]
        for r in resources
        if r["kind"] == "ConfigMap"
        and r["metadata"]["name"] == volume["configMap"]["name"]
    )
    assert config["purpose.md"]
    assert "AGENTS.md" not in config
    settings = json.loads(config["opencode.json"])
    assert (
        settings["agents"]["build"]["system"] == "{file:/opt/opencode-config/purpose.md}"
    )
    assert "instructions" not in settings
    assert json.loads(config["opencode.json"])["update"] == "disable"
    assert json.loads(config["opencode.json"])["share"] == "disabled"
    assert any(
        item["path"] == "skills/workspace-review/SKILL.md"
        for item in volume["configMap"]["items"]
    )


def test_configuration_change_rolls_the_pod():
    before = one(render(), "Deployment")["spec"]["template"]["metadata"]["annotations"]
    after = one(
        render("--set-string", "opencode.instructions=Different policy"), "Deployment"
    )["spec"]["template"]["metadata"]["annotations"]
    assert (
        before["checksum/opencode-configuration"]
        != after["checksum/opencode-configuration"]
    )


def test_github_uses_git_and_cli_without_an_mcp_bridge():
    resources = render(
        "--set",
        "git.enabled=true",
        "--set",
        "git.owner=example",
        "--set",
        "git.repositories[0].name=notes",
        "--set",
        "git.repositories[0].path=notes",
        "--set",
        "opencode.config.mcp.servers.blender.type=remote",
        "--set",
        "opencode.config.mcp.servers.blender.url=http://blender:8000/",
    )
    pod = one(resources, "Deployment")["spec"]["template"]["spec"]
    assert [c["name"] for c in pod["initContainers"]] == [
        "github-token",
        "workspace",
    ]
    assert not any(v["name"].startswith("github-mcp") for v in pod["volumes"])
    main = pod["containers"][0]
    env = {e["name"]: e.get("value") for e in main["env"]}
    assert "PATH" not in env
    assert env["GH_CONFIG_DIR"] == "/run/github-token/gh"
    assert "GH_TOKEN" not in env
    data = next(
        r["data"]
        for r in resources
        if r["kind"] == "ConfigMap" and "opencode.json" in r["data"]
    )
    servers = json.loads(data["opencode.json"])["mcp"]["servers"]
    assert servers == {"blender": {"type": "remote", "url": "http://blender:8000/"}}
    bootstrap = next(v for v in pod["volumes"] if v["name"] == "bootstrap")
    assert not any(
        i["path"].startswith("bin/") for i in bootstrap["configMap"]["items"]
    )
    mount = next(m for m in main["volumeMounts"] if m["name"] == "github-token")
    assert mount["readOnly"]


def test_tools_are_in_the_image_without_runtime_installation():
    resources = render()
    pod = one(resources, "Deployment")["spec"]["template"]["spec"]
    assert [c["name"] for c in pod["initContainers"]] == ["workspace"]
    assert not any(v["name"] == "tools" for v in pod["volumes"])
    for container in [*pod["initContainers"], *pod["containers"]]:
        assert container["image"] == pod["containers"][0]["image"]
        assert container["securityContext"]["runAsUser"] == 65532
        assert container["securityContext"]["readOnlyRootFilesystem"]
        assert not any(m["mountPath"] == "/tools" for m in container["volumeMounts"])
        env = {e["name"] for e in container["env"]}
        assert not env & {
            "LD_LIBRARY_PATH",
            "PYTHONHOME",
            "GIT_EXEC_PATH",
            "PATH",
            "HOME",
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "XDG_CACHE_HOME",
            "XDG_STATE_HOME",
            "OPENCODE_CONFIG_DIR",
            "PYTHONDONTWRITEBYTECODE",
            "UV_PYTHON_DOWNLOADS",
            "UV_CACHE_DIR",
            "UV_LINK_MODE",
        }
    data = next(
        r["data"]
        for r in resources
        if r["kind"] == "ConfigMap" and "git.json" in r["data"]
    )
    assert "packages" not in data


@pytest.mark.parametrize("secret", ["opencode-server", "mi-casa-opencode-server"])
def test_password_uses_the_configured_secret(secret):
    resources = render(
        "--set",
        f"components.main.container.env.OPENCODE_PASSWORD.valueFrom.secretKeyRef.name={secret}",
    )
    container = one(resources, "Deployment")["spec"]["template"]["spec"]["containers"][
        0
    ]
    password = next(
        item for item in container["env"] if item["name"] == "OPENCODE_PASSWORD"
    )
    assert password["valueFrom"]["secretKeyRef"] == {"name": secret, "key": "password"}
