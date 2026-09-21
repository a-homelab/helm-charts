import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path


def encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=")


def mint(config, secret_dir):
    now = int(time.time())
    header = encode(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = encode(
        json.dumps(
            {
                "iat": now - 60,
                "exp": now + 540,
                "iss": (secret_dir / "app-id").read_text().strip(),
            }
        ).encode()
    )
    message = header + b"." + payload
    signature = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(secret_dir / "private-key")],
        input=message,
        capture_output=True,
        check=True,
    ).stdout
    jwt = (message + b"." + encode(signature)).decode()
    installation = (secret_dir / "installation-id").read_text().strip()
    if not installation.isdecimal():
        raise ValueError("Invalid installation ID")
    permissions = {"contents": "write", "pull_requests": "write"}
    request = urllib.request.Request(
        f"https://api.github.com/app/installations/{installation}/access_tokens",
        data=json.dumps(
            {
                "repositories": [repo["name"] for repo in config["repositories"]],
                "permissions": permissions,
            }
        ).encode(),
        headers={
            "Authorization": f"Bearer {jwt}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "opencode-chart",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.load(response)
    return {"token": result["token"], "expires_at": result["expires_at"]}


def remaining(token):
    return (
        datetime.fromisoformat(token["expires_at"].replace("Z", "+00:00")).timestamp()
        - time.time()
    )


def write_json(path, value):
    descriptor, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, 0o640)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def write_token(path, token):
    gh_config = path.parent / "gh"
    gh_config.mkdir(mode=0o750, exist_ok=True)
    # gh cannot migrate configuration on its read-only credential mount.
    write_json(gh_config / "config.yml", {"version": "1"})
    write_json(
        gh_config / "hosts.yml",
        {"github.com": {"oauth_token": token["token"], "git_protocol": "https"}},
    )
    write_json(path, token)


def main():
    path = Path("/run/github-token/token.json")
    if sys.argv[1:] == ["check"]:
        try:
            return 0 if remaining(json.loads(path.read_text())) > 60 else 1
        except (OSError, ValueError, KeyError):
            return 1
    config = json.loads(Path("/opt/opencode/git.json").read_text())
    while True:
        try:
            token = mint(config, Path("/run/github-app"))
            if remaining(token) < 120:
                raise ValueError("Token expires too soon")
            write_token(path, token)
            print("GitHub installation token renewed", flush=True)
            time.sleep(max(30, min(2400, remaining(token) - 600)))
        except (
            OSError,
            ValueError,
            KeyError,
            subprocess.SubprocessError,
            urllib.error.URLError,
        ):
            print(
                "GitHub token renewal failed; retrying in 30 seconds",
                file=sys.stderr,
                flush=True,
            )
            time.sleep(30)


if __name__ == "__main__":
    sys.exit(main())
