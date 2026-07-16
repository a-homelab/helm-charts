#!/usr/bin/env python3
"""Verify that migrating an app chart to the new common library produces
(semantically) identical manifests.

For a chart at charts/<name> with a migration values file at
charts/<name>/values-v2.yaml, this script:

1. Renders the OLD chart as-is, with its `common` dependency rewritten to a
   local path (default: the primary git checkout, which still carries the
   old library) so rendering needs no registry access.
2. Scaffolds a NEW chart in a temp dir — same name/version/appVersion, a
   single `{{ include "common.all" . }}` template, values-v2.yaml as its
   values — depending on the new common library.
3. Renders both with the same release/namespace, pairs documents by
   (kind, name), and compares them canonically (YAML re-dumped with sorted
   keys, so formatting/quoting/key order never count as diffs).

Remaining differences are classified per resource:
  IDENTICAL  — canonically equal.
  COSMETIC   — equal after well-understood normalizations, each named:
                 empty-prune : one side omits keys whose value is null/{}/[]
                               (k8s treats absent and empty alike here)
                 env-order   : env lists contain the same entries in a
                               different order (matters only for $(VAR)
                               references, which the classifier re-checks)
  DIFFERENT  — a real difference; unified diff is printed.

Exit code: 0 if everything is IDENTICAL/COSMETIC, 1 otherwise.

Usage:
  scripts/verify-common-migration.py charts/sonarr [charts/radarr ...]
      [--release NAME] [--namespace NS] [--values-v2 FILE]
      [--old-common PATH] [--new-common PATH] [--verbose]
"""

import argparse
import copy
import difflib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml


def sh(args, **kw):
    res = subprocess.run(args, capture_output=True, text=True, **kw)
    if res.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(map(str, args))}\n{res.stdout}\n{res.stderr}")
    return res.stdout


def repo_root() -> Path:
    return Path(sh(["git", "rev-parse", "--show-toplevel"]).strip())


def primary_checkout() -> Path:
    # First entry of `git worktree list` is the main checkout — where the
    # old library still lives while this branch is unmerged.
    first = sh(["git", "worktree", "list", "--porcelain"]).splitlines()[0]
    return Path(first.split(" ", 1)[1])


def load_chart_yaml(chart_dir: Path) -> dict:
    return yaml.safe_load((chart_dir / "Chart.yaml").read_text())


def render(chart_dir: Path, release: str, namespace: str) -> str:
    sh(["helm", "dependency", "build", str(chart_dir)])
    return sh(["helm", "template", release, str(chart_dir), "--namespace", namespace])


def prepare_old(chart_dir: Path, old_common: Path, tmp: Path) -> Path:
    dst = tmp / "old" / chart_dir.name
    shutil.copytree(chart_dir, dst, ignore=shutil.ignore_patterns("charts", "Chart.lock", "values-v2.yaml", "tmpcharts*"))
    meta = load_chart_yaml(dst)
    for dep in meta.get("dependencies", []):
        if dep.get("name") == "common":
            dep["repository"] = f"file://{old_common}"
            dep["version"] = load_chart_yaml(old_common)["version"]
    (dst / "Chart.yaml").write_text(yaml.safe_dump(meta, sort_keys=False))
    return dst


def prepare_new(chart_dir: Path, values_v2: Path, new_common: Path, tmp: Path) -> Path:
    src_meta = load_chart_yaml(chart_dir)
    dst = tmp / "new" / chart_dir.name
    (dst / "templates").mkdir(parents=True)
    meta = {
        "apiVersion": "v2",
        "name": src_meta["name"],
        "version": src_meta["version"],
        "dependencies": [{
            "name": "common",
            "version": load_chart_yaml(new_common)["version"],
            "repository": f"file://{new_common}",
        }],
    }
    if "appVersion" in src_meta:
        meta["appVersion"] = src_meta["appVersion"]
    (dst / "Chart.yaml").write_text(yaml.safe_dump(meta, sort_keys=False))
    (dst / "templates" / "all.yaml").write_text('{{- include "common.all" . }}\n')
    shutil.copy(values_v2, dst / "values.yaml")
    return dst


def parse_docs(rendered: str) -> dict:
    docs = {}
    for doc in yaml.safe_load_all(rendered):
        if not doc:
            continue
        key = (doc.get("kind", "?"), doc.get("metadata", {}).get("name", "?"))
        if key in docs:
            raise RuntimeError(f"duplicate resource {key}")
        docs[key] = doc
    return docs


def canon(doc) -> str:
    return yaml.safe_dump(doc, sort_keys=True, default_flow_style=False)


