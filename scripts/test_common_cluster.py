"""Exercise admission and Gateway traffic in an explicitly selected disposable kind cluster."""

import argparse
import copy
import hashlib
import json
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.request import Request, urlopen

import yaml
from common_schema import ROOT, compose, validate_manifest


def run(*args, data=None, check=True, timeout=180):
    result = subprocess.run(
        args, input=data, text=True, capture_output=True, timeout=timeout, check=False
    )
    if check and result.returncode:
        raise RuntimeError(f"{' '.join(map(str, args))}: {result.stderr}")
    return result


def eventually(check, timeout=120):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (OSError, RuntimeError, ValueError) as error:
            last = error
        time.sleep(2)
    raise AssertionError(f"Condition did not become true: {last}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kubeconfig", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--gateway", action="store_true")
    args = parser.parse_args()
    kube = ["kubectl", "--kubeconfig", str(args.kubeconfig)]
    context = run(*kube, "config", "current-context").stdout.strip()
    if not context.startswith("kind-common-validation"):
        raise ValueError("Tests require an isolated kind-common-validation context")
    version = json.loads(run(*kube, "version", "-o", "json").stdout)["serverVersion"][
        "gitVersion"
    ]
    sources = json.loads(
        (ROOT / "charts/common/schema/vendor/sources.json").read_text()
    )
    args.cache.mkdir(parents=True, exist_ok=True)
    crds = []
    for name, source in sources.items():
        if name.startswith("kubernetes-"):
            continue
        path = args.cache / name
        if not path.exists():
            with urlopen(source["url"], timeout=120) as response:
                path.write_bytes(response.read())
        if hashlib.sha256(path.read_bytes()).hexdigest() != source["sha256"]:
            raise ValueError(f"CRD checksum mismatch: {name}")
        for crd in yaml.safe_load_all(path.read_text()):
            if (
                crd
                and crd.get("kind") == "CustomResourceDefinition"
                and crd["spec"]["names"]["kind"]
                in {
                    "HTTPRoute",
                    "GRPCRoute",
                    "TLSRoute",
                    "TCPRoute",
                    "UDPRoute",
                    "ListenerSet",
                    "Gateway",
                    "GatewayClass",
                    "ReferenceGrant",
                    "Certificate",
                    "ExternalSecret",
                    "ServiceMonitor",
                    "PodMonitor",
                }
            ):
                crds.append(crd)
    run(
        *kube,
        "apply",
        "--server-side",
        "--field-manager=common-validation",
        "--force-conflicts",
        "-f",
        "-",
        data=yaml.safe_dump_all(crds),
    )
    run(*kube, "wait", "--for=condition=Established", "crd", "--all", "--timeout=120s")
    for ns in ["apps", "edge", "rejected"]:
        run(
            *kube,
            "apply",
            "--server-side",
            "--field-manager=common-validation",
            "--force-conflicts",
            "-f",
            "-",
            data=yaml.safe_dump(
                {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}}
            ),
        )
    with tempfile.TemporaryDirectory(prefix="common-admission-") as temp:
        chart = Path(temp)
        (chart / "templates").mkdir()
        (chart / "charts").mkdir()
        shutil.copytree(ROOT / "charts/common", chart / "charts/common")
        (chart / "Chart.yaml").write_text(
            "apiVersion: v2\nname: admission\nversion: 1.0.0\n"
        )
        (chart / "templates/all.yaml").write_text('{{ include "common.all" . }}')
        (chart / "values.schema.json").write_text(json.dumps(compose()))
        values = {
            "fullnameOverride": "web",
            "components": {
                "main": {
                    "container": {
                        "image": {"repository": "nginx", "tag": "1.27.5"},
                        "ports": {"http": {"port": 80}},
                    },
                    "services": {
                        "main": {},
                        "alternate": {"ports": {"http": {"port": 8080}}},
                    },
                    "rbac": {
                        "roles": {
                            "read": {
                                "rules": {
                                    "pods": {
                                        "apiGroups": [""],
                                        "resources": ["pods"],
                                        "verbs": ["get", "list"],
                                    }
                                }
                            }
                        },
                        "bindings": {"read": {"role": "read"}},
                    },
                    "networkPolicies": {"allow": {"ingress": {"all": {}}}},
                    "serviceMonitors": {"main": {"endpoints": {"http": {}}}},
                    "podMonitors": {"main": {"endpoints": {"http": {}}}},
                    "listenerSets": {
                        "extra": {
                            "parentRef": {"name": "edge", "namespace": "edge"},
                            "listeners": {"extra": {"port": 8081, "protocol": "HTTP"}},
                        }
                    },
                    "routes": {
                        "direct": {
                            "parentRefs": {
                                "edge": {
                                    "name": "edge",
                                    "namespace": "edge",
                                    "sectionName": "http",
                                }
                            },
                            "rules": [
                                {
                                    "backendRefs": [
                                        {"service": "alternate", "port": "http"}
                                    ]
                                }
                            ],
                        },
                        "delegated": {
                            "parentRefs": {
                                "extra": {
                                    "listenerSet": "extra",
                                    "sectionName": "extra",
                                }
                            },
                            "rules": [
                                {"backendRefs": [{"service": "main", "port": "http"}]}
                            ],
                        },
                    },
                }
            },
            "appResources": {
                "certificate": {
                    "test": {
                        "issuerRef": {"name": "uninstalled"},
                        "dnsNames": ["example.com"],
                    }
                },
                "externalSecret": {
                    "test": {
                        "storeRef": {"name": "uninstalled", "kind": "SecretStore"},
                        "data": {"test": {"remoteRef": {"key": "test"}}},
                    }
                },
            },
        }
        (chart / "values.yaml").write_text(yaml.safe_dump(values))
        rendered = run(
            "helm",
            "template",
            "test",
            str(chart),
            "-n",
            "apps",
            "--kube-version",
            version,
        ).stdout
        docs = list(yaml.safe_load_all(rendered))
        for doc in docs:
            validate_manifest(doc, version)
        run(
            *kube,
            "apply",
            "--server-side",
            "--field-manager=common-validation",
            "--force-conflicts",
            "--dry-run=server",
            "-f",
            "-",
            data=rendered,
        )
        bad = copy.deepcopy(next(d for d in docs if d["kind"] == "Deployment"))
        bad["spec"]["template"]["spec"]["containers"][0]["livenessProbe"] = {
            "httpGet": {"path": "/", "port": 80},
            "exec": {"command": ["true"]},
        }
        result = run(
            *kube,
            "apply",
            "--server-side",
            "--field-manager=common-validation",
            "--force-conflicts",
            "--dry-run=server",
            "-f",
            "-",
            data=yaml.safe_dump(bad),
            check=False,
        )
        assert result.returncode and "more than 1 handler" in result.stderr, (
            result.stderr
        )
        bad = copy.deepcopy(next(d for d in docs if d["kind"] == "ListenerSet"))
        bad["spec"]["listeners"][0]["tls"] = {"mode": "Terminate"}
        result = run(
            *kube,
            "apply",
            "--server-side",
            "--field-manager=common-validation",
            "--force-conflicts",
            "--dry-run=server",
            "-f",
            "-",
            data=yaml.safe_dump(bad),
            check=False,
        )
        assert result.returncode and "tls must not be specified" in result.stderr, (
            result.stderr
        )
        for kind in ["Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"]:
            component = {
                "kind": kind,
                "container": values["components"]["main"]["container"],
            }
            if kind == "CronJob":
                component["cronjob"] = {"schedule": "0 * * * *"}
            if kind == "StatefulSet":
                component["statefulset"] = {
                    "volumeClaimTemplates": {
                        "data": {"size": "1Gi", "mounts": {"/data": {}}}
                    }
                }
            if kind == "Deployment":
                component["hpa"] = {"enabled": True, "min": 1, "max": 3}
                component["pdb"] = {"enabled": True, "maxUnavailable": 1}
            (chart / "values.yaml").write_text(
                yaml.safe_dump({"components": {"main": component}})
            )
            controller_docs = run(
                "helm",
                "template",
                "controller-" + kind.lower(),
                str(chart),
                "-n",
                "apps",
                "--kube-version",
                version,
            ).stdout
            for doc in yaml.safe_load_all(controller_docs):
                validate_manifest(doc, version)
            run(
                *kube,
                "apply",
                "--server-side",
                "--field-manager=common-validation",
                "--force-conflicts",
                "--dry-run=server",
                "-f",
                "-",
                data=controller_docs,
            )
        print(
            f"PASS {version}: {len(docs)} admitted resources plus all five workload kinds; invalid native and Gateway CEL cases rejected",
            flush=True,
        )
        if not args.gateway:
            return
        run(
            "helm",
            "upgrade",
            "--install",
            "istio-base",
            "base",
            "--repo",
            "https://blob.istio.io/istio-release/charts",
            "--version",
            "1.31.0",
            "-n",
            "istio-system",
            "--create-namespace",
            "--kubeconfig",
            str(args.kubeconfig),
            "--wait",
            "--timeout",
            "180s",
            timeout=240,
        )
        run(
            "helm",
            "upgrade",
            "--install",
            "istiod",
            "istiod",
            "--repo",
            "https://blob.istio.io/istio-release/charts",
            "--version",
            "1.31.0",
            "-n",
            "istio-system",
            "--kubeconfig",
            str(args.kubeconfig),
            "--wait",
            "--timeout",
            "180s",
            timeout=240,
        )
        gateway = {
            "apiVersion": "gateway.networking.k8s.io/v1",
            "kind": "Gateway",
            "metadata": {
                "name": "edge",
                "namespace": "edge",
                "annotations": {"networking.istio.io/service-type": "ClusterIP"},
            },
            "spec": {
                "gatewayClassName": "istio",
                "allowedListeners": {
                    "namespaces": {
                        "from": "Selector",
                        "selector": {
                            "matchLabels": {"kubernetes.io/metadata.name": "apps"}
                        },
                    }
                },
                "listeners": [
                    {
                        "name": "http",
                        "port": 8080,
                        "protocol": "HTTP",
                        "allowedRoutes": {"namespaces": {"from": "All"}},
                    }
                ],
            },
        }

        def shared_resources(resources, namespace):
            (chart / "templates/all.yaml").write_text(
                '{{ include "common.resources" . }}'
            )
            (chart / "values.yaml").write_text(
                yaml.safe_dump({"components": {}, "appResources": resources})
            )
            result = run(
                "helm", "template", "owners", str(chart), "-n", namespace
            ).stdout
            for doc in yaml.safe_load_all(result):
                validate_manifest(doc, version)
            run(
                *kube,
                "apply",
                "--server-side",
                "--field-manager=common-validation",
                "--force-conflicts",
                "-f",
                "-",
                data=result,
            )

        shared_resources(
            {
                "gateway": {
                    "edge": {
                        "name": "edge",
                        "annotations": gateway["metadata"]["annotations"],
                        "spec": gateway["spec"],
                    }
                }
            },
            "edge",
        )
        run(
            *kube,
            "apply",
            "--server-side",
            "--field-manager=common-validation",
            "--force-conflicts",
            "-f",
            "-",
            data=rendered,
        )
        run(
            *kube,
            "rollout",
            "status",
            "deployment/web",
            "-n",
            "apps",
            "--timeout=180s",
            timeout=200,
        )

        def resource(kind, name, ns="apps"):
            return json.loads(
                run(*kube, "get", kind, name, "-n", ns, "-o", "json").stdout
            )

        def condition(kind, name, expected, ns="apps"):
            status = resource(kind, name, ns).get("status", {})
            return any(
                c["type"] == expected and c["status"] == "True"
                for c in status.get("conditions", [])
            )

        eventually(lambda: condition("gateway", "edge", "Programmed", "edge"), 180)
        eventually(lambda: condition("listenerset", "web-extra", "Accepted"))
        for name in ["web-direct", "web-delegated"]:
            eventually(
                lambda name=name: any(
                    all(
                        any(
                            c["type"] == target and c["status"] == "True"
                            for c in parent["conditions"]
                        )
                        for target in ["Accepted", "ResolvedRefs"]
                    )
                    for parent in resource("httproute", name)
                    .get("status", {})
                    .get("parents", [])
                )
            )
        for verb, expected in [("list", "yes"), ("delete", "no")]:
            result = run(
                *kube,
                "auth",
                "can-i",
                verb,
                "pods",
                "-n",
                "apps",
                "--as",
                "system:serviceaccount:apps:web",
                check=False,
            )
            assert result.stdout.strip() == expected, result.stdout
        rejected = copy.deepcopy(next(d for d in docs if d["kind"] == "ListenerSet"))
        rejected["metadata"]["namespace"] = "rejected"
        rejected["spec"]["listeners"][0]["port"] = 8082
        run(
            *kube,
            "apply",
            "--server-side",
            "--field-manager=common-validation",
            "--force-conflicts",
            "-f",
            "-",
            data=yaml.safe_dump(rejected),
        )
        eventually(
            lambda: any(
                c["type"] == "Accepted"
                and c["status"] == "False"
                and c["reason"] == "NotAllowed"
                for c in resource("listenerset", "web-extra", "rejected")
                .get("status", {})
                .get("conditions", [])
            )
        )
        service = eventually(
            lambda: next(
                (
                    s
                    for s in json.loads(
                        run(*kube, "get", "svc", "-n", "edge", "-o", "json").stdout
                    )["items"]
                    if {8080, 8081}.issubset({p["port"] for p in s["spec"]["ports"]})
                ),
                None,
            )
        )
        assert 8082 not in {p["port"] for p in service["spec"]["ports"]}
        run(
            *kube,
            "delete",
            "referencegrant",
            "common-cross-grant",
            "-n",
            "apps",
            "--ignore-not-found",
        )
        shared_resources(
            {
                "route": {
                    "cross": {
                        "name": "common-cross-route",
                        "hostnames": ["cross.example.test"],
                        "parentRefs": {"edge": {"name": "edge", "sectionName": "http"}},
                        "rules": [
                            {
                                "backendRefs": [
                                    {"name": "web", "namespace": "apps", "port": 80}
                                ]
                            }
                        ],
                    }
                }
            },
            "edge",
        )

        def cross_reference(status, reason=None):
            return any(
                c["type"] == "ResolvedRefs"
                and c["status"] == status
                and (reason is None or c["reason"] == reason)
                for parent in resource("httproute", "common-cross-route", "edge")
                .get("status", {})
                .get("parents", [])
                for c in parent["conditions"]
            )

        eventually(lambda: cross_reference("False", "RefNotPermitted"))
        shared_resources(
            {
                "referenceGrant": {
                    "cross": {
                        "name": "common-cross-grant",
                        "spec": {
                            "from": [
                                {
                                    "group": "gateway.networking.k8s.io",
                                    "kind": "HTTPRoute",
                                    "namespace": "edge",
                                }
                            ],
                            "to": [{"group": "", "kind": "Service", "name": "web"}],
                        },
                    }
                }
            },
            "apps",
        )
        eventually(lambda: cross_reference("True"))
        for remote in [8080, 8081]:
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                local = sock.getsockname()[1]
            proc = subprocess.Popen(
                [
                    *kube,
                    "port-forward",
                    "-n",
                    "edge",
                    "svc/" + service["metadata"]["name"],
                    f"{local}:{remote}",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:

                def request(local=local):
                    with urlopen(f"http://127.0.0.1:{local}/", timeout=3) as response:
                        return (
                            response.status == 200
                            and b"Welcome to nginx" in response.read()
                        )

                eventually(request)
                if remote == 8080:

                    def cross_request(local=local):
                        req = Request(
                            f"http://127.0.0.1:{local}/",
                            headers={"Host": "cross.example.test"},
                        )
                        with urlopen(req, timeout=3) as response:
                            return (
                                response.status == 200
                                and b"Welcome to nginx" in response.read()
                            )

                    eventually(cross_request)
            finally:
                proc.terminate()
                proc.wait(timeout=10)
        print(
            "PASS Istio 1.31: direct and ListenerSet HTTP traffic, named Services, RBAC permissions, denied ListenerSet attachment, and cross-namespace ReferenceGrant enforcement",
            flush=True,
        )


if __name__ == "__main__":
    main()
