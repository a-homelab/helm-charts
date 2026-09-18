import os
from pathlib import Path


def main() -> None:
    environment = Path("/config/blender-mcp-server/current")
    env = dict(os.environ)
    env["PATH"] = f"{environment / 'bin'}:{env.get('PATH', '')}"
    os.execve(
        environment / "bin/blender-mcp",
        ["blender-mcp", "--transport", "http", "--host", "0.0.0.0", "--port", "8000"],
        env,
    )


if __name__ == "__main__":
    main()
