import subprocess
from pathlib import Path

import pytest
import yaml

CHART = Path(__file__).resolve().parents[1]


def render(tmp_path, values=None, example="legacy", success=True):
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


def test_legacy_preserves_identity_bootstrap_tls_and_archive(tmp_path):
    resources = render(tmp_path)
    assert sorted(d["kind"] for d in resources) == [
        "Certificate",
        "Certificate",
        "Certificate",
        "Cluster",
        "ObjectBucketClaim",
    ]
    cluster = one(resources, "Cluster")
    assert cluster["metadata"]["name"] == "example-postgres"
    spec = cluster["spec"]
    assert spec["imageName"] == "ghcr.io/cloudnative-pg/postgresql:15.3"
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
    assert spec["primaryUpdateMethod"] == "restart"
    assert spec["storage"] == {"storageClass": "rook-ceph-block-ssd", "size": "10Gi"}
    assert spec["certificates"] == {
        "serverTLSSecret": "example-postgres-server-tls",
        "serverCASecret": "example-postgres-server-tls",
        "clientCASecret": "example-postgres-client-replica-tls",
        "replicationTLSSecret": "example-postgres-client-replica-tls",
    }
    assert spec["backup"] == {
        "target": "prefer-standby",
        "retentionPolicy": "30d",
        "barmanObjectStore": {
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
        },
    }
    assert one(resources, "ObjectBucketClaim")["spec"] == {
        "bucketName": "example-postgres-backup",
        "storageClassName": "rook-ceph-bucket-ssd",
    }
    assert spec["monitoring"] == {"enablePodMonitor": True}
    assert "managed" not in spec
    assert "plugins" not in spec


