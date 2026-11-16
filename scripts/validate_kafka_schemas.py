import argparse
import json
import subprocess
from pathlib import Path

import jsonschema
import yaml
from download import cached_download
from update_common_schemas import reduce_schema
from validate_postgresql_schemas import strict_objects

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/kafka"

SOURCE_KEYS = {
    ("kafka.strimzi.io/v1", "Kafka"): "strimzi-1.3.1-kafkas.yaml",
    ("kafka.strimzi.io/v1", "KafkaNodePool"): "strimzi-1.3.1-kafkanodepools.yaml",
    ("kafka.strimzi.io/v1", "KafkaTopic"): "strimzi-1.3.1-kafkatopics.yaml",
    ("kafka.strimzi.io/v1", "KafkaUser"): "strimzi-1.3.1-kafkausers.yaml",
    ("cert-manager.io/v1", "Certificate"): "cert-manager-1.21.2-certificates.yaml",
    ("cert-manager.io/v1", "Issuer"): "cert-manager-1.21.2-issuers.yaml",
    (
        "policy.cert-manager.io/v1alpha1",
        "CertificateRequestPolicy",
    ): "approver-policy-0.28.0-certificaterequestpolicies.yaml",
    ("external-secrets.io/v1", "ExternalSecret"): "eso-2.11.0-externalsecrets.yaml",
    (
        "generators.external-secrets.io/v1alpha1",
        "Password",
    ): "eso-2.11.0-passwords.yaml",
}


def load_schemas(cache):
    sources = json.loads((CHART / "tests/schema-sources.json").read_text())
    registry = {}
    cache.mkdir(parents=True, exist_ok=True)
    for name, source in sources.items():
        payload = cached_download(
            source["url"], cache / name, source["sha256"], timeout=30
        )
        crd = yaml.safe_load(payload)
        schema = reduce_schema(
            next(v for v in crd["spec"]["versions"] if v["storage"])["schema"][
                "openAPIV3Schema"
            ]
        )
        strict_objects(schema)
        registry[name] = schema
    other = json.loads(
        (ROOT / "charts/common/schema/vendor/custom-resources.json").read_text()
    )
    schema = other["monitoring.coreos.com/v1/PodMonitor"]
    strict_objects(schema)
    registry["monitoring.coreos.com/v1/PodMonitor"] = schema
    # Role and RoleBinding for password users, at the Kubernetes version the clusters run.
    kubernetes = json.loads(
        (ROOT / "charts/common/schema/vendor/kubernetes-1.32.0.json").read_text()
    )
    for kind, definition in kubernetes["resourceIndex"].items():
        registry[kind] = {
            "$ref": f"#/definitions/{definition}",
            "definitions": kubernetes["definitions"],
        }
    return registry


def main():
    parser = argparse.ArgumentParser(
        description="Validate Kafka examples against pinned upstream CRDs."
    )
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--helm", default="helm")
    args = parser.parse_args()
    registry = load_schemas(args.cache)
    count = 0
    for example in sorted((CHART / "examples").glob("*.yaml")):
        output = subprocess.run(
            [
                args.helm,
                "template",
                "schema-test",
                str(CHART),
                "--namespace",
                "test",
                "-f",
                str(example),
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        for doc in yaml.safe_load_all(output):
            if not doc:
                continue
            kind = doc["kind"]
            key = SOURCE_KEYS.get(
                (doc["apiVersion"], kind), f"{doc['apiVersion']}/{kind}"
            )
            errors = list(jsonschema.Draft7Validator(registry[key]).iter_errors(doc))
            if errors:
                details = "\n".join(
                    f"{list(error.path)}: {error.message}" for error in errors
                )
                raise ValueError(f"{example.name}: {kind} against {key}:\n{details}")
            count += 1
        print(
            f"OK {example.name}: Strimzi 1.3.1, cert-manager 1.21.2, approver-policy 0.28.0,"
            " External Secrets 2.11.0, Kubernetes 1.32"
        )
    print(
        f"Passed {count} resource/schema validations; CEL and admission webhooks require separate cluster validation"
    )


if __name__ == "__main__":
    main()
