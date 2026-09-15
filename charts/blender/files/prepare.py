import hashlib
import os
import re
import shutil
from pathlib import Path
from urllib.request import urlopen


def prepare():
    workspace = Path("/workspace")
    workspace.mkdir(parents=True, exist_ok=True)
    os.chown(workspace, int(os.environ["PUID"]), int(os.environ["PGID"]))
    if os.environ["MCP_ENABLED"] != "true":
        return

    revision = os.environ["MCP_REVISION"]
    expected = os.environ["MCP_SHA256"]
    if not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise ValueError("MCP_REVISION must be a full Git commit SHA")
    if not re.fullmatch(r"[a-f0-9]{64}", expected):
        raise ValueError("MCP_SHA256 must be a SHA-256 digest")

    cache = Path("/config/blender-mcp-cache")
    cache.mkdir(parents=True, exist_ok=True)
    cached = cache / f"{expected}.py"
    data = cached.read_bytes() if cached.exists() else None
    if data is None or hashlib.sha256(data).hexdigest() != expected:
        url = f"https://raw.githubusercontent.com/ahujasid/blender-mcp/{revision}/addon.py"
        with urlopen(url, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError("Blender MCP addon checksum mismatch")
        pending = cached.with_suffix(".tmp")
        pending.write_bytes(data)
        pending.replace(cached)

    scripts = Path("/opt/blender-user-scripts")
    (scripts / "addons").mkdir(parents=True, exist_ok=True)
    (scripts / "startup").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(cached, scripts / "addons/blender_mcp.py")
    shutil.copyfile(
        "/opt/blender-bootstrap/mcp_autostart.py",
        scripts / "startup/mcp_autostart.py",
    )


if __name__ == "__main__":
    prepare()