def test_legacy_locale_sql_and_custom_image_survive(tmp_path):
    resources = render(
        tmp_path,
        {
            "image": {
                "repository": "bennycooly/cloudnative-pg-timescaledb",
                "tag": "15.4-debian-timescaledb-2.12.2",
            },
            "postgresqlConfig": {"shared_preload_libraries": ["timescaledb"]},
            "initdb": {
                "localeCType": "en_US.UTF-8",
                "localeCollate": "en_US.UTF-8",
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
    assert spec["bootstrap"]["initdb"]["postInitApplicationSQL"] == [
        "CREATE EXTENSION IF NOT EXISTS timescaledb;"
    ]


def test_plugin_migration_preserves_bucket_and_archive_configuration(tmp_path):
    legacy = render(tmp_path)
    migrated = render(
        tmp_path, {"backup": {"provider": "plugin", "scheduled": {"enabled": True}}}
    )
    old = one(legacy, "Cluster")["spec"]
    new = one(migrated, "Cluster")["spec"]
    store = one(migrated, "ObjectStore")["spec"]
    assert store["configuration"] == old["backup"]["barmanObjectStore"]
    assert store["retentionPolicy"] == old["backup"]["retentionPolicy"]
    assert one(legacy, "ObjectBucketClaim") == one(migrated, "ObjectBucketClaim")
    assert new["backup"] == {"target": "prefer-standby"}
    assert new["plugins"] == [
        {
            "name": "barman-cloud.cloudnative-pg.io",
            "isWALArchiver": True,
            "parameters": {"barmanObjectName": "example-postgres"},
        }
    ]
    schedule = one(migrated, "ScheduledBackup")["spec"]
    assert schedule["method"] == "plugin"
    assert schedule["pluginConfiguration"] == {"name": "barman-cloud.cloudnative-pg.io"}
    assert schedule["immediate"] is True


def test_external_object_store_and_credentials_are_not_mixed_with_ceph(tmp_path):
    resources = render(
        tmp_path,
        {
            "backup": {
                "provider": "plugin",
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
        {"backup": {"provider": "plugin", "objectStore": {"existingName": "offsite"}}},
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
    assert "barmanObjectStore" in one(resources, "Cluster")["spec"]["backup"]
    assert (
        one(resources, "Cluster")["spec"]["backup"]["volumeSnapshot"]["className"]
        == "database-snapshots"
    )
    assert one(resources, "ScheduledBackup")["spec"]["method"] == "volumeSnapshot"
    assert "pluginConfiguration" not in one(resources, "ScheduledBackup")["spec"]


def test_chart_owned_monitor_has_distinct_identity_and_stable_selector(tmp_path):
    resources = render(
        tmp_path,
        {
            "monitoring": {"mode": "podMonitor"},
            "scheduling": {"topologySpreadSelector": "stable"},
        },
    )
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
                "mode": "podMonitor",
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
            {"backup": {"provider": "plugin", "serverName": "example-postgres-pg18"}},
        ),
        "Cluster",
    )["spec"]
    assert spec["plugins"][0]["parameters"] == {
        "barmanObjectName": "example-postgres",
        "serverName": "example-postgres-pg18",
    }
    spec = one(render(tmp_path, {"backup": {"provider": "plugin"}}), "Cluster")["spec"]
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
                "ro": {"type": "ro", "resourceName": "reporting-pool"},
            }
        },
    )
    poolers = {d["metadata"]["name"]: d for d in resources if d["kind"] == "Pooler"}
    assert sorted(poolers) == ["example-postgres-pooler-rw", "reporting-pool"]
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
    assert "reporting-pool.test.svc" in sans
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
            "monitoring": {"mode": "podMonitor"},
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
        (
            {
                "poolers": {
                    "a": {"resourceName": "pool", "pgbouncer": {}},
                    "b": {"resourceName": "pool", "pgbouncer": {}},
                }
            },
            "duplicate Pooler resource name",
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
            "clusterSpec": {
                "walStorage": {"size": "5Gi"},
                "priorityClassName": "database",
            },
            "storage": {"size": "30Gi"},
            "affinity": None,
            "topologySpreadConstraints": [],
        },
    )
    spec = one(resources, "Cluster")["spec"]
    assert "imageName" not in spec
    assert spec["imageCatalogRef"]["major"] == 18
    assert spec["walStorage"] == {"size": "5Gi"}
    assert spec["storage"]["size"] == "30Gi"
    assert "affinity" not in spec
    assert "topologySpreadConstraints" not in spec


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
            "database": {"enabled": True},
            "backup": {
                "scheduled": {"enabled": True, "immediate": False, "suspend": True}
            },
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
        ({"replicaCount": 0}, "replicaCount"),
        ({"backpu": {}}, "backpu"),
        ({"backup": {"provider": "unknown"}}, "provider"),
        (
            {"backup": {"scheduled": {"enabled": True, "schedule": "0 10 * * *"}}},
            "schedule",
        ),
        (
            {"backup": {"provider": "none", "scheduled": {"enabled": True}}},
            "must match",
        ),
        (
            {"backup": {"scheduled": {"enabled": True, "method": "plugin"}}},
            "must match",
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
                    "provider": "plugin",
                    "configuration": {
                        "destinationPath": "s3://test/",
                        "serverName": "other",
                    },
                }
            },
            "serverName must be empty",
        ),
        ({"clusterSpec": {"imageName": "other"}}, "conflicts with a chart-owned field"),
        (
            {
                "database": {"enabled": True},
                "databases": {"app": {"name": "app", "owner": "app"}},
            },
            "conflicts",
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
            {"enableSuperuserAccess": True, "superuserCredsSecretName": None},
            "superuserCredsSecretName is required",
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
            "use monitoring.mode",
        ),
        ({"backup": {"serverName": "pg18"}}, "backup.serverName requires"),
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


