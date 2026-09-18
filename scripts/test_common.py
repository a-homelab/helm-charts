"""Exercise real Helm coalescing, schema validation and generated resource wiring."""

import copy
import importlib.util
import json
import shutil
import subprocess

import pytest
import yaml
from common_schema import ROOT, compose, validate_manifest


@pytest.fixture
def render(tmp_path):
    chart = tmp_path / "chart"
    (chart / "templates").mkdir(parents=True)
    (chart / "charts").mkdir()
    shutil.copytree(ROOT / "charts/common", chart / "charts/common")
    (chart / "Chart.yaml").write_text(
        "apiVersion: v2\nname: check\nversion: 1.0.0\nappVersion: '1.0'\n"
    )
    (chart / "templates/all.yaml").write_text('{{ include "common.all" . }}')
    (chart / "values.schema.json").write_text(json.dumps(compose()))

    def run(
        values, *overlays, error=None, template=None, validate=True, extension=None
    ):
        (chart / "values.schema.json").write_text(json.dumps(compose(extension)))
        (chart / "values.yaml").write_text(yaml.safe_dump(values))
        if template:
            (chart / "templates/all.yaml").write_text(template)
        cmd = ["helm", "template", "test", str(chart), "--namespace", "apps"]
        for index, overlay in enumerate(overlays):
            file = tmp_path / f"overlay-{index}.yaml"
            file.write_text(yaml.safe_dump(overlay))
            cmd += ["-f", str(file)]
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30, check=False
        )
        if error:
            assert result.returncode != 0, result.stdout
            assert error in result.stderr, result.stderr
            return []
        assert result.returncode == 0, result.stderr
        docs = [doc for doc in yaml.safe_load_all(result.stdout) if doc]
        for doc in docs:
            if validate:
                validate_manifest(doc)
        identities = [
            (
                d["apiVersion"].split("/")[0],
                d["kind"],
                d["metadata"].get("namespace"),
                d["metadata"]["name"],
            )
            for d in docs
        ]
        assert len(identities) == len(set(identities))
        return docs

    return run


def app(**component):
    return {
        "components": {
            "main": {
                "container": {
                    "image": {"repository": "nginx"},
                    "ports": {"http": {"port": 8080}},
                },
                **component,
            }
        }
    }


def one(docs, kind, name=None):
    return next(
        d
        for d in docs
        if d["kind"] == kind and (name is None or d["metadata"]["name"] == name)
    )


def pod(docs):
    return one(docs, "Deployment")["spec"]["template"]["spec"]


def test_multiple_services_routes_and_listener_sets(render):
    values = app(
        services={
            "main": {"ports": {"http": {"port": 80}}},
            "internal": {"clusterIP": "None"},
            "metrics": {"ports": {"stats": {"port": 9000, "targetPort": 9001}}},
        },
        listenerSets={
            "main": {
                "parentRef": {"name": "edge", "namespace": "gateways"},
                "listeners": {
                    "https": {
                        "protocol": "HTTPS",
                        "port": 443,
                        "hostname": "app.example.com",
                        "tls": {
                            "mode": "Terminate",
                            "certificateRefs": [{"name": "app-tls"}],
                        },
                    }
                },
            },
            "private": {
                "parentRef": {"name": "internal"},
                "listeners": {"http": {"protocol": "HTTP", "port": 8080}},
            },
        },
        routes={
            "main": {
                "parentRefs": {
                    "secure": {"listenerSet": "main", "sectionName": "https"}
                },
                "rules": [{"backendRefs": [{"service": "main", "port": "http"}]}],
            },
            "metrics": {
                "rules": [{"backendRefs": [{"service": "metrics", "port": "stats"}]}]
            },
            "redirect": {
                "rules": [
                    {
                        "filters": [
                            {
                                "type": "RequestRedirect",
                                "requestRedirect": {
                                    "scheme": "https",
                                    "statusCode": 301,
                                },
                            }
                        ]
                    }
                ]
            },
        },
    )
    docs = render(values)
    assert len([d for d in docs if d["kind"] == "Service"]) == 3
    assert len([d for d in docs if d["kind"] == "HTTPRoute"]) == 3
    assert len([d for d in docs if d["kind"] == "ListenerSet"]) == 2
    route = one(docs, "HTTPRoute", "test-check")
    assert route["spec"]["parentRefs"] == [
        {
            "name": "test-check",
            "group": "gateway.networking.k8s.io",
            "kind": "ListenerSet",
            "sectionName": "https",
        }
    ]
    assert route["spec"]["rules"][0]["backendRefs"] == [
        {"name": "test-check", "port": 80}
    ]
    assert (
        "backendRefs"
        not in one(docs, "HTTPRoute", "test-check-redirect")["spec"]["rules"][0]
    )


@pytest.mark.parametrize(
    "kind", ["HTTPRoute", "GRPCRoute", "TLSRoute", "TCPRoute", "UDPRoute"]
)
def test_route_families(render, kind):
    docs = render(
        app(
            routes={
                "main": {
                    "kind": kind,
                    **(
                        {"hostnames": ["app.example.com"]} if kind == "TLSRoute" else {}
                    ),
                }
            }
        )
    )
    assert one(docs, kind)["spec"]["rules"][0]["backendRefs"][0]["port"] == 8080


