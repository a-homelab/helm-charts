import subprocess
from pathlib import Path

import pytest
import yaml

CHART = Path(__file__).resolve().parents[1]


def render(tmp_path, values=None, example="existing", success=True):
    overlay = tmp_path / "values.yaml"
    overlay.write_text(yaml.safe_dump(values or {}))
    result = subprocess.run(
        [
            "helm",
            "template",
            "test",
            str(CHART),
            "--namespace",
            "test",
            "-f",
            str(CHART / "examples" / f"{example}.yaml"),
            "-f",
            str(overlay),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if not success:
        assert result.returncode != 0, result.stdout
        return result.stderr
    assert result.returncode == 0, result.stderr
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


def one(resources, kind):
    matches = [doc for doc in resources if doc["kind"] == kind]
    assert len(matches) == 1
    return matches[0]


DEFAULT_ARCHIVE = {
    "destinationPath": "s3://example-postgres-backup/",
    "endpointURL": "http://rook-ceph-rgw-k8s-store-ssd.rook-ceph.svc",
    "s3Credentials": {
        "accessKeyId": {
            "name": "example-postgres-backup-bucket",
            "key": "AWS_ACCESS_KEY_ID",
        },
        "secretAccessKey": {
            "name": "example-postgres-backup-bucket",
            "key": "AWS_SECRET_ACCESS_KEY",
        },
    },
    "wal": {"compression": "gzip", "maxParallel": 8},
}


def test_existing_credentials_identity_bootstrap_tls_and_archive(tmp_path):
    resources = render(tmp_path)
    assert sorted(d["kind"] for d in resources) == [
        "Certificate",
        "Certificate",
        "Certificate",
        "Cluster",
        "Database",
        "ObjectBucketClaim",
        "ObjectStore",
        "PodMonitor",
        "ScheduledBackup",
    ]
    cluster = one(resources, "Cluster")
    assert cluster["metadata"]["name"] == "example-postgres"
    spec = cluster["spec"]
    assert spec["imageName"] == "ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie"
    assert spec["instances"] == 3
    assert spec["bootstrap"] == {
        "initdb": {
            "database": "app",
            "owner": "app",
            "secret": {"name": "example-app"},
            "localeCType": "C",
            "localeCollate": "C",
        }
    }
    assert spec["superuserSecret"] == {"name": "example-superuser"}
    assert spec["enableSuperuserAccess"] is False
    assert spec["primaryUpdateMethod"] == "switchover"
    assert spec["smartShutdownTimeout"] == 30
    assert spec["storage"] == {"storageClass": "rook-ceph-block-ssd", "size": "10Gi"}
    assert spec["certificates"] == {
        "serverTLSSecret": "example-postgres-server-tls",
        "serverCASecret": "example-postgres-server-tls",
        "clientCASecret": "example-postgres-client-replica-tls",
        "replicationTLSSecret": "example-postgres-client-replica-tls",
    }
    assert spec["backup"] == {"target": "prefer-standby"}
    assert spec["plugins"] == [
        {
            "name": "barman-cloud.cloudnative-pg.io",
            "isWALArchiver": True,
            "parameters": {"barmanObjectName": "example-postgres"},
        }
    ]
    store = one(resources, "ObjectStore")["spec"]
    assert store["configuration"] == DEFAULT_ARCHIVE
    assert store["retentionPolicy"] == "7d"
    assert one(resources, "ObjectBucketClaim")["spec"] == {
        "bucketName": "example-postgres-backup",
        "storageClassName": "rook-ceph-bucket-ssd",
    }
    assert spec["monitoring"] == {"enablePodMonitor": False}
    assert "managed" not in spec


def test_locale_sql_and_custom_image_survive(tmp_path):
    resources = render(
        tmp_path,
        {
            "image": {
                "repository": "bennycooly/cloudnative-pg-timescaledb",
                "tag": "15.4-debian-timescaledb-2.12.2",
            },
            "postgresql": {"shared_preload_libraries": ["timescaledb"]},
            "database": {"localeCType": "en_US.UTF-8", "localeCollate": "en_US.UTF-8"},
            "initdb": {
                "localeCType": "POSIX",
                "postInitApplicationSQL": [
                    "CREATE EXTENSION IF NOT EXISTS timescaledb;"
                ],
            },
        },
    )
    spec = one(resources, "Cluster")["spec"]
    assert spec["imageName"].endswith("15.4-debian-timescaledb-2.12.2")
    assert spec["postgresql"]["shared_preload_libraries"] == ["timescaledb"]
    assert spec["bootstrap"]["initdb"]["localeCType"] == "en_US.UTF-8"
    assert spec["bootstrap"]["initdb"]["localeCollate"] == "en_US.UTF-8"
    assert one(resources, "Database")["spec"]["localeCType"] == "en_US.UTF-8"
    assert spec["bootstrap"]["initdb"]["postInitApplicationSQL"] == [
        "CREATE EXTENSION IF NOT EXISTS timescaledb;"
    ]


def test_scheduled_plugin_backup_is_the_default(tmp_path):
    resources = render(tmp_path)
    schedule = one(resources, "ScheduledBackup")["spec"]
    assert schedule["method"] == "plugin"
    assert schedule["pluginConfiguration"] == {"name": "barman-cloud.cloudnative-pg.io"}
    assert schedule["immediate"] is True


def test_external_object_store_and_credentials_are_not_mixed_with_ceph(tmp_path):
    resources = render(
        tmp_path,
        {
            "backup": {
                "objectBucket": {"enabled": False},
                "configuration": {
                    "destinationPath": "s3://offsite/app",
                    "s3Credentials": {"inheritFromIAMRole": True},
                },
            }
        },
    )
    assert not any(d["kind"] == "ObjectBucketClaim" for d in resources)
    assert one(resources, "ObjectStore")["spec"]["configuration"] == {
        "destinationPath": "s3://offsite/app",
        "s3Credentials": {"inheritFromIAMRole": True},
    }
    resources = render(
        tmp_path,
        {"backup": {"objectStore": {"existingName": "offsite"}}},
    )
    assert not any(d["kind"] == "ObjectStore" for d in resources)
    assert (
        one(resources, "Cluster")["spec"]["plugins"][0]["parameters"][
            "barmanObjectName"
        ]
        == "offsite"
    )


def test_declarative_databases_have_independent_kubernetes_names_and_retain_data(
    tmp_path,
):
    resources = render(tmp_path, example="declarative")
    databases = {d["metadata"]["name"]: d for d in resources if d["kind"] == "Database"}
    assert set(databases) == {
        "example-postgres-db-app",
        "example-postgres-db-app-analytics",
    }
    assert (
        databases["example-postgres-db-app-analytics"]["spec"]["name"]
        == "app_analytics"
    )
    for db in databases.values():
        assert db["spec"]["databaseReclaimPolicy"] == "retain"
        assert db["spec"]["cluster"] == {"name": "example-postgres"}
        assert db["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"] == "-4"
    assert one(resources, "Cluster")["spec"]["managed"]["roles"][0][
        "passwordSecret"
    ] == {"name": "example-app"}


def test_role_crs_are_opt_in_and_retain_roles(tmp_path):
    resources = render(tmp_path, example="modern")
    roles = [d for d in resources if d["kind"] == "DatabaseRole"]
    assert len(roles) == 2
    assert {r["metadata"]["name"] for r in roles} == {
        "example-postgres-role-app",
        "example-postgres-role-reporting",
    }
    for role in roles:
        assert role["spec"]["databaseRoleReclaimPolicy"] == "retain"
        assert role["spec"]["cluster"] == {"name": "example-postgres"}
    assert "managed" not in one(resources, "Cluster")["spec"]
    assert (
        one(resources, "Cluster")["spec"]["bootstrap"]["initdb"]["dataChecksums"]
        is True
    )


def test_recovery_replaces_initdb_and_keeps_source_separate(tmp_path):
    resources = render(tmp_path, example="recovery")
    spec = one(resources, "Cluster")["spec"]
    assert "initdb" not in spec["bootstrap"]
    assert spec["bootstrap"]["recovery"]["source"] == "source"
    assert spec["externalClusters"][0]["plugin"]["parameters"] == {
        "barmanObjectName": "example-postgres",
        "serverName": "example-postgres",
    }
    assert spec["plugins"][0]["parameters"]["barmanObjectName"] == "example-restored"
    assert (
        one(resources, "ObjectStore")["spec"]["configuration"]["destinationPath"]
        == "s3://example-restored-backup/"
    )


def test_snapshot_schedule_keeps_wal_archiving(tmp_path):
    resources = render(tmp_path, example="snapshot")
    assert one(resources, "Cluster")["spec"]["plugins"][0]["isWALArchiver"] is True
    assert (
        one(resources, "Cluster")["spec"]["backup"]["volumeSnapshot"]["className"]
        == "database-snapshots"
    )
    assert one(resources, "ScheduledBackup")["spec"]["method"] == "volumeSnapshot"
    assert "pluginConfiguration" not in one(resources, "ScheduledBackup")["spec"]


def test_chart_owned_monitor_has_distinct_identity_and_stable_selector(tmp_path):
    resources = render(tmp_path)
    cluster = one(resources, "Cluster")
    monitor = one(resources, "PodMonitor")
    assert monitor["metadata"]["name"] != cluster["metadata"]["name"]
    assert cluster["spec"]["monitoring"]["enablePodMonitor"] is False
    assert monitor["spec"]["selector"]["matchLabels"] == {
        "cnpg.io/cluster": "example-postgres",
        "cnpg.io/podRole": "instance",
    }
    assert monitor["spec"]["podMetricsEndpoints"] == [{"port": "metrics"}]
    selector = cluster["spec"]["topologySpreadConstraints"][0]["labelSelector"]
    assert selector == {"matchLabels": {"cnpg.io/cluster": "example-postgres"}}
    resources = render(tmp_path, {"monitoring": {"podMonitor": {"enabled": False}}})
    assert not any(d["kind"] == "PodMonitor" for d in resources)
    assert one(resources, "Cluster")["spec"]["monitoring"] == {
        "enablePodMonitor": False
    }


@pytest.mark.parametrize(
    ("tls_mode", "extra", "ca_secret"),
    [
        ("certManager", {}, "example-postgres-server-tls"),
        ("operator", {}, "example-postgres-ca"),
        (
            "external",
            {"certificates": {"serverTLSSecret": "srv", "serverCASecret": "srv-ca"}},
            "srv-ca",
        ),
    ],
)
def test_metrics_tls_scrapes_https_with_the_server_ca(
    tmp_path, tls_mode, extra, ca_secret
):
    resources = render(
        tmp_path,
        {
            "tls": {"mode": tls_mode, **extra},
            "monitoring": {
                "configuration": {"tls": {"enabled": True}},
                "podMonitor": {
                    "podMetricsEndpoints": [{"port": "metrics", "interval": "30s"}]
                },
            },
        },
    )
    assert one(resources, "PodMonitor")["spec"]["podMetricsEndpoints"] == [
        {
            "port": "metrics",
            "interval": "30s",
            "scheme": "https",
            "tlsConfig": {
                "ca": {"secret": {"name": ca_secret, "key": "ca.crt"}},
                "serverName": "example-postgres-rw",
            },
        }
    ]


def test_replication_slots_merge_over_high_availability_default(tmp_path):
    spec = one(render(tmp_path), "Cluster")["spec"]
    assert spec["replicationSlots"] == {"highAvailability": {"enabled": True}}
    spec = one(
        render(
            tmp_path,
            {
                "replicationSlots": {
                    "highAvailability": {"synchronizeLogicalDecoding": True},
                    "synchronizeReplicas": {"enabled": False},
                }
            },
        ),
        "Cluster",
    )["spec"]
    assert spec["replicationSlots"] == {
        "highAvailability": {"enabled": True, "synchronizeLogicalDecoding": True},
        "synchronizeReplicas": {"enabled": False},
    }


def test_plugin_server_name_separates_archives(tmp_path):
    spec = one(
        render(
            tmp_path,
            {"backup": {"serverName": "example-postgres-pg18"}},
        ),
        "Cluster",
    )["spec"]
    assert spec["plugins"][0]["parameters"] == {
        "barmanObjectName": "example-postgres",
        "serverName": "example-postgres-pg18",
    }
    spec = one(render(tmp_path), "Cluster")["spec"]
    assert "serverName" not in spec["plugins"][0]["parameters"]


def test_server_alt_dns_names_reach_certificates(tmp_path):
    names = ["example-postgres-pooler-rw", "db.example.internal"]
    resources = render(tmp_path, {"tls": {"serverAltDNSNames": names}})
    server = next(
        d for d in resources if d["metadata"]["name"] == "example-postgres-server-tls"
    )
    assert server["spec"]["dnsNames"][-2:] == names
    spec = one(
        render(tmp_path, {"tls": {"mode": "operator", "serverAltDNSNames": names}}),
        "Cluster",
    )["spec"]
    assert spec["certificates"] == {"serverAltDNSNames": names}


def test_image_tag_is_required_without_a_catalog(tmp_path):
    assert "image.tag or imageCatalogRef is required" in render(
        tmp_path, {"image": {"tag": ""}}, success=False
    )
    spec = one(
        render(
            tmp_path,
            {
                "image": {"tag": ""},
                "imageCatalogRef": {
                    "apiGroup": "postgresql.cnpg.io",
                    "kind": "ClusterImageCatalog",
                    "name": "postgresql",
                    "major": 18,
                },
            },
        ),
        "Cluster",
    )["spec"]
    assert "imageName" not in spec


def test_cert_manager_poolers_use_chart_issued_auth_certificate(tmp_path):
    resources = render(
        tmp_path,
        {
            "poolers": {
                "rw": {"instances": 2, "pgbouncer": {"poolMode": "transaction"}},
                "ro": {"type": "ro"},
            }
        },
    )
    poolers = {d["metadata"]["name"]: d for d in resources if d["kind"] == "Pooler"}
    assert sorted(poolers) == [
        "example-postgres-pooler-ro",
        "example-postgres-pooler-rw",
    ]
    rw = poolers["example-postgres-pooler-rw"]["spec"]
    assert rw["cluster"] == {"name": "example-postgres"}
    assert rw["pgbouncer"] == {
        "poolMode": "transaction",
        "authQuerySecret": {"name": "example-postgres-pooler-auth-tls"},
        "authQuery": "SELECT usename, passwd FROM public.user_search($1)",
    }
    assert rw["template"] == {
        "metadata": {"annotations": {"sidecar.istio.io/inject": "false"}}
    }
    certs = {d["metadata"]["name"]: d for d in resources if d["kind"] == "Certificate"}
    auth = certs["example-postgres-pooler-auth-tls"]["spec"]
    assert auth["commonName"] == "cnpg_pooler_pgbouncer"
    assert auth["usages"][-1] == "client auth"
    sans = certs["example-postgres-server-tls"]["spec"]["dnsNames"]
    assert "example-postgres-pooler-ro.test.svc" in sans
    assert "example-postgres-pooler-rw.test.svc.cluster.local" in sans


def test_explicit_pooler_auth_and_template_are_preserved(tmp_path):
    resources = render(
        tmp_path,
        {
            "poolers": {
                "rw": {
                    "pgbouncer": {"authQuerySecret": {"name": "custom"}},
                    "template": {
                        "metadata": {"annotations": {"sidecar.istio.io/inject": "true"}}
                    },
                }
            }
        },
    )
    spec = one(resources, "Pooler")["spec"]
    assert spec["pgbouncer"] == {"authQuerySecret": {"name": "custom"}}
    assert spec["template"]["metadata"]["annotations"] == {
        "sidecar.istio.io/inject": "true"
    }
    assert "example-postgres-pooler-auth-tls" not in [
        d["metadata"]["name"] for d in resources if d["kind"] == "Certificate"
    ]


def test_operator_tls_poolers_keep_cnpg_integration_and_add_sans(tmp_path):
    resources = render(
        tmp_path,
        {
            "tls": {"mode": "operator", "serverAltDNSNames": ["db.example.internal"]},
            "poolers": {"rw": {"pgbouncer": {}}},
        },
    )
    assert one(resources, "Pooler")["spec"]["pgbouncer"] == {}
    assert one(resources, "Cluster")["spec"]["certificates"] == {
        "serverAltDNSNames": [
            "example-postgres-pooler-rw",
            "example-postgres-pooler-rw.test",
            "example-postgres-pooler-rw.test.svc",
            "example-postgres-pooler-rw.test.svc.cluster.local",
            "db.example.internal",
        ]
    }
    monitors = {
        d["metadata"]["name"]: d["spec"]["selector"]["matchLabels"]
        for d in resources
        if d["kind"] == "PodMonitor"
    }
    assert monitors["example-postgres-pooler-metrics"] == {
        "cnpg.io/cluster": "example-postgres",
        "cnpg.io/podRole": "pooler",
    }


@pytest.mark.parametrize(
    ("values", "message"),
    [
        (
            {"poolers": {"rw": {"cluster": {"name": "other"}, "pgbouncer": {}}}},
            "cluster",
        ),
    ],
)
def test_invalid_poolers_fail_before_apply(tmp_path, values, message):
    assert message in render(tmp_path, values, success=False)


@pytest.mark.parametrize(
    ("example", "values", "immutable"),
    [
        ("generated", {}, True),
        ("generated", {"credentials": {"rotation": {"enabled": True}}}, False),
        ("recovery", {}, True),
    ],
)
def test_credential_secrets_are_immutable_unless_rotating(
    tmp_path, example, values, immutable
):
    secrets = [
        d
        for d in render(tmp_path, values, example=example)
        if d["kind"] == "ExternalSecret"
    ]
    assert secrets
    assert all(d["spec"]["target"]["immutable"] is immutable for d in secrets)


def test_cnpg_ca_is_the_default_issuer_for_new_values(tmp_path):
    certs = [
        d for d in render(tmp_path, example="snapshot") if d["kind"] == "Certificate"
    ]
    assert certs
    assert all(
        d["spec"]["issuerRef"] == {"name": "cnpg-ca", "kind": "ClusterIssuer"}
        for d in certs
    )
    server = next(d for d in certs if d["metadata"]["name"].endswith("-server-tls"))
    assert any(
        name.endswith(".svc.cluster.local") for name in server["spec"]["dnsNames"]
    )


def test_cnpg_specs_omit_empty_lists_the_operator_would_drop(tmp_path):
    resources = render(
        tmp_path,
        {
            "databaseRoles": {"r": {"name": "reporting", "inRoles": []}},
            "poolers": {"rw": {"pgbouncer": {}}},
        },
    )
    database = one(resources, "Database")["spec"]
    assert "extensions" not in database and "schemas" not in database
    assert "inRoles" not in one(resources, "DatabaseRole")["spec"]
    # pgbouncer is required by the Pooler CRD even when empty.
    assert "pgbouncer" in one(resources, "Pooler")["spec"]


def test_default_waves_order_cluster_before_dependent_crs(tmp_path):
    resources = render(tmp_path, {"poolers": {"rw": {"pgbouncer": {}}}})
    for doc in resources:
        wave = doc["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"]
        if doc["kind"] in {"Database", "DatabaseRole", "Pooler", "ScheduledBackup"}:
            assert wave == "-4", doc["metadata"]["name"]
        else:
            assert wave == "-5", doc["metadata"]["name"]


def test_native_cluster_fields_and_image_catalog(tmp_path):
    resources = render(
        tmp_path,
        {
            "imageCatalogRef": {
                "apiGroup": "postgresql.cnpg.io",
                "kind": "ClusterImageCatalog",
                "name": "postgres",
                "major": 18,
            },
            "extraClusterSpec": {
                "walStorage": {"size": "5Gi"},
                "priorityClassName": "database",
            },
            "storage": {"size": "30Gi"},
            "storageNodesOnly": False,
            "spreadAcrossNodes": False,
        },
    )
    spec = one(resources, "Cluster")["spec"]
    assert "imageName" not in spec
    assert spec["imageCatalogRef"]["major"] == 18
    assert spec["walStorage"] == {"size": "5Gi"}
    assert spec["priorityClassName"] == "database"
    assert spec["storage"]["size"] == "30Gi"
    assert "affinity" not in spec
    assert "topologySpreadConstraints" not in spec


def test_affinity_merges_over_storage_nodes_and_extra_spread_follows_default(
    tmp_path,
):
    storage_nodes = {
        "requiredDuringSchedulingIgnoredDuringExecution": {
            "nodeSelectorTerms": [
                {
                    "matchExpressions": [
                        {
                            "key": "node-role.benfu.me/storage",
                            "operator": "In",
                            "values": ["true"],
                        }
                    ]
                }
            ]
        }
    }
    default_spread = {
        "maxSkew": 1,
        "topologyKey": "kubernetes.io/hostname",
        "whenUnsatisfiable": "DoNotSchedule",
        "labelSelector": {"matchLabels": {"cnpg.io/cluster": "example-postgres"}},
    }
    spec = one(render(tmp_path), "Cluster")["spec"]
    assert spec["affinity"] == {"nodeAffinity": storage_nodes}
    assert spec["topologySpreadConstraints"] == [default_spread]
    zone = {
        "maxSkew": 2,
        "topologyKey": "topology.kubernetes.io/zone",
        "whenUnsatisfiable": "ScheduleAnyway",
    }
    spec = one(
        render(
            tmp_path,
            {
                "affinity": {"enablePodAntiAffinity": True},
                "topologySpreadConstraints": [zone],
            },
        ),
        "Cluster",
    )["spec"]
    assert spec["affinity"] == {
        "enablePodAntiAffinity": True,
        "nodeAffinity": storage_nodes,
    }
    assert spec["topologySpreadConstraints"] == [default_spread, zone]


@pytest.mark.parametrize("mode", ["operator", "external"])
def test_tls_modes_do_not_render_cert_manager_resources(tmp_path, mode):
    certs = {"serverTLSSecret": "server", "serverCASecret": "ca"}
    resources = render(
        tmp_path,
        {"tls": {"mode": mode, "certificates": certs if mode == "external" else {}}},
    )
    assert not any(d["kind"] == "Certificate" for d in resources)
    spec = one(resources, "Cluster")["spec"]
    if mode == "external":
        assert spec["certificates"] == certs
    else:
        assert "certificates" not in spec


def test_false_values_and_zero_wave_are_preserved(tmp_path):
    resources = render(
        tmp_path,
        {
            "syncWave": 0,
            "databaseSyncWave": 0,
            "backup": {"scheduled": {"immediate": False, "suspend": True}},
            "initdb": {"dataChecksums": False},
        },
    )
    assert (
        one(resources, "Database")["metadata"]["annotations"][
            "argocd.argoproj.io/sync-wave"
        ]
        == "0"
    )
    assert (
        one(resources, "Cluster")["spec"]["bootstrap"]["initdb"]["dataChecksums"]
        is False
    )
    assert one(resources, "ScheduledBackup")["spec"]["immediate"] is False
    assert one(resources, "ScheduledBackup")["spec"]["suspend"] is True


@pytest.mark.parametrize(
    "values,message",
    [
        ({"instances": 0}, "instances"),
        ({"backpu": {}}, "backpu"),
        ({"backup": {"enabled": "plugin"}}, "backup.enabled"),
        ({"backup": {"provider": "plugin"}}, "provider"),
        ({"monitoring": {"mode": "podMonitor"}}, "mode"),
        ({"nameOverride": "other"}, "nameOverride"),
        (
            {"backup": {"scheduled": {"enabled": True, "schedule": "0 10 * * *"}}},
            "schedule",
        ),
        (
            {"backup": {"enabled": False}},
            "backup.scheduled.method plugin requires backup.enabled",
        ),
        (
            {"backup": {"scheduled": {"enabled": True, "method": "volumeSnapshot"}}},
            "requires backup.volumeSnapshot",
        ),
        (
            {"backup": {"objectBucket": {"enabled": False}}},
            "backup.configuration is required",
        ),
        (
            {
                "backup": {
                    "configuration": {
                        "destinationPath": "s3://test/",
                        "serverName": "other",
                    },
                }
            },
            "serverName must be empty",
        ),
        (
            {"extraClusterSpec": {"imageName": "other"}},
            "extraClusterSpec.imageName conflicts with a chart-owned field",
        ),
        (
            {"extraClusterSpec": {"smartShutdownTimeout": 180}},
            "extraClusterSpec.smartShutdownTimeout conflicts with a chart-owned field",
        ),
        ({"clusterSpec": {"walStorage": {"size": "5Gi"}}}, "clusterSpec"),
        ({"database": {"enabled": True}}, "database.enabled"),
        (
            {"databases": {"app": {"name": "other", "owner": "app"}}},
            "databases.app is reserved",
        ),
        (
            {
                "databases": {
                    "a": {"name": "same", "owner": "app"},
                    "b": {"name": "same", "owner": "app"},
                }
            },
            "duplicate database name",
        ),
        (
            {"databaseRoles": {"app": {"name": "app"}, "other": {"name": "app"}}},
            "duplicate DatabaseRole name",
        ),
        ({"databaseRoles": {"app": {"name": "app", "ensure": "absent"}}}, "ensure"),
        (
            {
                "databaseRoles": {
                    "app": {"name": "app", "clientCertificate": {"enabled": True}}
                }
            },
            "requires tls.mode=operator",
        ),
        (
            {
                "enableSuperuserAccess": True,
                "credentials": {"existing": {"superuserSecretName": ""}},
            },
            "credentials.existing.superuserSecretName is required",
        ),
        (
            {
                "bootstrap": {
                    "recovery": {"source": "a"},
                    "pg_basebackup": {"source": "a"},
                }
            },
            "bootstrap",
        ),
        ({"tls": {"mode": "external"}}, "tls.certificates is required"),
        (
            {"monitoring": {"configuration": {"enablePodMonitor": True}}},
            (
                "use monitoring.podMonitor.enabled instead of "
                "monitoring.configuration.enablePodMonitor"
            ),
        ),
        (
            {
                "backup": {
                    "enabled": False,
                    "scheduled": {"enabled": False},
                    "serverName": "pg18",
                }
            },
            "backup.serverName requires backup.enabled",
        ),
        (
            {
                "tls": {
                    "mode": "external",
                    "certificates": {"serverTLSSecret": "s"},
                    "serverAltDNSNames": ["x"],
                }
            },
            "tls.serverAltDNSNames is unused",
        ),
    ],
)
def test_invalid_configuration_fails_before_apply(tmp_path, values, message):
    assert message in render(tmp_path, values, success=False)


def test_database_roles_replace_inline_roles_of_the_same_name(tmp_path):
    resources = render(
        tmp_path,
        {
            "database": {"name": "newdb", "owner": "newowner"},
            "databaseRoles": {"app": {"name": "app", "login": False}},
            "managed": {
                "roles": [
                    {"name": "app", "login": True},
                    {"name": "other", "login": False},
                ]
            },
        },
    )
    spec = one(resources, "Cluster")["spec"]
    assert spec["bootstrap"]["initdb"]["database"] == "newdb"
    assert spec["bootstrap"]["initdb"]["owner"] == "newowner"
    assert spec["managed"]["roles"] == [{"name": "other", "login": False}]
    assert one(resources, "DatabaseRole")["spec"]["login"] is False
    assert one(resources, "Database")["spec"]["name"] == "newdb"


def test_spread_selector_and_pods_omit_the_chart_version(tmp_path):
    cluster = one(render(tmp_path), "Cluster")
    version = yaml.safe_load((CHART / "Chart.yaml").read_text())["version"]
    assert cluster["metadata"]["labels"]["helm.sh/chart"] == f"postgresql-{version}"
    assert "helm.sh/chart" not in cluster["spec"]["inheritedMetadata"]["labels"]
    assert cluster["spec"]["topologySpreadConstraints"][0]["labelSelector"] == {
        "matchLabels": {"cnpg.io/cluster": "example-postgres"}
    }


def test_disabled_role_certificate_does_not_require_operator_ca(tmp_path):
    resources = render(
        tmp_path,
        {
            "databaseRoles": {
                "app": {"name": "app", "clientCertificate": {"enabled": False}}
            }
        },
    )
    assert (
        one(resources, "DatabaseRole")["spec"]["clientCertificate"]["enabled"] is False
    )


def test_digest_keeps_version_tag_for_cnpg_major_detection(tmp_path):
    digest = "sha256:" + "a" * 64
    resources = render(
        tmp_path, {"image": {"tag": "18.6-standard-trixie", "digest": digest}}
    )
    assert one(resources, "Cluster")["spec"]["imageName"] == (
        "ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie@" + digest
    )
    assert "image.tag is required" in render(
        tmp_path, {"image": {"tag": "", "digest": digest}}, success=False
    )


def test_generated_credentials_create_named_secrets_and_disable_scheduled_rotation(
    tmp_path,
):
    resources = render(tmp_path, {"credentials": {"mode": "generated"}})
    spec = one(resources, "Cluster")["spec"]
    assert spec["bootstrap"]["initdb"]["secret"] == {
        "name": "example-postgres-app"
    }
    assert "superuserSecret" not in spec
    secret = one(resources, "ExternalSecret")["spec"]
    assert secret["target"]["name"] == "example-postgres-app"
    assert secret["target"]["creationPolicy"] == "Orphan"
    assert secret["target"]["template"]["data"]["username"] == "app"
    assert secret["refreshPolicy"] == "CreatedOnce"
    assert secret["refreshInterval"] == "0s"
    assert secret["target"]["immutable"] is True
    assert secret["target"]["template"]["metadata"]["labels"] == {
        "cnpg.io/reload": "true"
    }
    assert set(secret["target"]["template"]["data"]) == {
        "username",
        "user",
        "host",
        "port",
        "dbname",
        "password",
        "pgpass",
        "uri",
        "jdbc-uri",
        "fqdn-uri",
        "fqdn-jdbc-uri",
    }
    assert one(resources, "Password")["spec"]["length"] == 42
    assert not any(
        d["kind"] in {"Secret", "SecretStore", "PushSecret"} for d in resources
    )
    assert resources == render(tmp_path, {"credentials": {"mode": "generated"}})


@pytest.mark.parametrize(
    "example,mode", [("existing", "generated"), ("recovery", "copy")]
)
@pytest.mark.parametrize("admin", [False, True])
def test_eso_targets_are_cluster_derived_credentials(tmp_path, example, mode, admin):
    resources = render(
        tmp_path,
        {
            "enableSuperuserAccess": admin,
            "credentials": {
                "mode": mode,
                "copy": {"superuserSecretName": "source-admin"},
            },
        },
        example=example,
    )
    prefix = "example-postgres" if mode == "generated" else "example-restored-recovery"
    user_secret = f"{prefix}-app"
    admin_secret = f"{prefix}-superuser"
    cluster = one(resources, "Cluster")["spec"]
    bootstrap = cluster["bootstrap"]["initdb" if mode == "generated" else "recovery"]
    assert bootstrap["secret"] == {"name": user_secret}
    secrets = [d for d in resources if d["kind"] == "ExternalSecret"]
    expected = {user_secret}
    if admin:
        expected.add(admin_secret)
        assert cluster["superuserSecret"] == {"name": admin_secret}
    else:
        assert "superuserSecret" not in cluster
    assert {d["spec"]["target"]["name"] for d in secrets} == expected
    for secret in secrets:
        assert secret["spec"]["target"]["creationPolicy"] == "Orphan"
        fields = secret["spec"]["target"]["template"]["data"]
        assert fields["username"] == (
            "postgres" if secret["metadata"]["name"] == admin_secret else "app"
        )
        assert "password" in fields


@pytest.mark.parametrize("method", ["initdb", "recovery", "pg_basebackup"])
def test_native_bootstrap_cannot_request_cnpg_generated_credentials(tmp_path, method):
    settings = {"database": "app", "owner": "app"}
    if method != "initdb":
        settings["source"] = "source"
    assert "CNPG-generated credential Secrets are disabled" in render(
        tmp_path,
        {"bootstrap": {method: settings}},
        success=False,
    )
    settings["secret"] = {"name": "explicit-credentials"}
    resources = render(tmp_path, {"bootstrap": {method: settings}})
    assert one(resources, "Cluster")["spec"]["bootstrap"][method]["secret"] == {
        "name": "explicit-credentials"
    }


def test_sql_names_control_resource_names_without_changing_sql_identity(tmp_path):
    resources = render(
        tmp_path,
        {
            "database": {
                "name": "Codecov_DB",
                "owner": "Codecov_User",
            },
            "databaseRoles": {"reader": {"name": "Codecov_Reader", "login": False}},
            "credentials": {"mode": "generated"},
            "enableSuperuserAccess": True,
        },
    )
    db = one(resources, "Database")
    assert db["metadata"]["name"] == "example-postgres-db-codecov-db"
    assert db["spec"]["name"] == "Codecov_DB"
    assert db["spec"]["owner"] == "Codecov_User"
    role = one(resources, "DatabaseRole")
    assert role["metadata"]["name"] == "example-postgres-role-codecov-reader"
    assert role["spec"]["name"] == "Codecov_Reader"
    cluster = one(resources, "Cluster")["spec"]
    assert cluster["bootstrap"]["initdb"]["secret"] == {
        "name": "example-postgres-codecov-user"
    }
    assert cluster["superuserSecret"] == {"name": "example-postgres-superuser"}
    generators = {d["metadata"]["name"] for d in resources if d["kind"] == "Password"}
    assert generators == {
        "example-postgres-codecov-user",
        "example-postgres-superuser",
    }
    for secret in (d for d in resources if d["kind"] == "ExternalSecret"):
        assert secret["spec"]["target"]["name"] == secret["metadata"]["name"]
        assert secret["spec"]["target"]["creationPolicy"] == "Orphan"
        fields = secret["spec"]["target"]["template"]["data"]
        assert fields["username"] == (
            "postgres"
            if secret["metadata"]["name"].endswith("-superuser")
            else "Codecov_User"
        )
        assert (
            secret["spec"]["dataFrom"][0]["sourceRef"]["generatorRef"]["name"]
            == secret["metadata"]["name"]
        )


def test_database_and_role_map_key_renames_do_not_rename_resources(tmp_path):
    a = {
        "databases": {"first": {"name": "reporting_db", "owner": "app"}},
        "databaseRoles": {"first": {"name": "reporting_user", "login": False}},
    }
    b = {
        "databases": {"second": a["databases"]["first"]},
        "databaseRoles": {"second": a["databaseRoles"]["first"]},
    }
    assert render(tmp_path, a) == render(tmp_path, b)


@pytest.mark.parametrize(
    "values, message",
    [
        (
            {
                "databases": {
                    "one": {"name": "sql_name", "owner": "app"},
                    "two": {"name": "sql-name", "owner": "app"},
                }
            },
            "duplicate Database resource name",
        ),
        (
            {
                "databaseRoles": {
                    "one": {"name": "sql_name"},
                    "two": {"name": "sql-name"},
                }
            },
            "duplicate DatabaseRole resource name",
        ),
        (
            {"database": {"name": "x" * 63}},
            "must be a DNS label of at most 63 characters",
        ),
        (
            {"database": {"name": "_"}},
            'SQL name "_" cannot form a Kubernetes resource name',
        ),
        ({"fullnameOverride": "Bad_Name"}, "must be a DNS label"),
    ],
)
def test_ambiguous_or_invalid_resource_names_fail_before_apply(
    tmp_path, values, message
):
    assert message in render(tmp_path, values, success=False)


def test_copied_owner_named_superuser_collides_with_the_superuser_secret(tmp_path):
    message = render(
        tmp_path,
        {
            "enableSuperuserAccess": True,
            "database": {"owner": "superuser"},
            "bootstrap": {"recovery": {"owner": "superuser"}},
            "credentials": {"copy": {"superuserSecretName": "source-admin"}},
        },
        example="recovery",
        success=False,
    )
    assert (
        "database.owner superuser collides with the superuser credential Secret"
        in message
    )


def test_rotation_and_superuser_are_explicit_with_independent_password_generators(
    tmp_path,
):
    resources = render(
        tmp_path,
        {
            "enableSuperuserAccess": True,
            "credentials": {
                "mode": "generated",
                "rotation": {"enabled": True, "interval": "48h"},
            },
        },
    )
    secrets = [d for d in resources if d["kind"] == "ExternalSecret"]
    assert len(secrets) == 2
    generators = {d["metadata"]["name"] for d in resources if d["kind"] == "Password"}
    assert generators == {
        "example-postgres-app",
        "example-postgres-superuser",
    }
    admin = next(
        d for d in secrets if d["spec"]["target"]["name"].endswith("-superuser")
    )
    fields = admin["spec"]["target"]["template"]["data"]
    assert fields["dbname"] == "postgres"
    assert ":5432:*:postgres:" in fields["pgpass"]
    for secret in secrets:
        assert secret["spec"]["refreshPolicy"] == "Periodic"
        assert secret["spec"]["refreshInterval"] == "48h"
        assert secret["spec"]["target"]["immutable"] is False
        assert (
            secret["spec"]["dataFrom"][0]["sourceRef"]["generatorRef"]["name"]
            == secret["metadata"]["name"]
        )


def test_recovery_copy_restricts_reads_and_retains_secrets_after_removal(tmp_path):
    resources = render(
        tmp_path,
        {
            "enableSuperuserAccess": True,
            "credentials": {"copy": {"superuserSecretName": "source-superuser"}},
        },
        example="recovery",
    )
    cluster = one(resources, "Cluster")["spec"]
    assert cluster["bootstrap"]["recovery"]["secret"] == {
        "name": "example-restored-recovery-app"
    }
    assert cluster["superuserSecret"] == {
        "name": "example-restored-recovery-superuser"
    }
    assert one(resources, "Role")["rules"] == [
        {
            "apiGroups": [""],
            "resources": ["secrets"],
            "resourceNames": ["example-postgres-app", "source-superuser"],
            "verbs": ["get"],
        }
    ]
    assert one(resources, "ServiceAccount")["automountServiceAccountToken"] is False
    provider = one(resources, "SecretStore")["spec"]["provider"]["kubernetes"]
    assert provider["remoteNamespace"] == "test"
    assert (
        provider["auth"]["serviceAccount"]["name"] == "example-restored-recovery-reader"
    )
    for secret in (d for d in resources if d["kind"] == "ExternalSecret"):
        assert secret["spec"]["target"]["creationPolicy"] == "Orphan"
        assert secret["spec"]["refreshPolicy"] == "CreatedOnce"
        assert secret["spec"]["refreshInterval"] == "0s"
        assert secret["spec"]["target"]["immutable"] is True
        fields = secret["spec"]["target"]["template"]["data"]
        assert "source credential username" in fields["password"]
        assert "example-restored-rw.test" in fields["uri"]
    assert not any(d["kind"] == "Password" for d in resources)


def test_cnpg_ca_issuer_superuser_certificate_and_issuer_override(tmp_path):
    modern = render(tmp_path, {"tls": {"superuserCertificate": True}})
    certs = [d for d in modern if d["kind"] == "Certificate"]
    assert len(certs) == 4
    assert all(d["spec"]["issuerRef"]["name"] == "cnpg-ca" for d in certs)
    admin = next(
        d for d in certs if d["metadata"]["name"].endswith("-client-superuser-tls")
    )
    assert admin["spec"]["commonName"] == "postgres"
    assert "client auth" in admin["spec"]["usages"]
    assert one(modern, "Cluster")["spec"]["enableSuperuserAccess"] is False
    assert "postgresql" not in one(modern, "Cluster")["spec"]
    override = render(
        tmp_path,
        {"tls": {"issuerRef": {"name": "custom", "kind": "Issuer"}}},
    )
    assert all(
        d["spec"]["issuerRef"] == {"name": "custom", "kind": "Issuer"}
        for d in override
        if d["kind"] == "Certificate"
    )


@pytest.mark.parametrize(
    "values,message",
    [
        (
            {"credentials": {"rotation": {"enabled": True}}},
            "requires credentials.mode=generated",
        ),
        ({"credentials": {"mode": "copy"}}, "requires bootstrap.recovery"),
        (
            {
                "credentials": {"mode": "generated"},
                "bootstrap": {"initdb": {"database": "other"}},
            },
            "requires the chart initdb settings",
        ),
        (
            {"tls": {"mode": "operator", "superuserCertificate": True}},
            "requires tls.mode=certManager",
        ),
        ({"credentials": {"rotation": {"interval": "0s"}}}, "interval"),
    ],
)
def test_unsafe_credential_and_certificate_combinations_fail(tmp_path, values, message):
    assert message in render(tmp_path, values, success=False)


def test_copy_refuses_self_copy_and_mismatched_database_identity(tmp_path):
    assert "differ from its destination" in render(
        tmp_path,
        {
            "credentials": {
                "copy": {"userSecretName": "example-restored-recovery-app"}
            },
        },
        example="recovery",
        success=False,
    )
    assert "must match" in render(
        tmp_path,
        {
            "bootstrap": {"recovery": {"owner": "different"}},
        },
        example="recovery",
        success=False,
    )


def evaluate_secret_template(tmp_path, template, inputs, success=True):
    chart = tmp_path / "eso-template-check"
    (chart / "templates").mkdir(parents=True, exist_ok=True)
    (chart / "Chart.yaml").write_text(
        "apiVersion: v2\nname: template-check\nversion: 0.1.0\n"
    )
    (chart / "values.yaml").write_text(
        yaml.safe_dump({"fields": template, "inputs": inputs})
    )
    (chart / "templates/secret.yaml").write_text(
        "apiVersion: v1\nkind: Secret\nstringData:\n"
        "{{- range $key, $value := .Values.fields }}\n"
        '  {{ $key }}: {{ tpl $value (merge (dict "Template" $.Template) $.Values.inputs) | quote }}\n'
        "{{- end }}\n"
    )
    result = subprocess.run(
        ["helm", "template", str(chart)], capture_output=True, text=True, check=False
    )
    if not success:
        assert result.returncode != 0
        return result.stderr
    assert result.returncode == 0, result.stderr
    return yaml.safe_load(result.stdout)["stringData"]


def test_password_connection_templates_escape_every_password_field(tmp_path):
    from urllib.parse import parse_qs, unquote, urlsplit

    resources = render(
        tmp_path,
        {"credentials": {"mode": "generated"}, "clusterDomain": "internal.example"},
    )
    fields = one(resources, "ExternalSecret")["spec"]["target"]["template"]["data"]
    password = 'p@ss:/\\word? &=+$#%"'
    rendered = evaluate_secret_template(tmp_path, fields, {"password": password})
    assert rendered["password"] == password
    for key in ["uri", "fqdn-uri"]:
        parsed = urlsplit(rendered[key])
        assert unquote(parsed.password) == password
        assert parsed.username == "app"
        assert parsed.path == "/app"
        assert parsed.hostname == (
            "example-postgres-rw.test"
            if key == "uri"
            else "example-postgres-rw.test.svc.internal.example"
        )
    for key in ["jdbc-uri", "fqdn-jdbc-uri"]:
        query = parse_qs(urlsplit(rendered[key].removeprefix("jdbc:")).query)
        assert query == {"user": ["app"], "password": [password]}
    escaped = password.replace("\\", "\\\\").replace(":", "\\:")
    assert rendered["pgpass"] == f"example-postgres-rw:5432:app:app:{escaped}\n"


def test_copy_template_rejects_wrong_username_instead_of_relabeling_password(tmp_path):
    resources = render(tmp_path, example="recovery")
    fields = one(resources, "ExternalSecret")["spec"]["target"]["template"]["data"]
    assert "source credential username" in evaluate_secret_template(
        tmp_path,
        fields,
        {"username": "wrong", "password": "not-a-real-password"},
        success=False,
    )
    rendered = evaluate_secret_template(
        tmp_path, fields, {"username": "app", "password": "not-a-real-password"}
    )
    assert rendered["username"] == "app"
    assert rendered["host"] == "example-restored-rw"


def test_explicit_settings_reach_cluster_database_and_bucket(tmp_path):
    resources = render(
        tmp_path,
        {
            "instances": 1,
            "postgresql": {"parameters": {"max_connections": "200"}},
            "credentials": {
                "existing": {
                    "userSecretName": "new-app",
                    "superuserSecretName": "new-admin",
                }
            },
            "database": {
                "localeCType": "en_US.UTF-8",
                "localeCollate": "en_US.UTF-8",
            },
            "backup": {"objectBucket": {"storageClassName": "new-bucket-class"}},
        },
    )
    spec = one(resources, "Cluster")["spec"]
    assert spec["instances"] == 1
    assert spec["postgresql"] == {"parameters": {"max_connections": "200"}}
    assert spec["bootstrap"]["initdb"]["secret"]["name"] == "new-app"
    assert spec["superuserSecret"]["name"] == "new-admin"
    assert (
        one(resources, "ObjectBucketClaim")["spec"]["storageClassName"]
        == "new-bucket-class"
    )
    for key in ["localeCType", "localeCollate"]:
        assert spec["bootstrap"]["initdb"][key] == "en_US.UTF-8"
        assert one(resources, "Database")["spec"][key] == "en_US.UTF-8"


def test_empty_superuser_reference_renders_no_superuser_secret(tmp_path):
    resources = render(
        tmp_path, {"credentials": {"existing": {"superuserSecretName": ""}}}
    )
    spec = one(resources, "Cluster")["spec"]
    assert "postgresql" not in spec
    assert "superuserSecret" not in spec


def test_native_bootstrap_and_generated_credentials_keep_their_precedence(tmp_path):
    resources = render(
        tmp_path,
        {
            "bootstrap": {
                "initdb": {
                    "database": "app",
                    "owner": "app",
                    "localeCType": "POSIX",
                    "secret": {"name": "native-secret"},
                }
            },
            "database": {"localeCType": "en_US.UTF-8"},
            "credentials": {"existing": {"userSecretName": "nested-app"}},
        },
    )
    initdb = one(resources, "Cluster")["spec"]["bootstrap"]["initdb"]
    assert initdb["localeCType"] == "POSIX"
    assert initdb["secret"]["name"] == "native-secret"
    resources = render(
        tmp_path,
        {
            "credentials": {
                "mode": "generated",
                "existing": {
                    "userSecretName": "nested-app",
                    "superuserSecretName": "nested-admin",
                },
            },
        },
    )
    spec = one(resources, "Cluster")["spec"]
    assert spec["bootstrap"]["initdb"]["secret"] == {
        "name": "example-postgres-app"
    }
    assert "superuserSecret" not in spec


@pytest.mark.parametrize(
    "values,message",
    [
        ({"instances": 0}, "instances"),
        ({"credentials": {"existing": {"userSecretName": ""}}}, "userSecretName"),
        ({"database": {"localeCType": None}}, "localeCType"),
        ({"backup": {"objectBucket": {"storageClassName": ""}}}, "storageClassName"),
    ],
)
def test_invalid_canonical_values_fail_schema_validation(tmp_path, values, message):
    assert message in render(tmp_path, values, success=False)


@pytest.mark.parametrize("owner", ["ca", "server", "replication", "superuser", "backup-bucket"])
def test_generated_credentials_reject_a_role_named_like_a_cluster_secret(tmp_path, owner):
    message = render(
        tmp_path,
        {"credentials": {"mode": "generated"}, "database": {"owner": owner}},
        success=False,
    )
    assert f'credential Secret "example-postgres-{owner}" would collide' in message
