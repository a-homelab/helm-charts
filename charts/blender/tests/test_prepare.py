import hashlib
import io
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

CHART = Path(__file__).resolve().parents[1]


def archive_bytes(name="__init__.py"):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(name, "extension")
    return buffer.getvalue()


@pytest.fixture
def bootstrap(tmp_path):
    project = tmp_path / "bootstrap"
    project.mkdir()
    shutil.copyfile(CHART / "files/prepare.sh", project / "prepare.sh")
    (project / "mcp_autostart.py").write_text("bootstrap")
    downloaded = tmp_path / "download.zip"
    downloaded.write_bytes(archive_bytes())
    log = tmp_path / "downloads"
    tools = tmp_path / "bin"
    tools.mkdir()
    curl = tools / "curl"
    curl.write_text(
        f"#!{sys.executable}\n"
        + """import os, shutil, sys
from pathlib import Path
with Path(os.environ["TEST_DOWNLOAD_LOG"]).open("a") as stream:
    stream.write(sys.argv[-1] + "\\n")
shutil.copyfile(os.environ["TEST_DOWNLOAD"], sys.argv[sys.argv.index("--output") + 1])
"""
    )
    curl.chmod(0o755)

    def run(expected=None, check=True):
        return subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; blender_python=$2; prepare_addon "$3" "$4" "$5"',
                "test",
                str(project / "prepare.sh"),
                sys.executable,
                str(project),
                str(tmp_path / "cache"),
                str(tmp_path / "scripts"),
            ],
            env={
                **os.environ,
                "PATH": f"{tools}:{os.environ['PATH']}",
                "MCP_VERSION": "1.0.3",
                "MCP_SHA256": expected
                or hashlib.sha256(downloaded.read_bytes()).hexdigest(),
                "TEST_DOWNLOAD": str(downloaded),
                "TEST_DOWNLOAD_LOG": str(log),
            },
            check=check,
            capture_output=True,
            text=True,
            timeout=20,
        )

    return run, tmp_path, downloaded, log


def test_download_and_verified_offline_cache(bootstrap):
    run, root, _, log = bootstrap
    run()
    run()
    assert log.read_text().splitlines() == [
        "https://projects.blender.org/lab/blender_mcp/releases/download/v1.0.3/mcp-1.0.3.zip"
    ]
    assert (root / "scripts/extensions/mcp/__init__.py").read_text() == "extension"
    assert (root / "scripts/startup/mcp_autostart.py").read_text() == "bootstrap"


def test_rejects_corrupt_download(bootstrap):
    run, root, _, _ = bootstrap
    assert run(expected="0" * 64, check=False).returncode != 0
    assert not (root / "scripts/extensions/mcp").exists()
    assert not list((root / "cache").glob("*.zip"))


def test_rejects_archive_path_escape(bootstrap):
    run, root, downloaded, _ = bootstrap
    downloaded.write_bytes(archive_bytes("../escaped.py"))
    result = run(check=False)
    assert result.returncode != 0
    assert "invalid path" in result.stderr
    assert not (root / "scripts/extensions/escaped.py").exists()
