import os
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

CHART = Path(__file__).resolve().parents[1]
SCRIPT = CHART / "files/sync_sources.sh"
DELIVERY = "addison-reference-home/polycam-mesh/2026-09-18"


def hash_tree(remote):
    hashes = subprocess.check_output(
        ["rclone", "--config", "/dev/null", "hashsum", "SHA-256", str(remote),
         "--exclude", "/SHA256SUMS"]
    )
    (remote / "SHA256SUMS").write_bytes(b"".join(sorted(hashes.splitlines(keepends=True))))


@pytest.fixture
def capture(tmp_path):
    if not shutil.which("rclone"):
        pytest.skip("Native rclone is required for source-sync integration tests")
    remote = tmp_path / "remote/captures"
    delivery = remote / DELIVERY
    delivery.mkdir(parents=True)
    (delivery / "original.zip").write_bytes(b"original ZIP")
    (delivery / "scan.glb").write_bytes(b"extracted GLB")
    (delivery / "session.json").write_text('{"sessionId":"legacy-acquisition-id"}\n')
    hash_tree(remote)
    workspace = tmp_path / "workspace"
    source = workspace / "source"
    source.mkdir(parents=True)
    (workspace / "scene.blend").write_bytes(b"editable scene")
    env = {
        **os.environ,
        "SOURCE_ROOT": str(source),
        "BUCKET_NAME": str(remote.parent),
        "BUCKET_HOST": "unused",
        "BUCKET_PORT": "80",
        "BUCKET_REGION": "",
        "AWS_ACCESS_KEY_ID": "test",
        "AWS_SECRET_ACCESS_KEY": "test",
        "RCLONE_CONFIG_RGW_TYPE": "local",
        "MIN_FREE_BYTES": "0",
    }
    return remote, source, env


def run(capture):
    return subprocess.run(
        ["/bin/sh", str(SCRIPT)], env=capture[2], capture_output=True, text=True, timeout=30
    )


def target(capture):
    return capture[1] / "captures"


def test_publish_and_repeat_preserve_originals_and_scene(capture):
    first = run(capture)
    assert first.returncode == 0, first.stderr
    assert target(capture).is_symlink()
    revision = target(capture).resolve()
    assert (revision / DELIVERY / "original.zip").read_bytes() == b"original ZIP"
    assert (revision / "SHA256SUMS").read_bytes() == (capture[0] / "SHA256SUMS").read_bytes()
    second = run(capture)
    assert second.returncode == 0, second.stderr
    assert target(capture).resolve() == revision
    assert len(list((capture[1] / ".source-sync/revisions").iterdir())) == 1
    assert (capture[1].parent / "scene.blend").read_bytes() == b"editable scene"
    assert not (capture[1] / ".source-sync/pending").exists()


def test_root_inventory_update_switches_whole_tree_and_retains_previous(capture):
    assert run(capture).returncode == 0
    previous = target(capture).resolve()
    addition = capture[0] / "another-home/photos/2026-09-19"
    addition.mkdir(parents=True)
    (addition / "image with spaces.jpg").write_bytes(b"new photo")
    hash_tree(capture[0])
    result = run(capture)
    assert result.returncode == 0, result.stderr
    assert target(capture).resolve() != previous
    assert (target(capture) / addition.relative_to(capture[0]) / "image with spaces.jpg").is_file()
    assert not (previous / "another-home").exists()
    assert (previous / DELIVERY / "original.zip").read_bytes() == b"original ZIP"


@pytest.mark.parametrize("change", ["changed", "missing", "extra", "missing-marker", "empty-marker"])
def test_failed_refresh_preserves_current_tree(capture, change):
    assert run(capture).returncode == 0
    previous = target(capture).resolve()
    (capture[0] / "new-file").write_bytes(b"addition")
    hash_tree(capture[0])
    if change == "changed":
        (capture[0] / DELIVERY / "scan.glb").write_bytes(b"corrupt")
    elif change == "missing":
        (capture[0] / DELIVERY / "scan.glb").unlink()
    elif change == "extra":
        (capture[0] / "not-published").write_bytes(b"pending upload")
    elif change == "missing-marker":
        (capture[0] / "SHA256SUMS").unlink()
    else:
        (capture[0] / "SHA256SUMS").write_bytes(b"")
    assert run(capture).returncode != 0
    assert target(capture).resolve() == previous
    assert not (previous / "new-file").exists()
    assert not (capture[1] / ".source-sync/pending").exists()


def test_first_unpublished_tree_is_not_exposed(capture):
    (capture[0] / "SHA256SUMS").unlink()
    assert run(capture).returncode != 0
    assert not target(capture).exists()


@pytest.mark.parametrize("change", ["rewrite", "remove"])
def test_new_inventory_cannot_change_published_originals(capture, change):
    assert run(capture).returncode == 0
    previous = target(capture).resolve()
    original = capture[0] / DELIVERY / "original.zip"
    if change == "rewrite":
        original.write_bytes(b"changed original")
    else:
        original.unlink()
    hash_tree(capture[0])
    assert run(capture).returncode != 0
    assert target(capture).resolve() == previous
    assert (previous / DELIVERY / "original.zip").read_bytes() == b"original ZIP"