def test_named_service_does_not_inject_main(render):
    docs = render(app(services={"web": {}}))
    assert [d["metadata"]["name"] for d in docs if d["kind"] == "Service"] == [
        "test-check-web"
    ]
    render(
        app(services={"web": {}}, routes={"main": {}}), error="services.main is missing"
    )


def test_disabled_services_and_listener_sets_reject_references(render):
    render(
        app(services={"main": {"enabled": False}}, routes={"main": {}}),
        error="services.main is missing",
    )
    render(
        app(
            listenerSets={"edge": {"enabled": False}},
            routes={"main": {"parentRefs": {"edge": {"listenerSet": "edge"}}}},
        ),
        error="unknown or disabled ListenerSet",
    )


def test_statefulset_governing_service_and_clients(render):
    docs = render(
        app(
            kind="StatefulSet",
            statefulset={"service": "headless", "replicas": 0},
            services={"headless": {"clusterIP": "None"}, "main": {}},
        )
    )
    spec = one(docs, "StatefulSet")["spec"]
    assert spec["replicas"] == 0
    assert spec["serviceName"] == "test-check-headless"
    render(
        app(
            kind="StatefulSet",
            statefulset={"service": "main", "serviceName": "external"},
        ),
        error="mutually exclusive",
    )


def test_explicit_zero_values_survive(render):
    docs = render(
        app(
            deployment={"replicas": 0},
            pdb={"enabled": True, "maxUnavailable": 0},
            pod={
                "volumes": {
                    "config": {
                        "configMap": {"name": "external", "defaultMode": 0},
                    }
                }
            },
        )
    )
    assert one(docs, "Deployment")["spec"]["replicas"] == 0
    assert one(docs, "PodDisruptionBudget")["spec"]["maxUnavailable"] == 0
    assert pod(docs)["volumes"][0]["configMap"]["defaultMode"] == 0
    docs = render(
        app(
            kind="Job",
            job={"parallelism": 0, "backoffLimit": 0, "ttlSecondsAfterFinished": 0},
        )
    )
    assert all(
        one(docs, "Job")["spec"][key] == 0
        for key in ["parallelism", "backoffLimit", "ttlSecondsAfterFinished"]
    )


def test_remove_survives_real_helm_coalescing(render):
    values = app()
    values["defaults"] = {"container": {"env": {"FOO": "inherited"}}}
    values["components"]["main"]["container"]["env"] = {"FOO": "chart"}
    docs = render(
        values,
        {
            "components": {
                "main": {
                    "container": {"env": {"FOO": None}},
                    "remove": ["/container/env/FOO"],
                }
            }
        },
    )
    assert not pod(docs)["containers"][0].get("env")
    assert render(values, {"components": {"main": {"enabled": False}}}) == []


def test_null_handlers_and_weighted_env(render):
    values = app(hpa=None, remove=["/container/probes/readiness/httpGet"])
    values["defaults"] = {
        "container": {
            "probes": {"readiness": {"httpGet": {"path": "/", "port": "http"}}}
        }
    }
    c = values["components"]["main"]["container"]
    c["probes"] = {"readiness": {"httpGet": None, "tcpSocket": {"port": "http"}}}
    c["env"] = {
        "Z": {"weight": 0, "value": 123},
        "A": {"weight": 1, "value": "$(Z)"},
        "BOOL": {"value": False},
    }
    result = pod(render(values))["containers"][0]
    assert result["env"] == [
        {"name": "Z", "value": "123"},
        {"name": "A", "value": "$(Z)"},
        {"name": "BOOL", "value": "false"},
    ]
    assert result["readinessProbe"] == {"tcpSocket": {"port": "http"}}


def test_container_defaults_ordering_and_partial_image(render):
    values = app(
        containerDefaults={"securityContext": {"runAsNonRoot": True}},
        sidecars={"proxy": {"image": {"tag": "2"}}},
        initContainers={
            "z-first": {"weight": 0, "command": ["true"]},
            "a-last": {"weight": 1, "command": ["true"]},
        },
    )
    p = pod(render(values))
    assert [c["name"] for c in p["initContainers"]] == ["z-first", "a-last"]
    assert p["containers"][1]["image"] == "nginx:2"
    assert all(
        c["securityContext"]["runAsNonRoot"]
        for c in p["containers"] + p["initContainers"]
    )


def test_native_sidecar_ports_and_service_overrides(render):
    values = app(
        initContainers={
            "proxy": {"restartPolicy": "Always", "ports": {"proxy": {"port": 4180}}}
        },
        services={
            "main": {
                "ports": {"proxy": {}},
                "overrides": {
                    "metadata": {"name": "public"},
                    "spec": {
                        "ports": [{"name": "proxy", "port": 80, "targetPort": "proxy"}]
                    },
                },
            }
        },
        routes={"main": {}},
    )
    ref = one(render(values), "HTTPRoute")["spec"]["rules"][0]["backendRefs"][0]
    assert ref == {"name": "public", "port": 80}


def test_ambiguous_route_port_fails(render):
    values = app(routes={"main": {}})
    values["components"]["main"]["container"]["ports"]["metrics"] = {"port": 9090}
    render(values, error="requires an explicit backend port")


def test_parent_refs_allow_same_gateway_on_two_listeners(render):
    docs = render(
        app(
            routes={
                "main": {
                    "parentRefs": {
                        "secure": {"name": "edge", "sectionName": "https"},
                        "plain": {"name": "edge", "sectionName": "http"},
                    }
                }
            }
        )
    )
    assert len(one(docs, "HTTPRoute")["spec"]["parentRefs"]) == 2


