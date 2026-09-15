"""Refuse chart publication without immutable Harbor tags and a fresh version."""

import argparse
import os
from urllib.parse import quote

import requests


def immutable_repository(rule, repository):
    return (
        rule.get("disabled") is False
        and rule.get("action") == "immutable"
        and rule.get("template") == "immutable_template"
        and rule.get("tag_selectors")
        == [{"kind": "doublestar", "decoration": "matches", "pattern": "**"}]
        and rule.get("scope_selectors", {}).get("repository")
        in [
            [
                {
                    "kind": "doublestar",
                    "decoration": "repoMatches",
                    "pattern": repository,
                }
            ],
            [{"kind": "doublestar", "decoration": "repoMatches", "pattern": "**"}],
        ]
    )


def check_release(session, base, project, repository, version):
    project_path = f"{base}/api/v2.0/projects/{quote(project, safe='')}"
    response = session.get(project_path, timeout=30)
    response.raise_for_status()
    project_id = response.json()["project_id"]
    page = 1
    protected = False
    while True:
        response = session.get(
            f"{base}/api/v2.0/projects/{project_id}/immutabletagrules",
            params={"page": page, "page_size": 100},
            timeout=30,
        )
        response.raise_for_status()
        rules = response.json()
        protected |= any(immutable_repository(rule, repository) for rule in rules)
        if len(rules) < 100:
            break
        page += 1
    if not protected:
        raise ValueError(
            f"Refusing publication: {project}/{repository} lacks an enabled all-tags immutable rule"
        )
    reference = quote(version.replace("+", "_"), safe="")
    repo = quote(quote(repository, safe=""), safe="")
    response = session.get(
        f"{project_path}/repositories/{repo}/artifacts/{reference}", timeout=30
    )
    if response.status_code == 404:
        return
    response.raise_for_status()
    raise ValueError(
        f"Chart {project}/{repository}:{version} already exists; bump Chart.yaml and consumer pins"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--registry",
        required=True,
        help="HTTPS Harbor origin, without the project path",
    )
    parser.add_argument("--project", required=True)
    parser.add_argument("--chart", required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    if not args.registry.startswith("https://"):
        raise ValueError("Registry must use HTTPS")
    with requests.Session() as session:
        session.auth = (os.environ["HARBOR_USERNAME"], os.environ["HARBOR_PASSWORD"])
        check_release(
            session, args.registry.rstrip("/"), args.project, args.chart, args.version
        )
    print(
        f"Publication allowed: immutable policy verified and {args.chart}:{args.version} is new"
    )


if __name__ == "__main__":
    main()