def test_new_keys_override_legacy_keys_without_duplicate_role_controllers(tmp_path):
    resources = render(
        tmp_path,
        {
            "database": {"enabled": True, "name": "newdb", "owner": "newowner"},
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


def test_legacy_pod_labels_and_topology_are_stable_across_chart_versions(tmp_path):
    cluster = one(render(tmp_path), "Cluster")
    version = yaml.safe_load((CHART / "Chart.yaml").read_text())["version"]
    assert cluster["metadata"]["labels"]["helm.sh/chart"] == f"postgresql-{version}"
    pod_labels = cluster["spec"]["inheritedMetadata"]["labels"]
    assert pod_labels["helm.sh/chart"] == "postgresql-0.1.0"
    assert (
        cluster["spec"]["topologySpreadConstraints"][0]["labelSelector"]["matchLabels"]
        == pod_labels
    )


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
        "name": "example-postgres-creds-app"
    }
    assert "superuserSecret" not in spec
    secret = one(resources, "ExternalSecret")["spec"]
    assert secret["target"]["name"] == "example-postgres-creds-app"
    assert secret["target"]["creationPolicy"] == "Orphan"
    assert secret["target"]["template"]["data"]["username"] == "app"
    assert secret["refreshPolicy"] == "Periodic"
    assert secret["refreshInterval"] == "0s"
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
    "example,mode", [("legacy", "generated"), ("recovery", "copy")]
)
@pytest.mark.parametrize("admin", [False, True])
def test_eso_targets_are_explicit_cluster_credentials(tmp_path, example, mode, admin):
    resources = render(
        tmp_path,
        {
            "enableSuperuserAccess": admin,
            "credentials": {
                "mode": mode,
                "resourceNames": {
                    "user": "application-credentials",
                    "superuser": "postgres-credentials",
                },
                "copy": {"superuserSecretName": "source-admin"},
            },
        },
        example=example,
    )
    cluster = one(resources, "Cluster")["spec"]
    bootstrap = cluster["bootstrap"]["initdb" if mode == "generated" else "recovery"]
    assert bootstrap["secret"] == {"name": "application-credentials"}
    secrets = [d for d in resources if d["kind"] == "ExternalSecret"]
    expected = {"application-credentials"}
    if admin:
        expected.add("postgres-credentials")
        assert cluster["superuserSecret"] == {"name": "postgres-credentials"}
    else:
        assert "superuserSecret" not in cluster
    assert {d["spec"]["target"]["name"] for d in secrets} == expected
    for secret in secrets:
        assert secret["spec"]["target"]["creationPolicy"] == "Orphan"
        fields = secret["spec"]["target"]["template"]["data"]
        assert fields["username"] == (
            "postgres"
            if secret["metadata"]["name"] == "postgres-credentials"
            else "app"
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
                "enabled": True,
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
        "name": "example-postgres-creds-codecov-user"
    }
    assert cluster["superuserSecret"] == {"name": "example-postgres-creds-postgres"}
    generators = {d["metadata"]["name"] for d in resources if d["kind"] == "Password"}
    assert generators == {
        "example-postgres-creds-codecov-user",
        "example-postgres-creds-postgres",
    }
    for secret in (d for d in resources if d["kind"] == "ExternalSecret"):
        assert secret["spec"]["target"]["name"] == secret["metadata"]["name"]
        assert secret["spec"]["target"]["creationPolicy"] == "Orphan"
        fields = secret["spec"]["target"]["template"]["data"]
        assert fields["username"] == (
            "postgres"
            if secret["metadata"]["name"].endswith("-postgres")
            else "Codecov_User"
        )
        assert (
            secret["spec"]["dataFrom"][0]["sourceRef"]["generatorRef"]["name"]
            == secret["metadata"]["name"]
        )


def test_resource_name_overrides_preserve_previous_database_role_and_copy_identities(
    tmp_path,
):
    resources = render(
        tmp_path,
        {
            "database": {"enabled": True, "resourceName": "example-restored-app"},
            "databaseRoles": {
                "reader": {
                    "name": "read_only",
                    "resourceName": "example-restored-reader",
                }
            },
            "credentials": {"resourceNames": {"user": "example-restored-recovery-app"}},
        },
        example="recovery",
    )
    db = one(resources, "Database")
    role = one(resources, "DatabaseRole")
    assert db["metadata"]["name"] == "example-restored-app"
    assert role["metadata"]["name"] == "example-restored-reader"
    assert "resourceName" not in db["spec"] and "resourceName" not in role["spec"]
    secret = one(resources, "ExternalSecret")
    assert secret["metadata"]["name"] == "example-restored-recovery-app"
    assert secret["spec"]["target"]["name"] == "example-restored-recovery-app"
    assert one(resources, "Cluster")["spec"]["bootstrap"]["recovery"]["secret"] == {
        "name": "example-restored-recovery-app"
    }


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
        ({"database": {"enabled": True, "name": "x" * 63}}, "resourceName"),
        ({"database": {"enabled": True, "name": "_"}}, "set resourceName explicitly"),
        ({"database": {"enabled": True, "resourceName": "BAD_NAME"}}, "resourceName"),
        (
            {
                "enableSuperuserAccess": True,
                "credentials": {
                    "mode": "generated",
                    "resourceNames": {"user": "same", "superuser": "same"},
                },
            },
            "duplicate credential resource name",
        ),
    ],
)
def test_ambiguous_or_invalid_resource_names_fail_before_apply(
    tmp_path, values, message
):
    assert message in render(tmp_path, values, success=False)