def test_externalname_without_ports(render):
    values = app(
        services={
            "dns": {
                "type": "ExternalName",
                "externalName": "db.example.com",
                "ports": {},
            }
        }
    )
    svc = one(render(values), "Service")
    assert svc["spec"] == {"type": "ExternalName", "externalName": "db.example.com"}


def test_selector_overrides_fail(render):
    values = app(pod={"labels": {"app.kubernetes.io/name": "wrong"}})
    render(values, error="reserved for the component selector")
    render(
        app(
            overrides={
                "spec": {
                    "template": {
                        "metadata": {"labels": {"app.kubernetes.io/name": "wrong"}}
                    }
                }
            }
        ),
        error="reserved selector label",
    )


def test_long_names_and_duplicate_final_identities(render):
    values = app()
    values["fullnameOverride"] = "a" * 63
    values["components"]["worker"] = copy.deepcopy(values["components"]["main"])
    docs = render(values)
    names = [d["metadata"]["name"] for d in docs if d["kind"] == "Deployment"]
    assert len(set(names)) == 2
    assert all(len(n) <= 63 for n in names)
    render(
        app(services={"main": {}, "other": {"name": "test-check"}}),
        error="duplicate resource identity",
    )


@pytest.mark.parametrize(
    "component, error",
    [
        (
            {
                "container": {
                    "image": {"repository": "nginx"},
                    "volumeMounts": {"tmp": {"name": "typo", "mountPath": "/tmp"}},
                }
            },
            "unknown volume",
        ),
        ({"sidecars": {"main": {}}}, "duplicates the main container"),
        ({"sidecars": {"other": {"name": "main"}}}, "duplicate container name"),
        ({"hpa": {"enabled": True}, "kind": "Job"}, "hpa requires"),
        (
            {"pdb": {"enabled": True, "minAvailable": 1, "maxUnavailable": 0}},
            "exactly one",
        ),
    ],
)
def test_invalid_resolved_combinations(render, component, error):
    render(app(**component), error=error)


def test_native_pvc_and_renamed_config_reference(render):
    values = app(
        pod={
            "volumes": {
                "data": {
                    "persistentVolumeClaim": {
                        "claimName": '{{ include "common.ref" (list . "pvc" "data") }}'
                    }
                },
                "cfg": {
                    "configMap": {
                        "name": '{{ include "common.ref" (list . "configMap" "config") }}'
                    }
                },
            }
        }
    )
    values["appResources"] = {
        "pvc": {
            "data": {
                "metadata": {"name": "restored-data"},
                "spec": {
                    "accessModes": ["ReadWriteOnce"],
                    "storageClassName": "",
                    "resources": {"requests": {"storage": "1Gi"}},
                    "dataSource": {
                        "apiGroup": "snapshot.storage.k8s.io",
                        "kind": "VolumeSnapshot",
                        "name": "restore",
                    },
                },
            }
        },
        "configMap": {
            "config": {
                "data": {"key": "value"},
                "overrides": {"metadata": {"name": "renamed"}},
            }
        },
    }
    docs = render(values)
    pvc = one(docs, "PersistentVolumeClaim")
    assert pvc["metadata"]["name"] == "restored-data"
    assert pvc["spec"]["dataSource"]["name"] == "restore"
    assert pvc["spec"]["storageClassName"] == ""
    volumes = {v["name"]: v for v in pod(docs)["volumes"]}
    assert volumes["data"]["persistentVolumeClaim"]["claimName"] == "restored-data"
    assert volumes["cfg"]["configMap"]["name"] == "renamed"
    without_metadata = render(
        values, {"appResources": {"pvc": {"data": {"metadata": None}}}}
    )
    assert (
        one(without_metadata, "PersistentVolumeClaim")["metadata"]["name"]
        == "test-check-data"
    )
    assert (
        next(v for v in pod(without_metadata)["volumes"] if v["name"] == "data")[
            "persistentVolumeClaim"
        ]["claimName"]
        == "test-check-data"
    )


def test_raw_preserves_template_syntax_and_nulls_and_cluster_scope(render):
    values = app(enabled=False)
    values["rawResources"] = {
        "opaque": {
            "scope": "Cluster",
            "manifest": {
                "apiVersion": "example.io/v1",
                "kind": "Policy",
                "spec": {"expression": "{{ other.system }}", "nullable": None},
            },
        }
    }
    values["rawResources"]["opaque"]["manifest"] = yaml.safe_dump(
        values["rawResources"]["opaque"]["manifest"]
    )
    m = render(values, validate=False)[0]
    assert "namespace" not in m["metadata"]
    assert m["spec"] == {"expression": "{{ other.system }}", "nullable": None}
    values["rawResources"]["opaque"]["manifest"] = (
        "apiVersion: v1\nkind: ConfigMap\n---\napiVersion: v1\nkind: Secret\n"
    )
    render(values, error="one YAML document")


