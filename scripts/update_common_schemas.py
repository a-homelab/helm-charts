"""Rebuild offline output schemas from checksum-locked upstream downloads."""

import argparse
import hashlib
import json
from pathlib import Path
from urllib.request import urlopen

import yaml

VENDOR = Path(__file__).resolve().parents[1] / "charts/common/schema/vendor"


def reduce_schema(node):
    if isinstance(node, dict):
        result = {
            key: reduce_schema(value)
            for key, value in node.items()
            if key not in {"description", "title", "default", "example"}
            and not key.startswith("x-kubernetes-")
        }
        if node.get("x-kubernetes-preserve-unknown-fields"):
            result["additionalProperties"] = True
        if node.get("x-kubernetes-int-or-string") and "anyOf" not in result:
            result["anyOf"] = [{"type": "integer"}, {"type": "string"}]
        if node.get("nullable"):
            result.pop("nullable", None)
            result = {"anyOf": [result, {"type": "null"}]}
        return result
    if isinstance(node, list):
        return [reduce_schema(value) for value in node]
    return node


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument(
        "--check", action="store_true", help="Verify snapshots without changing them"
    )
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    sources = json.loads((VENDOR / "sources.json").read_text())

    def emit(name, schema):
        text = json.dumps(schema, separators=(",", ":")) + "\n"
        path = VENDOR / name
        if args.check:
            if not path.exists() or path.read_text() != text:
                raise ValueError(f"Output schema is stale: {path}")
        else:
            path.write_text(text)

    registry = {}
    for name, source in sources.items():
        path = args.cache / name
        if not path.exists():
            with urlopen(source["url"], timeout=120) as response:
                path.write_bytes(response.read())
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != source["sha256"]:
            raise ValueError(f"Upstream checksum mismatch: {name}")
        if name.startswith("kubernetes-"):
            original = json.loads(data)
            schema = reduce_schema(original)
            schema["resourceIndex"] = {
                f"{gvk['group'] + '/' if gvk['group'] else ''}{gvk['version']}/{gvk['kind']}": key
                for key, definition in original["definitions"].items()
                for gvk in definition.get("x-kubernetes-group-version-kind", [])
            }
            emit(name, schema)
        else:
            for crd in yaml.safe_load_all(data):
                if not crd or crd.get("kind") != "CustomResourceDefinition":
                    continue
                spec = crd["spec"]
                if spec["names"]["kind"] not in {
                    "Certificate",
                    "ExternalSecret",
                    "ServiceMonitor",
                    "PodMonitor",
                    "Gateway",
                    "GatewayClass",
                    "ReferenceGrant",
                    "HTTPRoute",
                    "GRPCRoute",
                    "TLSRoute",
                    "TCPRoute",
                    "UDPRoute",
                    "ListenerSet",
                }:
                    continue
                for version in spec["versions"]:
                    if version["served"]:
                        key = (
                            f"{spec['group']}/{version['name']}/{spec['names']['kind']}"
                        )
                        registry[key] = reduce_schema(
                            version["schema"]["openAPIV3Schema"]
                        )
    emit("custom-resources.json", registry)


if __name__ == "__main__":
    main()
