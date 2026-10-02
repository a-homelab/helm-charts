import argparse
import difflib
import json
import subprocess
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART_PATH = Path("charts/postgresql")


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def resources(chart, release, namespace, files=(), settings=()):
    args = ["helm", "template", release, str(chart), "--namespace", namespace]
    for path in files:
        args.extend(["-f", str(path)])
    for setting in settings:
        args.extend(["--set", setting])
    return [doc for doc in yaml.safe_load_all(command(*args)) if doc]


def consumers(manifests):
    for root in sorted(manifests.glob("applications/*/root/charts/root")):
        category = root.parents[2].name
        settings = [
            f"global.argocd.basePath=applications/{category}",
            "global.argocd.project=chart-review",
        ]
        for app in resources(root, "inventory", "default", settings=settings):
            if app["kind"] != "Application":
                continue
            sources = app["spec"].get("sources", [app["spec"].get("source", {})])
            for source in sources:
                if source.get("path") == str(CHART_PATH):
                    if "a-homelab/helm-charts" not in source.get("repoURL", ""):
                        continue
                    yield (
                        app["metadata"]["name"],
                        app["spec"]["destination"]["namespace"],
                        source,
                    )


def normalize(documents):
    result = {}
    for doc in documents:
        meta = doc["metadata"]
        # A chart release label on the CR cannot change the database or its pods.
        meta.get("labels", {}).pop("helm.sh/chart", None)
        if not meta.get("annotations"):
            meta.pop("annotations", None)
        result[(doc["kind"], meta.get("namespace"), meta["name"])] = doc
    return result


def main():
    parser = argparse.ArgumentParser(
        description="Compare all GitOps PostgreSQL consumers to a baseline chart."
    )
    parser.add_argument("--baseline-ref", required=True)
    parser.add_argument(
        "--manifests", type=Path, default=ROOT.parent / "kubernetes-manifests"
    )
    parser.add_argument(
        "--live-clusters",
        type=Path,
        help="Optional kubectl get clusters -A -o json report.",
    )
    args = parser.parse_args()
    baseline_ref = command(
        "git", "-C", str(ROOT), "rev-parse", "--verify", args.baseline_ref
    ).strip()
    failed = False
    count = 0
    identities = set()
    with tempfile.TemporaryDirectory(prefix="postgresql-baseline-") as directory:
        baseline = Path(directory)
        paths = command(
            "git",
            "-C",
            str(ROOT),
            "ls-tree",
            "-r",
            "--name-only",
            baseline_ref,
            str(CHART_PATH),
        ).splitlines()
        if not paths:
            raise SystemExit("Baseline does not contain the PostgreSQL chart")
        for name in paths:
            target = baseline / Path(name).relative_to(CHART_PATH)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(
                command("git", "-C", str(ROOT), "show", f"{baseline_ref}:{name}")
            )
        for app, namespace, source in consumers(args.manifests):
            helm = source["helm"]
            if helm.get("parameters") or helm.get("values") or helm.get("valuesObject"):
                raise SystemExit(
                    f"{app}: inline Helm overrides need explicit comparison support"
                )
            rendered = []
            for chart in [baseline, ROOT / CHART_PATH]:
                files = [
                    args.manifests / value.removeprefix("$values/")
                    if value.startswith("$values/")
                    else chart / value
                    for value in helm.get("valueFiles", [])
                ]
                rendered.append(
                    normalize(resources(chart, helm["releaseName"], namespace, files))
                )
            old, new = rendered
            for kind, ns, name in new:
                if kind == "Cluster":
                    identities.add((ns, name))
            count += 1
            if old == new:
                print(
                    f"OK {app}/{helm['releaseName']}: all specs and resource identities unchanged"
                )
            else:
                failed = True
                print(f"FAIL {app}/{helm['releaseName']}")
                before = yaml.safe_dump(list(old.values()), sort_keys=True).splitlines(
                    True
                )
                after = yaml.safe_dump(list(new.values()), sort_keys=True).splitlines(
                    True
                )
                print(
                    "".join(
                        difflib.unified_diff(
                            before, after, fromfile="baseline", tofile="working tree"
                        )
                    )
                )
    if count == 0:
        raise SystemExit("No PostgreSQL consumers found")
    if args.live_clusters:
        live = json.loads(args.live_clusters.read_text())["items"]
        missing = {
            (c["metadata"]["namespace"], c["metadata"]["name"]) for c in live
        } - identities
        if missing:
            failed = True
            print(
                f"FAIL live clusters not covered by consumer comparison: {sorted(missing)}"
            )
        else:
            print(f"OK all {len(live)} live cluster identities are covered")
    print(f"Compared {count} consumer configurations against {baseline_ref}")
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