def test_checksum_hashes_rendered_config(render):
    values = app(
        pod={
            "annotations": {
                "checksum/config": '{{ include "common.checksum.configMap" (list . "config") }}'
            }
        }
    )
    values["global"] = {"domain": "one.example"}
    values["appResources"] = {
        "configMap": {
            "config": {"tpl": True, "data": {"domain": "{{ .Values.global.domain }}"}}
        }
    }
    first = one(render(values), "Deployment")["spec"]["template"]["metadata"][
        "annotations"
    ]
    second = one(render(values, {"global": {"domain": "two.example"}}), "Deployment")[
        "spec"
    ]["template"]["metadata"]["annotations"]
    assert first != second


def test_component_entrypoint_with_shared_resources(render):
    values = app()
    values["appResources"] = {"configMap": {"config": {"data": {"key": "value"}}}}
    docs = render(
        values,
        template='{{ include "common.component" (dict "ctx" . "name" "main") }}{{ include "common.resources" . }}',
    )
    assert len(docs) == 4


def test_schema_rejects_typos_and_accepts_partial_overlay(render):
    values = app()
    values["components"]["main"]["contianer"] = {}
    render(values, error="contianer")
    values = app()
    docs = render(
        values,
        {"components": {"main": {"container": {"ports": {"http": {"expose": 80}}}}}},
    )
    assert one(docs, "Service")["spec"]["ports"][0]["port"] == 80


def test_merge_has_no_silent_frame_limit(render):
    values = app()
    values["defaults"] = {
        "container": {"env": {f"VAR_{i}": {"value": "old"} for i in range(1100)}}
    }
    values["components"]["main"]["container"]["env"] = {
        f"VAR_{i}": {"value": "new"} for i in range(1100)
    }
    env = pod(render(values))["containers"][0]["env"]
    assert len(env) == 1100
    assert all(e["value"] == "new" for e in env)


@pytest.mark.parametrize(
    "path",
    sorted((ROOT / "charts").glob("*/values-v2.yaml")),
    ids=lambda p: p.parent.name,
)
def test_migration_values_render_against_native_schemas(render, path):
    values = yaml.safe_load(path.read_text())
    properties = {
        "primaryInterface": {"type": "string"},
        "infraNetworkInterface": {"type": "string"},
        "threadNetworkInterface": {"type": "string"},
        "rcpDeviceHostPath": {"type": "string"},
        "logLevel": {"type": "integer"},
    }
    extension = {
        "properties": {key: spec for key, spec in properties.items() if key in values}
    }
    render(values, extension=extension)


def test_migration_comparison_preserves_empty_volume_sources():
    spec = importlib.util.spec_from_file_location(
        "migration", ROOT / "scripts/verify-common-migration.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    original = {
        "spec": {"template": {"spec": {"volumes": [{"name": "tmp", "emptyDir": {}}]}}}
    }
    broken = {"spec": {"template": {"spec": {"volumes": [{"name": "tmp"}]}}}}
    assert module.classify(original, broken)[0] == "DIFFERENT"
    rendered = "apiVersion: v1\nkind: ConfigMap\nmetadata: {name: same, namespace: a}\n---\napiVersion: v1\nkind: ConfigMap\nmetadata: {name: same, namespace: b}\n"
    assert len(module.parse_docs(rendered)) == 2


def test_native_claim_template_and_volume_collision(render):
    values = app(
        kind="StatefulSet",
        statefulset={
            "volumeClaimTemplates": {
                "data": {
                    "metadata": {"annotations": {"example.com/retain": "true"}},
                    "spec": {
                        "accessModes": ["ReadWriteOnce"],
                        "resources": {"requests": {"storage": "1Gi"}},
                        "volumeMode": "Filesystem",
                    },
                }
            }
        },
    )
    values["components"]["main"]["container"]["volumeMounts"] = {
        "data": {"name": "data", "mountPath": "/data"}
    }
    docs = render(values)
    claim = one(docs, "StatefulSet")["spec"]["volumeClaimTemplates"][0]
    assert claim["spec"]["volumeMode"] == "Filesystem"
    assert claim["metadata"]["name"] == "data"
    assert claim["metadata"]["annotations"]["example.com/retain"] == "true"
    assert not any(d["kind"] == "PersistentVolumeClaim" for d in docs)
    values["components"]["main"]["pod"] = {"volumes": {"data": {"emptyDir": {}}}}
    render(values, error="duplicates a pod volume")


def test_final_service_target_and_numeric_image_tag(render):
    values = app()
    values["components"]["main"]["container"]["image"]["tag"] = 0
    assert pod(render(values))["containers"][0]["image"] == "nginx:0"
    values["components"]["main"]["container"]["overrides"] = {"ports": []}
    render(values, error="targets missing final container port")


def test_shared_listener_set_reference(render):
    values = app(
        routes={
            "main": {"parentRefs": {"shared": {"ref": "edge", "sectionName": "http"}}}
        }
    )
    values["appResources"] = {
        "listenerSet": {
            "edge": {
                "name": "shared-edge",
                "parentRef": {"name": "gateway"},
                "listeners": {"http": {"port": 8080, "protocol": "HTTP"}},
            }
        }
    }
    docs = render(values)
    assert (
        one(docs, "HTTPRoute")["spec"]["parentRefs"][0]["name"]
        == one(docs, "ListenerSet")["metadata"]["name"]
        == "shared-edge"
    )


