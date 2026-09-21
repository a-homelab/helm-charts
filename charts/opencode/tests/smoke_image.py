import os
import secrets
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import yaml

CHART = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    result = subprocess.run(
        list(args), check=False, capture_output=True, text=True, timeout=120, **kwargs
    )
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout.strip()


def main():
    password = secrets.token_urlsafe(24)
    rendered = run(
        "helm",
        "template",
        "smoke",
        str(CHART),
        "-f",
        str(CHART / "examples/immutable-config-values.yaml"),
        "--set",
        "git.enabled=true",
        "--set",
        "git.owner=example",
        "--set",
        "git.repositories[0].name=notes",
        "--set",
        "git.repositories[0].path=notes",
        "--set",
        "opencode.config.model=openai/gpt-4.1-mini",
        "--set",
        "opencode.config.providers.openai.settings.baseURL=http://127.0.0.1:4097/v1",
        "--set",
        "opencode.config.providers.openai.settings.transport=http",
    )
    resources = [item for item in yaml.safe_load_all(rendered) if item]
    configs = {
        item["metadata"]["name"]: item["data"]
        for item in resources
        if item["kind"] == "ConfigMap"
    }
    deployment = next(item for item in resources if item["kind"] == "Deployment")
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    image = sys.argv[1] if len(sys.argv) > 1 else container["image"]
    volumes = deployment["spec"]["template"]["spec"]["volumes"]
    name = "opencode-smoke-" + secrets.token_hex(5)
    with tempfile.TemporaryDirectory(prefix="opencode-smoke-") as directory:
        path = Path(directory)
        path.chmod(0o755)
        for volume in volumes:
            if "configMap" not in volume:
                continue
            mount = path / volume["name"]
            mount.mkdir()
            data = configs[volume["configMap"]["name"]]
            items = volume["configMap"].get(
                "items", [{"key": key, "path": key} for key in data]
            )
            for item in items:
                destination = mount / item["path"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(data[item["key"]])
        (path / "bootstrap/smoke-git.json").write_text('{"enabled": false}')
        token_dir = path / "token"
        token_dir.mkdir()
        sys.path.insert(0, str(CHART / "files/services/github"))
        from github_token import write_token

        def rotate(value, minutes=60):
            write_token(
                token_dir / "token.json",
                {
                    "token": value,
                    "expires_at": (
                        datetime.now(timezone.utc) + timedelta(minutes=minutes)
                    ).strftime("%Y-%m-%dT%H:%M:%SZ"),
                },
            )
            (token_dir / "gh").chmod(0o755)
            (token_dir / "gh/hosts.yml").chmod(0o444)
            (token_dir / "gh/config.yml").chmod(0o444)
            (token_dir / "token.json").chmod(0o444)

        rotate("fixture-first-token")
        args = [
            "docker",
            "run",
            "--detach",
            "--name",
            name,
            "--user",
            "65532:65532",
            "--read-only",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "--tmpfs",
            "/state:uid=65532,gid=65532,mode=0700",
            "--tmpfs",
            "/workspace:uid=65532,gid=65532,mode=0700",
            "--tmpfs",
            "/tmp:uid=65532,gid=65532,mode=0700",
            "--mount",
            f"type=bind,src={path / 'bootstrap'},dst=/opt/opencode,readonly",
            "--mount",
            f"type=bind,src={path / 'configuration'},dst=/opt/opencode-config,readonly",
            "--mount",
            f"type=bind,src={token_dir},dst=/run/github-token,readonly",
            "--env",
            "OPENCODE_PASSWORD",
            "--env",
            "OPENAI_API_KEY=fixture-no-provider-access",
        ]
        for item in container["env"]:
            if "value" in item:
                args += ["--env", f"{item['name']}={item['value']}"]
        args.append(image)
        try:
            run(*args, env={**os.environ, "OPENCODE_PASSWORD": password})
            run(
                "docker",
                "exec",
                name,
                "/bin/sh",
                "/opt/opencode/bootstrap/workspace.sh",
                "/opt/opencode/smoke-git.json",
            )
            run(
                "docker",
                "exec",
                name,
                "git",
                "init",
                "--initial-branch=main",
                "/workspace",
            )
            for _ in range(60):
                result = subprocess.run(
                    [
                        "docker",
                        "exec",
                        name,
                        *container["startupProbe"]["exec"]["command"],
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=False,
                )
                if result.returncode == 0:
                    break
                time.sleep(1)
            else:
                raise RuntimeError(
                    "OpenCode did not become healthy: " + run("docker", "logs", name)
                )
            check = """import json, os, urllib.request, urllib.error, urllib.parse, base64, time
base = 'http://127.0.0.1:4096/api'
try:
    urllib.request.urlopen(base + '/session', timeout=10)
    raise AssertionError('Unauthenticated session access succeeded')
except urllib.error.HTTPError as error:
    assert error.code == 401
auth = base64.b64encode(('opencode:' + os.environ['OPENCODE_PASSWORD']).encode()).decode()
headers = {'Authorization': 'Basic ' + auth, 'Content-Type': 'application/json'}
request = urllib.request.Request('http://127.0.0.1:4096/', headers=headers)
with urllib.request.urlopen(request, timeout=30) as response:
    assert response.status == 200
    assert 'text/html' in response.headers['Content-Type']
request = urllib.request.Request(base + '/session', data=b'{"title":"smoke","location":{"directory":"/workspace"}}', headers=headers)
with urllib.request.urlopen(request, timeout=30) as response:
    session = json.load(response)['data']
    assert session['id']
request = urllib.request.Request(base + '/session', headers=headers)
with urllib.request.urlopen(request, timeout=30) as response:
    assert any(item['id'] == session['id'] for item in json.load(response)['data'])
request = urllib.request.Request(base + '/info', headers=headers)
with urllib.request.urlopen(request, timeout=30) as response:
    assert json.load(response)['version'] == '2.0.11'
query = urllib.parse.urlencode({'location[directory]': '/workspace'})
request = urllib.request.Request(base + '/skill?' + query, headers=headers)
for attempt in range(20):
    with urllib.request.urlopen(request, timeout=30) as response:
        if json.load(response)['data']:
            break
    time.sleep(0.5)
with urllib.request.urlopen(request, timeout=30) as response:
    skills = json.load(response)['data']
    assert any(skill['name'] == 'workspace-review' for skill in skills), skills
from pathlib import Path
request = urllib.request.Request(base + '/agent/build?' + query, headers=headers)
with urllib.request.urlopen(request, timeout=30) as response:
    agent = json.load(response)['data']
    assert agent['system'] == Path('/opt/opencode-config/purpose.md').read_text().strip(), agent
assert os.environ['HOME'] == '/state'
assert os.environ['XDG_CONFIG_HOME'] == '/state/config'
assert os.environ['XDG_DATA_HOME'] == '/state/data'
assert os.environ['XDG_CACHE_HOME'] == '/state/cache'
assert os.environ['XDG_STATE_HOME'] == '/state/state'
assert os.environ['UV_CACHE_DIR'] == '/state/cache/uv'
assert os.environ['UV_PYTHON_DOWNLOADS'] == 'never'
assert os.environ['OPENCODE_CONFIG_DIR'] == '/opt/opencode-defaults'
assert os.environ['PYTHONDONTWRITEBYTECODE'] == '1'
assert Path.cwd() == Path('/workspace')
guide = Path('/opt/opencode-defaults/AGENTS.md')
assert 'uv run --project /opt/agent-toolkit --no-sync' in guide.read_text()
assert not os.access(guide, os.W_OK)
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
captured = []
class CaptureProvider(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        captured.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        body = b'{"error":{"message":"Fixture request captured","type":"invalid_request_error"}}'
        self.send_response(400)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
provider = ThreadingHTTPServer(('127.0.0.1', 4097), CaptureProvider)
Thread(target=provider.serve_forever, daemon=True).start()
def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)
try:
    request = urllib.request.Request(
        base + '/session/' + session['id'] + '/prompt',
        data=json.dumps({'text': 'Verify layered instruction fixture.'}).encode(),
        headers=headers,
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        assert response.status == 200
    purpose = Path('/opt/opencode-config/purpose.md').read_text().strip()
    for attempt in range(100):
        requests = ['\\n'.join(strings(item)) for item in captured]
        if any(text.count(purpose) == 1 and text.count(guide.read_text().strip()) == 1 for text in requests):
            break
        time.sleep(0.2)
    else:
        raise AssertionError(f'Image guide and deployment purpose were not both sent to the provider ({len(captured)} requests)')
finally:
    provider.shutdown()
    provider.server_close()
import subprocess
subprocess.run([
    'uv', 'run', '--project', '/opt/agent-toolkit', '--no-sync', '--offline',
    'python', '-c', 'import requests, pandas, lxml.etree, pydantic; '
    'assert pandas.DataFrame({"value": [1, 2]}).value.sum() == 3',
], check=True)
assert os.getuid() == 65532
assert not Path('/run/github-app').exists()
try:
    Path('/run/github-token/token.json').write_text('changed')
    raise AssertionError('Token mount was writable')
except OSError:
    pass
try:
    Path('/run/github-token/gh/hosts.yml').write_text('changed')
    raise AssertionError('GitHub CLI credentials were writable')
except OSError:
    pass
tool = Path('/usr/bin/git')
try:
    with tool.open('ab') as stream:
        stream.write(b'changed')
    raise AssertionError('Managed tool was writable')
except OSError:
    pass
for file in ['purpose.md', 'opencode.json', 'skills/workspace-review/SKILL.md']:
    target = Path('/opt/opencode-config') / file
    assert target.read_text()
    try:
        target.write_text('unauthorized change')
        raise AssertionError('Configuration was writable')
    except OSError:
        pass
"""
            try:
                run("docker", "exec", name, "python3", "-c", check)
            except RuntimeError as error:
                result = subprocess.run(
                    ["docker", "logs", name],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                raise RuntimeError(
                    str(error) + "\nContainer log:\n" + result.stdout + result.stderr
                ) from None
            run("docker", "exec", name, "git", "--version")
            assert (
                run(
                    "docker",
                    "exec",
                    name,
                    "realpath",
                    "-m",
                    "/workspace/not/yet/present",
                )
                == "/workspace/not/yet/present"
            )
            for value in ["fixture-first-token", "fixture-rotated-token"]:
                rotate(value)
                assert (
                    run(
                        "docker",
                        "exec",
                        name,
                        "gh",
                        "auth",
                        "token",
                        "--hostname",
                        "github.com",
                    )
                    == value
                )
                assert (
                    run(
                        "docker",
                        "exec",
                        "-i",
                        name,
                        "git",
                        "credential",
                        "fill",
                        input="protocol=https\nhost=github.com\npath=example/notes.git\n\n",
                    ).splitlines()[-1]
                    == "password=" + value
                )
            rotate("fixture-expired-token", minutes=-1)
            result = subprocess.run(
                ["docker", "exec", "-i", name, "git", "credential", "fill"],
                input="protocol=https\nhost=github.com\npath=example/notes.git\n\n",
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            assert result.returncode != 0
            assert "fixture-expired-token" not in result.stdout + result.stderr
            (token_dir / "gh/hosts.yml").unlink()
            result = subprocess.run(
                [
                    "docker",
                    "exec",
                    name,
                    "gh",
                    "auth",
                    "token",
                    "--hostname",
                    "github.com",
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            assert result.returncode != 0
            assert not result.stdout
            rotate("fixture-current-token")
            assert (
                run("docker", "exec", name, "/bin/sh", "-c", "command -v gh")
                == "/usr/bin/gh"
            )
            run("docker", "exec", name, "gh", "--version")
            run("docker", "exec", name, "openssl", "version")
            run(
                "docker",
                "exec",
                name,
                "git",
                "ls-remote",
                "https://github.com/anomalyco/opencode.git",
                "HEAD",
            )
            print(
                "OK: OpenCode v2, native gh config rotation, Git token rotation and expiry, isolated App key, read-only tools/config, layered image/purpose instructions, API, skills and HTTPS Git"
            )
        finally:
            subprocess.run(
                ["docker", "rm", "--force", name],
                capture_output=True,
                timeout=30,
                check=False,
            )


if __name__ == "__main__":
    main()
