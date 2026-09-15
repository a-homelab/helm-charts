"""Verify that publication checks fail closed on registry and policy errors."""

import copy

import pytest
import requests
from check_chart_release import check_release

RULE = {
    "disabled": False,
    "action": "immutable",
    "template": "immutable_template",
    "tag_selectors": [{"kind": "doublestar", "decoration": "matches", "pattern": "**"}],
    "scope_selectors": {
        "repository": [
            {"kind": "doublestar", "decoration": "repoMatches", "pattern": "common"}
        ]
    },
}


class Registry:
    def __init__(self, rules=None, artifact=404, policy=200):
        self.rules = [RULE] if rules is None else rules
        self.artifact = artifact
        self.policy = policy
        self.artifact_checked = False

    def get(self, url, **kwargs):
        response = requests.Response()
        response.status_code = 200
        response.json = lambda: {"project_id": 1}
        if "immutabletagrules" in url:
            response.status_code = self.policy
            response.json = lambda: self.rules
        elif "/artifacts/" in url:
            self.artifact_checked = True
            response.status_code = self.artifact
        return response


def test_new_version_with_immutable_policy():
    registry = Registry()
    check_release(registry, "https://registry.example", "helm", "common", "1.0.0")
    assert registry.artifact_checked


@pytest.mark.parametrize("status", [200, 401, 403, 429, 500])
def test_existing_or_unverifiable_version_is_rejected(status):
    with pytest.raises((ValueError, requests.HTTPError)):
        check_release(
            Registry(artifact=status),
            "https://registry.example",
            "helm",
            "common",
            "1.0.0",
        )


@pytest.mark.parametrize(
    "mutation", ["disabled", "different_repository", "limited_tags", "exclusion"]
)
def test_inadequate_policy_is_rejected(mutation):
    rule = copy.deepcopy(RULE)
    if mutation == "disabled":
        rule["disabled"] = True
    elif mutation == "different_repository":
        rule["scope_selectors"]["repository"][0]["pattern"] = "other"
    elif mutation == "limited_tags":
        rule["tag_selectors"][0]["pattern"] = "v*"
    else:
        rule["tag_selectors"][0]["decoration"] = "excludes"
    registry = Registry(rules=[rule])
    with pytest.raises(ValueError, match="lacks an enabled"):
        check_release(registry, "https://registry.example", "helm", "common", "1.0.0")
    assert not registry.artifact_checked


@pytest.mark.parametrize("status", [401, 403, 404, 500])
def test_unverifiable_policy_is_rejected(status):
    with pytest.raises(requests.HTTPError):
        check_release(
            Registry(policy=status),
            "https://registry.example",
            "helm",
            "common",
            "1.0.0",
        )