def test_removing_derived_services_and_selected_ports(render):
    assert not any(d["kind"] == "Service" for d in render(app(remove=["/services"])))
    values = app(
        services={"main": {"ports": {"http": {}, "metrics": {}}}},
        remove=["/services/main/ports/metrics"],
    )
    values["components"]["main"]["container"]["ports"]["metrics"] = {"port": 9090}
    assert [p["name"] for p in one(render(values), "Service")["spec"]["ports"]] == [
        "http"
    ]
    render(app(remove=["/services/main/ports/http"]), error="missing or non-map parent")


def test_rbac_policy_and_monitor_relationships(render):
    docs = render(
        app(
            services={
                "main": {},
                "metrics": {"ports": {"http": {}}, "name": "metrics-final"},
            },
            serviceAccount={"name": "runner"},
            rbac={
                "roles": {
                    "reader": {
                        "rules": {
                            "pods": {
                                "apiGroups": [""],
                                "resources": ["pods"],
                                "verbs": ["get", "list"],
                            }
                        }
                    },
                    "cluster": {
                        "kind": "ClusterRole",
                        "rules": {
                            "nodes": {
                                "apiGroups": [""],
                                "resources": ["nodes"],
                                "verbs": ["get"],
                            }
                        },
                    },
                },
                "bindings": {
                    "reader": {"role": "reader"},
                    "cluster": {"kind": "ClusterRoleBinding", "role": "cluster"},
                },
            },
            networkPolicies={
                "deny": {"ingress": {}, "egress": {}},
                "self": {
                    "ingress": {
                        "web": {
                            "from": [{"component": "main"}],
                            "ports": [{"port": "http"}],
                        }
                    }
                },
            },
            serviceMonitors={
                "main": {
                    "service": "metrics",
                    "endpoints": {"http": {"interval": "30s"}},
                }
            },
            podMonitors={
                "main": {"endpoints": {"http": {}}},
                "numeric": {"endpoints": {"metrics": {"portNumber": 8080}}},
            },
        )
    )
    assert one(docs, "RoleBinding")["subjects"] == [
        {"kind": "ServiceAccount", "name": "runner", "namespace": "apps"}
    ]
    assert (
        one(docs, "ClusterRoleBinding")["roleRef"]["name"]
        == one(docs, "ClusterRole")["metadata"]["name"]
    )
    assert one(docs, "ClusterRole")["metadata"]["name"].startswith("apps-")
    assert "namespace" not in one(docs, "ClusterRole")["metadata"]
    service = one(docs, "Service", "metrics-final")
    selector = one(docs, "ServiceMonitor")["spec"]["selector"]["matchLabels"]
    assert all(
        service["metadata"]["labels"][key] == value for key, value in selector.items()
    )
    policy = next(
        d
        for d in docs
        if d["kind"] == "NetworkPolicy" and d["metadata"]["name"].endswith("-deny")
    )
    assert policy["spec"]["ingress"] == [] and policy["spec"]["egress"] == []


@pytest.mark.parametrize(
    "component,expected",
    [
        (
            {"rbac": {"bindings": {"bad": {"role": "missing"}}}},
            "missing or disabled role",
        ),
        (
            {"serviceMonitors": {"bad": {"endpoints": {"missing": {}}}}},
            "missing named port",
        ),
        (
            {
                "networkPolicies": {
                    "bad": {"ingress": {"x": {"from": [{"component": "absent"}]}}}
                }
            },
            "unknown component",
        ),
        (
            {
                "podMonitors": {
                    "bad": {"endpoints": {"http": {"port": "http", "portNumber": 8080}}}
                }
            },
            "mutually exclusive",
        ),
        (
            {
                "networkPolicies": {
                    "bad": {
                        "ingress": {
                            "x": {"from": [{"component": "main", "podSelector": {}}]}
                        }
                    }
                }
            },
            "cannot also set",
        ),
    ],
)
def test_invalid_policy_relationships(render, component, expected):
    render(app(**component), error=expected)


def test_app_policy_resources_and_gateway(render):
    values = app()
    values["appResources"] = {
        "role": {
            "read": {
                "rules": {
                    "pods": {"apiGroups": [""], "resources": ["pods"], "verbs": ["get"]}
                }
            }
        },
        "roleBinding": {
            "read": {"ref": "read", "subjects": {"app": {"component": "main"}}}
        },
        "networkPolicy": {"deny": {"podSelector": {}, "ingress": {}}},
        "podMonitor": {"scrape": {"component": "main", "endpoints": {"http": {}}}},
        "gateway": {
            "edge": {
                "spec": {
                    "gatewayClassName": "istio",
                    "listeners": [{"name": "http", "port": 80, "protocol": "HTTP"}],
                    "allowedListeners": {"namespaces": {"from": "Same"}},
                }
            }
        },
        "referenceGrant": {
            "backend": {
                "spec": {
                    "from": [
                        {
                            "group": "gateway.networking.k8s.io",
                            "kind": "HTTPRoute",
                            "namespace": "frontend",
                        }
                    ],
                    "to": [{"group": "", "kind": "Service", "name": "backend"}],
                }
            }
        },
    }
    docs = render(values)
    assert (
        one(docs, "RoleBinding")["roleRef"]["name"]
        == one(docs, "Role")["metadata"]["name"]
    )
    assert one(docs, "PodMonitor")["spec"]["namespaceSelector"] == {
        "matchNames": ["apps"]
    }


@pytest.mark.parametrize("version", [f"1.{minor}.0" for minor in range(31, 38)])
def test_kubernetes_schema_matrix(render, version):
    docs = render(app())
    for doc in docs:
        validate_manifest(doc, version)