def prune_empty(node):
    """Recursively drop map keys whose value is null / {} / [] (both sides
    are pruned identically, so real empties like `emptyDir: {}` only vanish
    when both sides agree)."""
    if isinstance(node, dict):
        return {k: prune_empty(v) for k, v in node.items()
                if not (v is None or v == {} or v == [])}
    if isinstance(node, list):
        return [prune_empty(v) for v in node]
    return node


def env_has_var_refs(doc) -> bool:
    found = []

    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "env" and isinstance(v, list):
                    for e in v:
                        if isinstance(e, dict) and "$(" in str(e.get("value", "")):
                            found.append(e)
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(doc)
    return bool(found)


def sort_env(node):
    if isinstance(node, dict):
        return {k: (sorted(v, key=lambda e: e.get("name", "") if isinstance(e, dict) else str(e))
                    if k == "env" and isinstance(v, list) else sort_env(v))
                for k, v in node.items()}
    if isinstance(node, list):
        return [sort_env(v) for v in node]
    return node


def classify(old_doc, new_doc):
    """Return (status, notes, diff_text)."""
    if canon(old_doc) == canon(new_doc):
        return "IDENTICAL", [], ""

    notes = []
    o, n = copy.deepcopy(old_doc), copy.deepcopy(new_doc)

    po, pn = prune_empty(o), prune_empty(n)
    if canon(po) == canon(pn):
        return "COSMETIC", ["empty-prune"], ""
    if canon(po) != canon(o) or canon(pn) != canon(n):
        notes_candidate = ["empty-prune"]
    else:
        notes_candidate = []

    so, sn = sort_env(po), sort_env(pn)
    if canon(so) == canon(sn):
        notes = notes_candidate + ["env-order"]
        if env_has_var_refs(old_doc) or env_has_var_refs(new_doc):
            notes.append("WARNING: env contains $(VAR) references — order matters!")
            return "DIFFERENT", notes, udiff(canon(old_doc), canon(new_doc))
        return "COSMETIC", notes, ""

    return "DIFFERENT", [], udiff(canon(so), canon(sn))


def udiff(a: str, b: str) -> str:
    return "".join(difflib.unified_diff(
        a.splitlines(keepends=True), b.splitlines(keepends=True),
        fromfile="old", tofile="new"))


def verify_chart(chart_dir: Path, args, old_common: Path, new_common: Path) -> bool:
    release = args.release or chart_dir.name
    values_v2 = chart_dir / args.values_v2
    if not values_v2.exists():
        print(f"  SKIP: {values_v2} not found")
        return False

    with tempfile.TemporaryDirectory(prefix=f"migrate-{chart_dir.name}-") as tmp:
        tmp = Path(tmp)
        old_rendered = render(prepare_old(chart_dir, old_common, tmp), release, args.namespace)
        new_rendered = render(prepare_new(chart_dir, values_v2, new_common, tmp), release, args.namespace)

    old_docs, new_docs = parse_docs(old_rendered), parse_docs(new_rendered)
    ok = True

    for key in sorted(set(old_docs) - set(new_docs)):
        print(f"  MISSING in new: {key[0]}/{key[1]}")
        ok = False
    for key in sorted(set(new_docs) - set(old_docs)):
        print(f"  EXTRA in new:   {key[0]}/{key[1]}")
        ok = False

    for key in sorted(set(old_docs) & set(new_docs)):
        status, notes, diff = classify(old_docs[key], new_docs[key])
        note = f"  ({', '.join(notes)})" if notes else ""
        print(f"  {status:9s} {key[0]}/{key[1]}{note}")
        if status == "DIFFERENT":
            ok = False
            print("    " + "    ".join(diff.splitlines(keepends=True)) if args.verbose else
                  f"    (re-run with --verbose for the diff)")
        elif args.verbose and status != "IDENTICAL":
            print("    " + "    ".join(udiff(canon(old_docs[key]), canon(new_docs[key])).splitlines(keepends=True)))
    return ok


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("charts", nargs="+", help="chart directories, e.g. charts/sonarr")
    p.add_argument("--release", help="release name (default: chart name)")
    p.add_argument("--namespace", default="default")
    p.add_argument("--values-v2", default="values-v2.yaml", help="migration values file inside the chart dir")
    p.add_argument("--old-common", help="path to the OLD common library (default: <primary checkout>/charts/common)")
    p.add_argument("--new-common", help="path to the NEW common library (default: <repo>/charts/common)")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()

    root = repo_root()
    new_common = Path(args.new_common).resolve() if args.new_common else root / "charts" / "common"
    old_common = Path(args.old_common).resolve() if args.old_common else primary_checkout() / "charts" / "common"

    all_ok = True
    for chart in args.charts:
        chart_dir = Path(chart).resolve()
        print(f"\n=== {chart_dir.name} ===")
        try:
            all_ok &= verify_chart(chart_dir, args, old_common, new_common)
        except RuntimeError as e:
            print(f"  ERROR: {e}")
            all_ok = False

    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