def test_existing_edit_is_preserved(capture):
    assert run(capture).returncode == 0
    (target(capture) / DELIVERY / "scan.glb").write_bytes(b"local edit")
    assert run(capture).returncode != 0
    assert (target(capture) / DELIVERY / "scan.glb").read_bytes() == b"local edit"


def test_marker_change_during_transfer_is_rejected(capture, tmp_path):
    binary = shutil.which("rclone")
    wrapper = tmp_path / "bin"
    wrapper.mkdir()
    script = wrapper / "rclone"
    script.write_text(
        '#!/bin/sh\nset -eu\n"$REAL_RCLONE" "$@"\ncase " $* " in *" checksum "*) printf "\\n" >> "$REMOTE_SUMS";; esac\n'
    )
    script.chmod(0o755)
    capture[2].update({
        "PATH": str(wrapper) + ":" + os.environ["PATH"],
        "REAL_RCLONE": binary,
        "REMOTE_SUMS": str(capture[0] / "SHA256SUMS"),
    })
    result = run(capture)
    assert result.returncode != 0 and "changed during sync" in result.stderr
    assert not target(capture).exists()


def test_existing_directory_requires_explicit_migration(capture):
    target(capture).mkdir()
    (target(capture) / "original.zip").write_bytes(b"legacy cache")
    result = run(capture)
    assert result.returncode != 0 and "move it aside" in result.stderr
    assert (target(capture) / "original.zip").read_bytes() == b"legacy cache"


@pytest.mark.parametrize("path", ["captures", ".source-sync", ".source-sync/revisions"])
def test_unmanaged_symlink_is_rejected(capture, tmp_path, path):
    outside = tmp_path / "outside"
    outside.mkdir()
    link = capture[1] / path
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(outside)
    assert run(capture).returncode != 0
    assert not list(outside.iterdir())


def test_free_space_reserve_prevents_download(capture):
    capture[2]["MIN_FREE_BYTES"] = "1000000000000000"
    result = run(capture)
    assert result.returncode != 0 and "Insufficient workspace" in result.stderr
    assert not target(capture).exists()


def test_scheduled_and_manual_runs_share_lock(capture):
    import fcntl

    state = capture[1] / ".source-sync"
    state.mkdir()
    with (state / "lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = run(capture)
        assert result.returncode != 0 and "Another source sync" in result.stderr
    assert run(capture).returncode == 0


def test_abandoned_staging_removed_under_lock(capture):
    pending = capture[1] / ".source-sync/pending"
    pending.mkdir(parents=True)
    (pending / "partial").write_text("interrupted")
    assert run(capture).returncode == 0
    assert not pending.exists()


def test_verified_revision_recovered_after_interrupted_pointer_switch(capture):
    assert run(capture).returncode == 0
    previous = target(capture).resolve()
    target(capture).unlink()
    assert run(capture).returncode == 0
    assert target(capture).resolve() == previous


def test_chart_uses_rclone_only_and_shared_workspace():
    output = subprocess.check_output(
        [
            "helm",
            "template",
            "mi-casa-blender",
            str(CHART),
            "--namespace",
            "mi-casa",
            "--set",
            "components.source-sync.enabled=true",
        ]
    )
    resources = list(yaml.safe_load_all(output))
    cron = next(r for r in resources if r["kind"] == "CronJob")
    desktop = next(r for r in resources if r["kind"] == "Deployment")
    spec = cron["spec"]
    pod = spec["jobTemplate"]["spec"]["template"]["spec"]
    assert spec["concurrencyPolicy"] == "Forbid"
    assert spec["jobTemplate"]["spec"]["activeDeadlineSeconds"] == 7200
    assert not pod.get("runtimeClassName")
    assert not pod.get("initContainers")
    assert len(pod["containers"]) == 1
    container = pod["containers"][0]
    assert container["image"] == "rclone/rclone:1.75.1"
    assert container["command"] == ["/bin/sh", "/opt/blender-bootstrap/sync_sources.sh"]
    assert "nvidia.com/gpu" not in str(container["resources"])
    assert pod["affinity"]["podAffinity"][
        "requiredDuringSchedulingIgnoredDuringExecution"
    ] == [
        {
            "labelSelector": {
                "matchLabels": desktop["spec"]["selector"]["matchLabels"]
            },
            "topologyKey": "kubernetes.io/hostname",
        }
    ]
    assert {
        "key": "nvidia.com/gpu",
        "operator": "Exists",
        "effect": "NoSchedule",
    } in pod["tolerations"]
    claim = next(v for v in pod["volumes"] if v["name"] == "workspace")
    assert claim["persistentVolumeClaim"]["claimName"] == "mi-casa-blender-workspace"
    mount = next(v for v in container["volumeMounts"] if v["name"] == "workspace")
    assert mount == {"name": "workspace", "mountPath": "/source", "subPath": "source"}
    assert all(e["name"] != "SOURCE_DELIVERIES" for e in container["env"])
    assert pod["automountServiceAccountToken"] is False


def test_sync_disabled_by_default():
    output = subprocess.check_output(["helm", "template", "test", str(CHART)])
    assert all(r["kind"] != "CronJob" for r in yaml.safe_load_all(output))