def test_custom_output_schemas_fail_closed():
    from common_schema import crd_schemas

    manifest = {
        "apiVersion": "example.com/v1",
        "kind": "Widget",
        "metadata": {"name": "widget"},
        "spec": {"count": 3},
    }
    with pytest.raises(ValueError, match="No output schema"):
        validate_manifest(manifest)
    schemas = crd_schemas(
        [
            {
                "kind": "CustomResourceDefinition",
                "spec": {
                    "group": "example.com",
                    "names": {"kind": "Widget"},
                    "versions": [
                        {
                            "name": "v1",
                            "served": True,
                            "schema": {
                                "openAPIV3Schema": {
                                    "type": "object",
                                    "properties": {
                                        "apiVersion": {"type": "string"},
                                        "kind": {"type": "string"},
                                        "metadata": {"type": "object"},
                                        "spec": {
                                            "type": "object",
                                            "properties": {
                                                "count": {"type": "integer"}
                                            },
                                        },
                                    },
                                }
                            },
                        }
                    ],
                },
            }
        ]
    )
    validate_manifest(manifest, schemas=schemas)
    manifest["spec"]["count"] = "wrong"
    with pytest.raises(ValueError, match="not of type"):
        validate_manifest(manifest, schemas=schemas)
    with pytest.raises(ValueError, match="No output schema"):
        validate_manifest(
            {
                "apiVersion": "gateway.networking.k8s.io/v99",
                "kind": "HTTPRoute",
                "metadata": {"name": "bad"},
            }
        )


def test_output_schema_extensions_preserve_crd_semantics():
    from common_schema import crd_schemas

    schema = {
        "type": "object",
        "properties": {
            "apiVersion": {"type": "string"},
            "kind": {"type": "string"},
            "metadata": {"type": "object"},
            "spec": {
                "type": "object",
                "properties": {"value": {"type": "string", "nullable": True}},
                "x-kubernetes-preserve-unknown-fields": True,
            },
        },
    }
    schemas = crd_schemas(
        [
            {
                "kind": "CustomResourceDefinition",
                "spec": {
                    "group": "example.com",
                    "names": {"kind": "Widget"},
                    "versions": [
                        {
                            "name": "v1",
                            "served": True,
                            "schema": {"openAPIV3Schema": schema},
                        }
                    ],
                },
            }
        ]
    )
    validate_manifest(
        {
            "apiVersion": "example.com/v1",
            "kind": "Widget",
            "metadata": {"name": "widget"},
            "spec": {"value": None, "unknown": {"nested": 1}},
        },
        schemas=schemas,
    )
    with pytest.raises(ValueError, match="cannot replace bundled"):
        validate_manifest(
            {"apiVersion": "v1", "kind": "Service"}, schemas={"v1/Service": {}}
        )
    with pytest.raises(ValueError, match="local references"):
        validate_manifest(
            {"apiVersion": "example.com/v1", "kind": "Widget"},
            schemas={
                "example.com/v1/Widget": {"$ref": "https://example.com/schema.json"}
            },
        )


@pytest.mark.parametrize(
    "template", ['{{ include "common.all" . }}', '{{ include "common.resources" . }}']
)
def test_resource_only_chart_with_explicit_empty_components(render, template):
    docs = render(
        {
            "components": {},
            "appResources": {"configMap": {"settings": {"data": {"mode": "shared"}}}},
        },
        template=template,
    )
    assert [d["kind"] for d in docs] == ["ConfigMap"]


@pytest.mark.parametrize(
    "reference",
    [
        {"component": "main", "namespace": "foreign"},
        {"service": "main", "kind": "Secret"},
        {"component": "main", "group": "example.com"},
    ],
)
def test_managed_backends_cannot_change_resource_identity(render, reference):
    render(
        app(routes={"main": {"rules": [{"backendRefs": [reference]}]}}),
        error="managed backendRef must target",
    )


def test_managed_listener_parent_cannot_change_namespace(render):
    render(
        app(
            listenerSets={
                "main": {
                    "parentRef": {"name": "edge"},
                    "listeners": {"http": {"protocol": "HTTP", "port": 80}},
                }
            },
            routes={
                "main": {
                    "parentRefs": {
                        "main": {"listenerSet": "main", "namespace": "foreign"}
                    }
                }
            },
        ),
        error="managed ListenerSet parentRef must use",
    )


