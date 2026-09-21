import json
import sys
from pathlib import Path

from github_token import remaining


def credential(request, config, token):
    allowed = {f"{config['owner']}/{repo['name']}" for repo in config["repositories"]}
    path = request.get("path", "").removesuffix(".git")
    if (
        request.get("protocol") != "https"
        or request.get("host") != "github.com"
        or path not in allowed
    ):
        return ""
    if remaining(token) <= 60:
        raise ValueError("GitHub token expired; wait for token renewal")
    return f"username=x-access-token\npassword={token['token']}\n\n"


def main():
    if sys.argv[1:] != ["get"]:
        return
    request = dict(line.rstrip("\n").split("=", 1) for line in sys.stdin if "=" in line)
    config = json.loads(Path("/opt/opencode/git.json").read_text())
    token = json.loads(Path("/run/github-token/token.json").read_text())
    sys.stdout.write(credential(request, config, token))


if __name__ == "__main__":
    main()