def test_resource_name_override_resolves_sql_name_normalization_collision(tmp_path):
    resources = render(
        tmp_path,
        {
            "databases": {
                "one": {"name": "sql_name", "owner": "app"},
                "two": {
                    "name": "sql-name",
                    "owner": "app",
                    "resourceName": "explicit-db-name",
                },
            }
        },
    )
    names = {d["metadata"]["name"] for d in resources if d["kind"] == "Database"}
    assert names == {"example-postgres-db-sql-name", "explicit-db-name"}


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
        "example-postgres-creds-app",
        "example-postgres-creds-postgres",
    }
    admin = next(
        d for d in secrets if d["spec"]["target"]["name"].endswith("-postgres")
    )
    fields = admin["spec"]["target"]["template"]["data"]
    assert fields["dbname"] == "postgres"
    assert ":5432:*:postgres:" in fields["pgpass"]
    for secret in secrets:
        assert secret["spec"]["refreshInterval"] == "48h"
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
        "name": "example-restored-recovery-creds-app"
    }
    assert cluster["superuserSecret"] == {
        "name": "example-restored-recovery-creds-postgres"
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
        assert secret["spec"]["refreshInterval"] == "0s"
        fields = secret["spec"]["target"]["template"]["data"]
        assert "source credential username" in fields["password"]
        assert "example-restored-rw.test" in fields["uri"]
    assert not any(d["kind"] == "Password" for d in resources)


def test_new_tls_profile_and_issuer_override_preserve_legacy_fallback(tmp_path):
    legacy = render(tmp_path)
    assert all(
        d["spec"]["issuerRef"]["name"] == "apps-ca-issuer"
        for d in legacy
        if d["kind"] == "Certificate"
    )
    modern = render(
        tmp_path, {"tls": {"profile": "cnpg", "superuserCertificate": True}}
    )
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
        {"tls": {"profile": "cnpg", "issuerRef": {"name": "custom", "kind": "Issuer"}}},
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
                "copy": {"userSecretName": "example-restored-recovery-creds-app"}
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


def test_schema_only_migration_is_identical_to_legacy_values(tmp_path):
    assert render(tmp_path, example="compatible-keys") == render(tmp_path)


def test_canonical_keys_override_legacy_values_together(tmp_path):
    resources = render(
        tmp_path,
        {
            "replicaCount": 3,
            "instances": 1,
            "postgresqlConfig": {
                "parameters": {"max_connections": "100", "work_mem": "4MB"}
            },
            "postgresql": {"parameters": {"max_connections": "200"}},
            "credentials": {
                "existing": {
                    "userSecretName": "new-app",
                    "superuserSecretName": "new-admin",
                }
            },
            "database": {
                "enabled": True,
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


def test_empty_native_postgresql_and_superuser_reference_clear_legacy_settings(
    tmp_path,
):
    resources = render(
        tmp_path,
        {
            "postgresqlConfig": {"parameters": {"work_mem": "4MB"}},
            "postgresql": {},
            "credentials": {"existing": {"superuserSecretName": ""}},
        },
    )
    spec = one(resources, "Cluster")["spec"]
    assert "postgresql" not in spec
    assert "superuserSecret" not in spec
    assert "superuserCredsSecretName is required" in render(
        tmp_path,
        {
            "enableSuperuserAccess": True,
            "credentials": {"existing": {"superuserSecretName": ""}},
        },
        success=False,
    )


def test_null_native_settings_inherit_legacy_and_nested_admin_satisfies_validation(
    tmp_path,
):
    resources = render(
        tmp_path,
        {
            "instances": None,
            "postgresql": None,
            "replicaCount": 2,
            "postgresqlConfig": {"enableAlterSystem": False},
            "enableSuperuserAccess": True,
            "superuserCredsSecretName": None,
            "credentials": {"existing": {"superuserSecretName": "nested-admin"}},
        },
    )
    spec = one(resources, "Cluster")["spec"]
    assert spec["instances"] == 2
    assert spec["postgresql"] == {"enableAlterSystem": False}
    assert spec["superuserSecret"] == {"name": "nested-admin"}


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
        "name": "example-postgres-creds-app"
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