def test_independent_native_mount_maps_and_partial_overrides(render):
    values = app(pod={"volumes": {"workspace": {"emptyDir": {}}}})
    main = values["components"]["main"]
    main["container"]["volumeMounts"] = {
        "workspace": {"name": "workspace", "mountPath": "/workspace", "readOnly": True},
        "exports": {
            "name": "workspace",
            "mountPath": "/exports",
            "subPath": "exports",
            "readOnly": True,
        },
    }
    main["initContainers"] = {
        "prepare": {
            "volumeMounts": {
                "workspace": {
                    "name": "workspace",
                    "mountPath": "/workspace",
                    "readOnly": False,
                },
            }
        }
    }
    main["sidecars"] = {
        "exporter": {
            "volumeMounts": {
                "files": {
                    "name": "workspace",
                    "mountPath": "/workspace",
                    "subPath": "exports",
                    "readOnly": True,
                },
            }
        }
    }
    overlay = {
        "components": {
            "main": {
                "container": {
                    "volumeMounts": {
                        "workspace": {"readOnly": False},
                    }
                }
            }
        }
    }
    initial = pod(render(values))
    initial_main = next(c for c in initial["containers"] if c["name"] == "main")
    assert all(m["readOnly"] for m in initial_main["volumeMounts"])
    assert initial["initContainers"][0]["volumeMounts"][0]["readOnly"] is False
    result = pod(render(values, overlay))
    containers = {c["name"]: c for c in result["containers"] + result["initContainers"]}
    mounts = {m["mountPath"]: m for m in containers["main"]["volumeMounts"]}
    assert mounts["/workspace"] == {
        "name": "workspace",
        "mountPath": "/workspace",
        "readOnly": False,
    }
    assert mounts["/exports"]["subPath"] == "exports"
    assert containers["prepare"]["volumeMounts"][0]["readOnly"] is False
    assert containers["exporter"]["volumeMounts"][0]["readOnly"] is True
    assert containers["exporter"]["volumeMounts"][0]["name"] == "workspace"
    assert result["volumes"] == [{"name": "workspace", "emptyDir": {}}]
    result = pod(
        render(
            values,
            {
                "components": {
                    "main": {"container": {"volumeMounts": {"exports": None}}}
                }
            },
        )
    )
    assert (
        len(
            next(c for c in result["containers"] if c["name"] == "main")["volumeMounts"]
        )
        == 1
    )


def test_native_volume_sources_preserve_fields_and_zero_values(render):
    volumes = {
        "config": {
            "configMap": {"name": "settings", "optional": False, "defaultMode": 0}
        },
        "credentials": {"secret": {"secretName": "creds", "optional": True}},
        "projection": {
            "projected": {
                "defaultMode": 0,
                "sources": [{"secret": {"name": "creds", "optional": True}}],
            }
        },
        "nfs": {
            "nfs": {"server": "nas.example.com", "path": "/exports", "readOnly": True}
        },
        "csi": {
            "csi": {
                "driver": "example.com/csi",
                "readOnly": True,
                "volumeAttributes": {"mode": "test"},
            }
        },
        "ephemeral": {
            "ephemeral": {
                "volumeClaimTemplate": {
                    "spec": {
                        "accessModes": ["ReadWriteOnce"],
                        "resources": {"requests": {"storage": "1Gi"}},
                    }
                }
            }
        },
    }
    actual = pod(render(app(pod={"volumes": volumes})))["volumes"]
    assert actual == [{"name": name, **volumes[name]} for name in sorted(volumes)]


@pytest.mark.parametrize(
    "mounts, error",
    [
        (
            {
                "first": {"name": "work", "mountPath": "/same"},
                "second": {"name": "work", "mountPath": "/same"},
            },
            "mounts path /same more than once",
        ),
        ({"missing": {"name": "absent", "mountPath": "/work"}}, "unknown volume"),
        ({"missing-name": {"mountPath": "/work"}}, "require name and mountPath"),
        ({"missing-path": {"name": "work"}}, "require name and mountPath"),
        (
            {
                "conflict": {
                    "name": "work",
                    "mountPath": "/work",
                    "subPath": "a",
                    "subPathExpr": "$(DIR)",
                }
            },
            "mutually exclusive",
        ),
    ],
)
def test_invalid_native_mounts(render, mounts, error):
    values = app(pod={"volumes": {"work": {"emptyDir": {}}}})
    values["components"]["main"]["container"]["volumeMounts"] = mounts
    render(values, error=error)


@pytest.mark.parametrize(
    "source, error",
    [
        ({}, "requires exactly one source"),
        (
            {"emptyDir": {}, "secret": {"secretName": "creds"}},
            "requires exactly one source",
        ),
        ({"type": "emptyDir", "mounts": {"/work": {}}}, "schema"),
        ({"name": "renamed", "emptyDir": {}}, "schema"),
    ],
)
def test_invalid_native_volumes(render, source, error):
    render(app(pod={"volumes": {"work": source}}), error=error)


def test_volume_source_switch_and_duplicate_final_names(render):
    values = app(pod={"volumes": {"work": {"emptyDir": {"medium": "Memory"}}}})
    overlay = {
        "components": {
            "main": {
                "pod": {
                    "volumes": {
                        "work": {
                            "emptyDir": None,
                            "persistentVolumeClaim": {"claimName": "existing"},
                        }
                    }
                }
            }
        }
    }
    assert pod(render(values, overlay))["volumes"] == [
        {"name": "work", "persistentVolumeClaim": {"claimName": "existing"}}
    ]
    values["components"]["main"]["pod"]["overrides"] = {
        "volumes": [{"name": "same", "emptyDir": {}}, {"name": "same", "emptyDir": {}}]
    }
    render(values, error="duplicate volume name")


