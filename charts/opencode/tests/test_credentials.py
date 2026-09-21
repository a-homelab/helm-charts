import importlib.util
import io
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest
import yaml

FILES = Path(__file__).resolve().parents[1] / "files/services/github"
sys.path.insert(0, str(FILES))
spec = importlib.util.spec_from_file_location(
    "git_credentials", FILES / "git_credentials.py"
)
credentials = importlib.util.module_from_spec(spec)
spec.loader.exec_module(credentials)
import github_token
from github_token import write_token


def token(minutes=60):
    return {
        "token": "fixture-token",
        "expires_at": (
            datetime.now(timezone.utc) + timedelta(minutes=minutes)
        ).isoformat(),
    }


CONFIG = {"owner": "example", "repositories": [{"name": "notes"}]}


@pytest.mark.parametrize("path", ["example/notes", "example/notes.git"])
def test_git_authenticates_only_the_allowed_repository(path):
    assert credentials.credential(
        {"protocol": "https", "host": "github.com", "path": path}, CONFIG, token()
    ) == ("username=x-access-token\npassword=fixture-token\n\n")


@pytest.mark.parametrize(
    "target",
    [
        {"protocol": "http", "host": "github.com", "path": "example/notes"},
        {"protocol": "https", "host": "github.com.evil.test", "path": "example/notes"},
        {"protocol": "https", "host": "github.com", "path": "example/private"},
        {"protocol": "https", "host": "github.com"},
    ],
)
def test_does_not_offer_credentials_to_other_targets(target):
    assert credentials.credential(target, CONFIG, token()) == ""


def test_expired_tokens_fail_closed():
    with pytest.raises(ValueError, match="expired"):
        credentials.credential(
            {"protocol": "https", "host": "github.com", "path": "example/notes"},
            CONFIG,
            token(-1),
        )


def test_rotation_replaces_token_atomically_with_restricted_permissions(tmp_path):
    path = tmp_path / "token.json"
    old = token()
    write_token(path, old)
    new = {**token(), "token": "rotated-fixture"}
    write_token(path, new)
    assert json.loads(path.read_text()) == new
    assert path.stat().st_mode & 0o777 == 0o640
    assert set(tmp_path.iterdir()) == {path, tmp_path / "gh"}
    gh_config = tmp_path / "gh/hosts.yml"
    assert yaml.safe_load(gh_config.read_text()) == {
        "github.com": {"oauth_token": "rotated-fixture", "git_protocol": "https"}
    }
    assert gh_config.stat().st_mode & 0o777 == 0o640
    assert (tmp_path / "gh").stat().st_mode & 0o777 == 0o750
    assert yaml.safe_load((tmp_path / "gh/config.yml").read_text()) == {"version": "1"}
    assert set((tmp_path / "gh").iterdir()) == {gh_config, tmp_path / "gh/config.yml"}


def test_shared_token_requests_only_repository_contents_and_pr_writes(
    tmp_path, monkeypatch
):
    (tmp_path / "app-id").write_text("123")
    (tmp_path / "installation-id").write_text("456")
    captured = []
    monkeypatch.setattr(
        github_token.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(stdout=b"fixture-signature"),
    )

    def open_request(request, timeout):
        captured.append(json.loads(request.data))
        return io.BytesIO(json.dumps(token()).encode())

    monkeypatch.setattr(github_token.urllib.request, "urlopen", open_request)
    github_token.mint(CONFIG, tmp_path)
    assert captured == [
        {
            "repositories": ["notes"],
            "permissions": {"contents": "write", "pull_requests": "write"},
        }
    ]
