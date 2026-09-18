import hashlib
import importlib.util
import io
import zipfile
from pathlib import Path

import pytest


@pytest.fixture
def bootstrap(tmp_path, monkeypatch):
    source = Path(__file__).resolve().parents[1] / "files/prepare.py"
    spec = importlib.util.spec_from_file_location("prepare", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "Path", lambda path: tmp_path / path.lstrip("/"))
    monkeypatch.setattr(module.os, "chown", lambda *args: None)
    for key, value in {
        "PUID": "1000",
        "PGID": "1000",
        "MCP_ENABLED": "true",
        "MCP_VERSION": "1.0.3",
    }.items():
        monkeypatch.setenv(key, value)
    startup = tmp_path / "opt/blender-bootstrap/mcp_autostart.py"
    startup.parent.mkdir(parents=True)
    startup.write_text("bootstrap")
    copyfile = module.shutil.copyfile
    monkeypatch.setattr(
        module.shutil,
        "copyfile",
        lambda src, dst: copyfile(tmp_path / src.lstrip("/"), dst),
    )
    return module, tmp_path


def archive_bytes(name="__init__.py"):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(name, "extension")
    return buffer.getvalue()


def test_download_and_verified_offline_cache(bootstrap, monkeypatch):
    module, root = bootstrap
    data = archive_bytes()
    monkeypatch.setenv("MCP_SHA256", hashlib.sha256(data).hexdigest())
    urls = []

    def download(url, timeout):
        urls.append(url)
        return io.BytesIO(data)

    monkeypatch.setattr(module, "urlopen", download)
    module.prepare()
    module.prepare()
    assert urls == [
        "https://projects.blender.org/lab/blender_mcp/releases/download/v1.0.3/mcp-1.0.3.zip"
    ]
    assert (
        root / "opt/blender-user-scripts/extensions/mcp/__init__.py"
    ).read_text() == "extension"
    assert (
        root / "opt/blender-user-scripts/startup/mcp_autostart.py"
    ).read_text() == "bootstrap"


def test_rejects_corrupt_download(bootstrap, monkeypatch):
    module, root = bootstrap
    monkeypatch.setenv("MCP_SHA256", "0" * 64)
    monkeypatch.setattr(
        module, "urlopen", lambda *args, **kwargs: io.BytesIO(archive_bytes())
    )
    with pytest.raises(ValueError, match="checksum mismatch"):
        module.prepare()
    assert not (root / "opt/blender-user-scripts/extensions/mcp").exists()


def test_rejects_archive_path_escape(bootstrap, monkeypatch):
    module, root = bootstrap
    data = archive_bytes("../escaped.py")
    monkeypatch.setenv("MCP_SHA256", hashlib.sha256(data).hexdigest())
    monkeypatch.setattr(module, "urlopen", lambda *args, **kwargs: io.BytesIO(data))
    with pytest.raises(ValueError, match="invalid path"):
        module.prepare()
    assert not (root / "opt/blender-user-scripts/extensions/escaped.py").exists()
