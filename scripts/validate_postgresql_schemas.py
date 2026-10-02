import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from urllib.request import urlopen

import jsonschema
import yaml
from update_common_schemas import reduce_schema

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/postgresql"


def strict_objects(schema):
    if isinstance(schema, dict):
        if "properties" in schema and schema.get("type") == "object":
            schema.setdefault("additionalProperties", False)
        for value in schema.values():
            strict_objects(value)
    elif isinstance(schema, list):
        for value in schema:
            strict_objects(value)


def load_schemas(cache):
    sources = json.loads((CHART / "tests/schema-sources.json").read_text())
    registry = {}
    cache.mkdir(parents=True, exist_ok=True)
    for name, source in sources.items():
        path = cache / name
        if not path.exists():
            with urlopen(source["url"], timeout=30) as response:
                path.write_bytes(response.read())
        payload = path.read_bytes()
        if hashlib.sha256(payload).hexdigest() != source["sha256"]:
            raise ValueError(f"Upstream checksum mismatch: {name}")
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
    for kind in [
        "cert-manager.io/v1/Certificate",
        "monitoring.coreos.com/v1/PodMonitor",
    ]:
        schema = other[kind]
        strict_objects(schema)
        registry[kind] = schema
    kubernetes = json.loads(
        (ROOT / "charts/common/schema/vendor/kubernetes-1.31.0.json").read_text()
    )
    for kind, definition in kubernetes["resourceIndex"].items():
        registry[kind] = {
            "$ref": f"#/definitions/{definition}",
            "definitions": kubernetes["definitions"],
        }
    return registry


def main():
    parser = argparse.ArgumentParser(
        description="Validate PostgreSQL examples against pinned upstream CRDs."
    )
    parser.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args()
    registry = load_schemas(args.cache)
    count = 0
    for example in sorted((CHART / "examples").glob("*.yaml")):
        output = subprocess.run(
            [
                "helm",
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
        versions = ["1.30.1"] if example.stem == "modern" else ["1.28.1", "1.30.1"]
        for doc in yaml.safe_load_all(output):
            if not doc or doc["kind"] == "ObjectBucketClaim":
                continue
            kind = doc["kind"]
            if doc["apiVersion"] == "postgresql.cnpg.io/v1":
                keys = [f"cnpg-{version}-{kind.lower()}s.yaml" for version in versions]
            elif kind == "ObjectStore":
                keys = ["barman-0.15.1-objectstores.yaml"]
            elif kind in {"ExternalSecret", "SecretStore", "Password"}:
                keys = [f"eso-2.11.0-{kind.lower()}s.yaml"]
            else:
                keys = [f"{doc['apiVersion']}/{kind}"]
            for key in keys:
                errors = list(
                    jsonschema.Draft7Validator(registry[key]).iter_errors(doc)
                )
                if errors:
                    details = "\n".join(
                        f"{list(error.path)}: {error.message}" for error in errors
                    )
                    raise ValueError(
                        f"{example.name}: {kind} against {key}:\n{details}"
                    )
                count += 1
        print(
            f"OK {example.name}: CNPG {', '.join(versions)} and applicable ancillary schemas"
        )
    print(
        f"Passed {count} resource/schema validations; CEL and admission webhooks require separate cluster validation"
    )


if __name__ == "__main__":
    main()
