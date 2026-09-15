"""Compose offline consumer schemas and validate rendered common resources."""

import argparse
import json
from functools import lru_cache
from pathlib import Path

import yaml
from jsonschema import Draft7Validator
from update_common_schemas import reduce_schema

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "charts/common/schema/values.schema.json"
VENDOR = SOURCE.parent / "vendor"


def compose(extension=None):
    schema = json.loads(SOURCE.read_text())
    if extension:
        for key in ("properties", "definitions"):
            extra = extension.get(key, {})
            collisions = schema[key].keys() & extra.keys()
            if collisions:
                raise ValueError(
                    f"Extension replaces common {key}: {sorted(collisions)}"
                )
            schema[key].update(extra)
        schema.setdefault("required", []).extend(extension.get("required", []))
    Draft7Validator.check_schema(schema)
    return schema


def strict(node):
    if isinstance(node, dict):
        if "properties" in node and "additionalProperties" not in node:
            node["additionalProperties"] = False
        for value in node.values():
            strict(value)
    elif isinstance(node, list):
        for value in node:
            strict(value)
    return node


SUPPORTED_KUBERNETES = tuple(f"1.{minor}.0" for minor in range(31, 38))
CUSTOM = strict(json.loads((VENDOR / "custom-resources.json").read_text()))


@lru_cache(maxsize=7)
def kubernetes_schema(version):
    parts = version.removeprefix("v").split(".")
    minor = ".".join(parts[:2]) + ".0"
    if minor not in SUPPORTED_KUBERNETES:
        raise ValueError(f"Unsupported Kubernetes version: {version}")
    return strict(json.loads((VENDOR / f"kubernetes-{minor}.json").read_text()))


def check_local_refs(schema):
    if isinstance(schema, dict):
        if isinstance(schema.get("$ref"), str) and not schema["$ref"].startswith("#/"):
            raise ValueError("Output schemas must use local references only")
        for value in schema.values():
            check_local_refs(value)
    elif isinstance(schema, list):
        for value in schema:
            check_local_refs(value)


def crd_schemas(documents):
    result = {}
    for crd in documents:
        if not crd or crd.get("kind") != "CustomResourceDefinition":
            raise ValueError("--crd expects CustomResourceDefinition documents")
        spec = crd["spec"]
        for version in spec["versions"]:
            if version["served"]:
                key = f"{spec['group']}/{version['name']}/{spec['names']['kind']}"
                result[key] = strict(
                    reduce_schema(version["schema"]["openAPIV3Schema"])
                )
    return result


def validate_manifest(manifest, kubernetes_version="1.31.0", schemas=None):
    kind = manifest["kind"]
    api = manifest["apiVersion"]
    key = f"{api}/{kind}"
    custom = {**CUSTOM, **(schemas or {})}
    native = kubernetes_schema(kubernetes_version)
    if schemas and key in schemas and (key in CUSTOM or key in native["resourceIndex"]):
        raise ValueError(f"Custom schema cannot replace bundled schema {key}")
    if key in custom:
        schema = custom[key]
    else:
        name = native["resourceIndex"].get(key)
        if not name:
            raise ValueError(f"No output schema for {key}; supply --crd or --schemas")
        schema = {"$ref": f"#/definitions/{name}", **native}
    check_local_refs(schema)
    errors = list(Draft7Validator(schema).iter_errors(manifest))
    metadata_schema = {
        "$ref": "#/definitions/io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta",
        **native,
    }
    errors.extend(
        Draft7Validator(metadata_schema).iter_errors(manifest.get("metadata", {}))
    )
    if errors:
        details = "; ".join(
            f"{'/'.join(map(str, e.path))}: {e.message}"
            for e in sorted(errors, key=str)
        )
        raise ValueError(
            f"{kind}/{manifest.get('metadata', {}).get('name', '?')}: {details}"
        )


def validate_main():
    parser = argparse.ArgumentParser(
        description="Validate final manifests offline, including overrides and raw resources"
    )
    parser.add_argument("manifests", type=Path, nargs="+")
    parser.add_argument("--kubernetes-version", default="1.31.0")
    parser.add_argument("--crd", type=Path, action="append", default=[])
    parser.add_argument(
        "--schemas",
        type=Path,
        action="append",
        default=[],
        help="JSON map of apiVersion/kind to a complete local JSON Schema",
    )
    args = parser.parse_args()
    schemas = {}
    for path in args.crd:
        schemas.update(crd_schemas(yaml.safe_load_all(path.read_text())))
    for path in args.schemas:
        schemas.update(json.loads(path.read_text()))
    for key, schema in schemas.items():
        check_local_refs(schema)
        Draft7Validator.check_schema(schema)
        if key in CUSTOM:
            raise ValueError(f"Custom schema cannot replace bundled schema {key}")
    count = 0
    for path in args.manifests:
        for manifest in yaml.safe_load_all(path.read_text()):
            if manifest:
                validate_manifest(manifest, args.kubernetes_version, schemas)
                count += 1
    print(f"Validated {count} resources for Kubernetes {args.kubernetes_version}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("chart", type=Path, help="Consumer chart directory")
    parser.add_argument(
        "--extensions", type=Path, help="Additional root properties/definitions"
    )
    parser.add_argument(
        "--check", action="store_true", help="Fail if the generated schema differs"
    )
    args = parser.parse_args()
    extension = json.loads(args.extensions.read_text()) if args.extensions else None
    text = json.dumps(compose(extension), indent=2, ensure_ascii=True) + "\n"
    path = args.chart / "values.schema.json"
    if args.check:
        if not path.exists() or path.read_text() != text:
            raise SystemExit(f"Schema is stale: {path}")
    else:
        path.write_text(text)


if __name__ == "__main__":
    main()
