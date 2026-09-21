import json
import os
import subprocess
from pathlib import Path

import pytest

SOURCE = Path(__file__).resolve().parents[1] / "files/bootstrap/workspace.sh"


def bootstrap(config, root):
    config_path = root.parent / "git.json"
    config_path.write_text(json.dumps({"enabled": True, **config}))
    result = subprocess.run(
        [
            "/bin/sh",
            str(SOURCE),
            str(config_path),
            str(root),
            str(root.parent / "state"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result


def run(*args):
    return subprocess.run(
        ["git", *map(str, args)], check=True, capture_output=True, text=True
    ).stdout.strip()


@pytest.fixture
def repos(tmp_path, monkeypatch):
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", "/dev/null")
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    upstream = tmp_path / "upstream"
    upstream.mkdir()
    run("init", "--initial-branch=main", upstream)
    run("-C", upstream, "config", "user.name", "Fixture")
    run("-C", upstream, "config", "user.email", "fixture@example.test")
    run("-C", upstream, "config", "commit.gpgsign", "false")
    (upstream / "notes.md").write_text("original\n")
    run("-C", upstream, "add", ".")
    run("-C", upstream, "commit", "-m", "Initial fixture")
    origin = "https://github.com/example/notes.git"
    config = tmp_path / "gitconfig"
    config.write_text(f'[url "{upstream}"]\n    insteadOf = {origin}\n')
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", str(config))
    root = tmp_path / "workspace"
    root.mkdir()
    return (
        upstream,
        root,
        {"owner": "example", "repositories": [{"name": "notes", "path": "notes"}]},
    )


def test_clones_missing_repo_and_preserves_dirty_branch_on_restart(repos, monkeypatch):
    upstream, root, config = repos
    bootstrap(config, root)
    checkout = root / "notes"
    run("-C", checkout, "switch", "-c", "agent/work")
    (checkout / "notes.md").write_text("unfinished edit\n")
    (checkout / "untracked").write_text("keep me")
    (upstream / "notes.md").write_text("remote change\n")
    run("-C", upstream, "commit", "-am", "Remote change")
    head = run("-C", checkout, "rev-parse", "HEAD")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", "/dev/null")
    bootstrap(config, root)
    assert run("-C", checkout, "branch", "--show-current") == "agent/work"
    assert run("-C", checkout, "rev-parse", "HEAD") == head
    assert (checkout / "notes.md").read_text() == "unfinished edit\n"
    assert (checkout / "untracked").read_text() == "keep me"


def test_rejects_wrong_origin_without_modifying_files(repos, monkeypatch):
    _, root, config = repos
    bootstrap(config, root)
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", "/dev/null")
    run(
        "-C",
        root / "notes",
        "remote",
        "set-url",
        "origin",
        "https://github.com/other/notes.git",
    )
    with pytest.raises(RuntimeError, match="does not match"):
        bootstrap(config, root)
    assert (root / "notes/notes.md").read_text() == "original\n"


@pytest.mark.parametrize(
    "path", ["", ".", "../escape", "/absolute", "nested/../../escape"]
)
def test_rejects_paths_outside_workspace(tmp_path, path):
    with pytest.raises(RuntimeError, match="workspace"):
        bootstrap(
            {"owner": "example", "repositories": [{"name": "notes", "path": path}]},
            tmp_path / "workspace",
        )


@pytest.mark.parametrize("outside", [True, False])
@pytest.mark.parametrize("path", ["linked", "linked/", "linked/."])
def test_rejects_checkout_symlink(tmp_path, outside, path):
    root = tmp_path / "workspace"
    root.mkdir()
    destination = tmp_path / "outside" if outside else root / "inside"
    destination.mkdir()
    (root / "linked").symlink_to(destination, target_is_directory=True)
    with pytest.raises(RuntimeError, match="workspace|symlink"):
        bootstrap(
            {"owner": "example", "repositories": [{"name": "notes", "path": path}]},
            root,
        )
    assert list(destination.iterdir()) == []


def test_rejects_symlink_ancestor_escape(tmp_path):
    root = tmp_path / "workspace"
    root.mkdir()
    (root / "linked").symlink_to(tmp_path, target_is_directory=True)
    with pytest.raises(RuntimeError, match="workspace"):
        bootstrap(
            {
                "owner": "example",
                "repositories": [{"name": "notes", "path": "linked/checkout"}],
            },
            root,
        )
    assert not (tmp_path / "checkout").exists()


def test_failed_clone_is_not_published(tmp_path, monkeypatch):
    tools = tmp_path / "tools"
    tools.mkdir()
    fake_git = tools / "git"
    fake_git.write_text("#!/bin/sh\nexit 1\n")
    fake_git.chmod(0o755)
    monkeypatch.setenv("PATH", str(tools) + os.pathsep + os.environ["PATH"])
    root = tmp_path / "workspace"
    with pytest.raises(RuntimeError):
        bootstrap(
            {"owner": "example", "repositories": [{"name": "notes", "path": "notes"}]},
            root,
        )
    assert list(root.iterdir()) == []


def test_disabled_git_only_creates_state_directories(tmp_path):
    root = tmp_path / "workspace"
    bootstrap({"enabled": False}, root)
    assert list(root.iterdir()) == []
    assert {p.name for p in (tmp_path / "state").iterdir()} == {
        "config",
        "data",
        "cache",
        "state",
    }


def test_clones_into_missing_nested_directories(repos):
    _, root, config = repos
    config["repositories"][0]["path"] = "parent/nested/notes"
    bootstrap(config, root)
    assert (root / "parent/nested/notes/notes.md").read_text() == "original\n"


def test_rejects_parent_repository_masquerading_as_child(repos, monkeypatch):
    _, root, config = repos
    bootstrap(config, root)
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", "/dev/null")
    (root / "notes/child").mkdir()
    config["repositories"][0]["path"] = "notes/child"
    with pytest.raises(RuntimeError, match="does not match"):
        bootstrap(config, root)
