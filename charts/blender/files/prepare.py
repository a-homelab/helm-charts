import hashlib
import os
import re
import shutil
import zipfile
from pathlib import Path
from urllib.request import urlopen


def prepare():
    workspace = Path("/workspace")
    workspace.mkdir(parents=True, exist_ok=True)
    os.chown(workspace, int(os.environ["PUID"]), int(os.environ["PGID"]))
    if os.environ["MCP_ENABLED"] != "true":
        return

    version = os.environ["MCP_VERSION"]
    expected = os.environ["MCP_SHA256"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("MCP_VERSION must be a release version")
    if not re.fullmatch(r"[a-f0-9]{64}", expected):
        raise ValueError("MCP_SHA256 must be a SHA-256 digest")

    cache = Path("/config/blender-mcp-cache")
    cache.mkdir(parents=True, exist_ok=True)
    cached = cache / f"{expected}.zip"
    data = cached.read_bytes() if cached.exists() else None
    if data is None or hashlib.sha256(data).hexdigest() != expected:
        url = (
            "https://projects.blender.org/lab/blender_mcp/releases/download/"
            f"v{version}/mcp-{version}.zip"
        )
        with urlopen(url, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError("Blender MCP addon checksum mismatch")
        pending = cached.with_suffix(".tmp")
        pending.write_bytes(data)
        pending.replace(cached)

    scripts = Path("/opt/blender-user-scripts")
    extension = scripts / "extensions/mcp"
    if extension.exists():
        shutil.rmtree(extension)
    extension.mkdir(parents=True)
    with zipfile.ZipFile(cached) as archive:
        for member in archive.infolist():
            target = (extension / member.filename).resolve()
            if not target.is_relative_to(extension.resolve()):
                raise ValueError("Blender MCP archive contains an invalid path")
        archive.extractall(extension)
    (scripts / "startup").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(
        "/opt/blender-bootstrap/mcp_autostart.py",
        scripts / "startup/mcp_autostart.py",
    )


if __name__ == "__main__":
    prepare()
