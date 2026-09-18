import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

CHART = Path(__file__).resolve().parents[1]


@pytest.fixture
def bootstrap(tmp_path):
    project = tmp_path / "bootstrap"
    project.mkdir()
    shutil.copyfile(CHART / "files/prepare.sh", project / "prepare.sh")
    (project / "requirements.txt").write_text("blender-mcp")
    build = tmp_path / "build_version"
    build.write_text("build-one")
    cache = tmp_path / "cache"
    log = tmp_path / "commands.jsonl"
    fake = tmp_path / "python"
    fake.write_text(
        f"#!{sys.executable}\n"
        """import json, os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["TEST_LOG"]).open("a") as stream:
    stream.write(json.dumps(args) + "\\n")
if args[:2] == ["-m", "venv"]:
    env = Path(args[-1])
    (env / "bin").mkdir(parents=True)
    shutil.copyfile(__file__, env / "bin/python")
    (env / "bin/python").chmod(0o755)
elif "install" in args:
    if Path(os.environ["TEST_FAILURE"]).exists():
        sys.exit(1)
    server = Path(__file__).parent / "blender-mcp"
    server.touch()
    server.chmod(0o755)
elif args[0] == "-c" and "platform" in args[1]:
    print("test-python")
"""
    )
    fake.chmod(0o755)
    failure = tmp_path / "fail"

    def run(image="image", check=True):
        return subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; blender_python=$2; blender_build=$3; prepare_environment "$4" "$5" "$6"',
                "test",
                str(project / "prepare.sh"),
                str(fake),
                str(build),
                str(project),
                str(cache),
                image,
            ],
            env={**os.environ, "TEST_LOG": str(log), "TEST_FAILURE": str(failure)},
            check=check,
            capture_output=True,
            text=True,
            timeout=20,
        )

    return run, project, build, cache, log, failure


def test_prepare_reuses_ready_environment_without_pip(bootstrap):
    run, _, _, cache, log, _ = bootstrap
    run()
    first = (cache / "current").resolve()
    ready_time = (first / ".ready").stat().st_mtime_ns
    log.write_text("")
    result = run()
    assert "Reusing MCP environment" in result.stdout
    assert (cache / "current").resolve() == first
    assert (first / ".ready").stat().st_mtime_ns == ready_time
    commands = [json.loads(line) for line in log.read_text().splitlines()]
    assert len(commands) == 1
    assert commands[0][0] == "-c"


def test_image_build_requirements_and_script_changes_create_new_environments(bootstrap):
    run, project, build, cache, _, _ = bootstrap
    paths = []
    run()
    paths.append((cache / "current").resolve())
    run(image="new-image")
    paths.append((cache / "current").resolve())
    build.write_text("build-two")
    run(image="new-image")
    paths.append((cache / "current").resolve())
    (project / "requirements.txt").write_text("new source")
    run(image="new-image")
    paths.append((cache / "current").resolve())
    with (project / "prepare.sh").open("a") as stream:
        stream.write("\n")
    run(image="new-image")
    paths.append((cache / "current").resolve())
    assert len(set(paths)) == 5
    assert all((path / ".ready").exists() for path in paths)


def test_failed_install_preserves_current_and_retry_rebuilds(bootstrap):
    run, project, _, cache, _, failure = bootstrap
    run()
    previous = (cache / "current").resolve()
    (project / "requirements.txt").write_text("new source")
    failure.touch()
    assert run(check=False).returncode != 0
    assert (cache / "current").resolve() == previous
    incomplete = next(p for p in (cache / "environments").iterdir() if p != previous)
    assert not (incomplete / ".ready").exists()
    marker = incomplete / "partial-install"
    marker.touch()
    failure.unlink()
    run()
    assert not marker.exists()
    assert (cache / "current").resolve() == incomplete
    assert (incomplete / ".ready").exists()


def test_disabled_prepare_does_not_invoke_python(tmp_path):
    workspace = tmp_path / "workspace"
    subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; blender_workspace=$2; blender_python=/does-not-exist; prepare',
            "test",
            str(CHART / "files/prepare.sh"),
            str(workspace),
        ],
        env={
            **os.environ,
            "MCP_ENABLED": "false",
            "PUID": str(os.getuid()),
            "PGID": str(os.getgid()),
        },
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert workspace.is_dir()


def test_launcher_executes_prepared_server(monkeypatch):
    source = CHART / "files/mcp-server/start_server.py"
    spec = importlib.util.spec_from_file_location("start_server", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    calls = []
    monkeypatch.setattr(module.os, "execve", lambda *args: calls.append(args))
    monkeypatch.setenv("BLENDER_MCP_HOST", "127.0.0.1")
    module.main()
    executable, arguments, env = calls[0]
    assert str(executable) == "/config/blender-mcp-server/current/bin/blender-mcp"
    assert arguments == [
        "blender-mcp",
        "--transport",
        "http",
        "--host",
        "0.0.0.0",
        "--port",
        "8000",
    ]
    assert env["PATH"].startswith("/config/blender-mcp-server/current/bin:")
    assert env["BLENDER_MCP_HOST"] == "127.0.0.1"