def test_chart_level_pvc_exists_without_component_or_mount(render):
    values = {
        "appResources": {
            "pvc": {
                "archive": {
                    "metadata": {"annotations": {"helm.sh/resource-policy": "keep"}},
                    "spec": {
                        "accessModes": ["ReadWriteMany"],
                        "storageClassName": "nfs",
                        "resources": {"requests": {"storage": "10Gi"}},
                    },
                }
            }
        }
    }
    values["components"] = {"main": {"enabled": False}}
    docs = render(values)
    assert len(docs) == 1
    assert docs[0]["metadata"]["name"] == "test-check-archive"
    assert docs[0]["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep"


@pytest.mark.parametrize("enabled", [True, False, "{{ false }}", "{{ true }}"])
def test_conditional_auxiliary_containers_and_service_ports(render, enabled):
    active = enabled is True or enabled == "{{ true }}"
    values = app(
        sidecars={"proxy": {"enabled": enabled, "ports": {"proxy": {"port": 9000}}}},
        initContainers={
            "prepare": {"enabled": enabled},
            "native-sidecar": {
                "enabled": enabled,
                "restartPolicy": "Always",
                "ports": {"native": {"port": 9001}},
            },
        },
    )
    docs = render(values)
    result = pod(docs)
    assert [c["name"] for c in result["containers"]] == (
        ["main", "proxy"] if active else ["main"]
    )
    assert [c["name"] for c in result.get("initContainers", [])] == (
        ["native-sidecar", "prepare"] if active else []
    )
    ports = {p["port"] for p in one(docs, "Service")["spec"]["ports"]}
    assert ports == ({8080, 9000, 9001} if active else {8080})
    assert all(
        "enabled" not in c
        for c in result["containers"] + result.get("initContainers", [])
    )


def test_disabled_container_skips_templates_and_can_be_enabled_by_overlay(render):
    values = app(
        sidecars={
            "proxy": {
                "enabled": False,
                "command": ['{{ fail "disabled command evaluated" }}'],
            }
        }
    )
    assert len(pod(render(values))["containers"]) == 1
    render(
        values,
        {"components": {"main": {"sidecars": {"proxy": {"enabled": True}}}}},
        error="disabled command evaluated",
    )


def test_disabled_container_ports_cannot_be_selected_by_service(render):
    render(
        app(
            sidecars={"proxy": {"enabled": False, "ports": {"proxy": {"port": 9000}}}},
            services={"main": {"ports": {"proxy": {}}}},
        ),
        error="unknown container port",
    )


@pytest.mark.parametrize("enabled", [False, True])
def test_conditional_storage_preserves_native_shapes_and_skips_templates(
    render, enabled
):
    values = app(
        pod={
            "volumes": {
                "scratch": {
                    "enabled": "{{ .Values.components.main.container.env.ACTIVE }}",
                    "emptyDir": {},
                }
            }
        }
    )
    container = values["components"]["main"]["container"]
    container["env"] = {"ACTIVE": enabled}
    container["volumeMounts"] = {
        "scratch": {
            "enabled": "{{ .Values.components.main.container.env.ACTIVE }}",
            "name": "scratch",
            "mountPath": "/tmp",
        }
    }
    result = pod(render(values))
    assert result.get("volumes", []) == (
        [{"name": "scratch", "emptyDir": {}}] if enabled else []
    )
    assert result["containers"][0].get("volumeMounts", []) == (
        [{"name": "scratch", "mountPath": "/tmp"}] if enabled else []
    )
    values["components"]["main"]["pod"]["volumes"]["skipped"] = {
        "enabled": False,
        "configMap": {"name": '{{ fail "disabled volume evaluated" }}'},
    }
    container["volumeMounts"]["skipped"] = {
        "enabled": False,
        "name": "missing",
        "mountPath": '{{ fail "disabled mount evaluated" }}',
    }
    render(values)


@pytest.mark.parametrize(
    "location", ["sidecars", "initContainers", "volumes", "volumeMounts"]
)
def test_conditional_enabled_rejects_non_boolean_results(render, location):
    entry = {"enabled": '{{ "not-a-boolean" }}'}
    values = app()
    component = values["components"]["main"]
    if location == "volumes":
        component["pod"] = {"volumes": {"scratch": {**entry, "emptyDir": {}}}}
    elif location == "volumeMounts":
        component["container"]["volumeMounts"] = {
            "scratch": {**entry, "name": "scratch", "mountPath": "/tmp"}
        }
    else:
        component[location] = {"optional": entry}
    render(values, error="enabled must resolve to true or false")


@pytest.mark.parametrize("uid", [0, 1234])
def test_templated_security_ids_preserve_integer_types_and_inheritance(render, uid):
    values = app(
        containerDefaults={
            "securityContext": {
                "runAsUser": "{{ .Values.components.main.container.env.UID }}",
                "runAsGroup": "{{ .Values.components.main.container.env.GID }}",
                "allowPrivilegeEscalation": False,
            }
        },
        sidecars={"proxy": {}},
        initContainers={"prepare": {}},
    )
    values["components"]["main"]["container"]["env"] = {"UID": str(uid), "GID": "5678"}
    result = pod(render(values))
    for container in result["containers"] + result["initContainers"]:
        assert container["securityContext"] == {
            "runAsUser": uid,
            "runAsGroup": 5678,
            "allowPrivilegeEscalation": False,
        }
        assert type(container["securityContext"]["runAsUser"]) is int


@pytest.mark.parametrize("value", ["bad", "1.5", "-1", "9223372036854775808"])
def test_templated_security_ids_reject_invalid_integers(render, value):
    values = app()
    values["components"]["main"]["container"].update(
        {
            "env": {"UID": value},
            "securityContext": {
                "runAsUser": "{{ .Values.components.main.container.env.UID }}"
            },
        }
    )
    render(values, error="runAsUser must resolve to a non-negative integer")
