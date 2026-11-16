# Kafka

One Strimzi Kafka cluster per release, in KRaft mode: the `Kafka` resource, its `KafkaNodePool`s,
`KafkaTopic`s and `KafkaUser`s, a client certificate per user, a cluster CA and clients CA of its
own, and Strimzi's PodMonitors. Start from [examples/mimir.yaml](examples/mimir.yaml);
[values.yaml](values.yaml) documents every key.

## Prerequisites

- The Strimzi Cluster Operator 1.3.1, watching the release namespace. The templates use the
  `kafka.strimzi.io/v1` API and Strimzi's cert-manager mode, which is Early Access in 1.3.
- cert-manager 1.21 and approver-policy 0.28, with cert-manager allowed to `use` every
  CertificateRequestPolicy. The chart ships the policies for its own Issuers.
- The Prometheus Operator CRDs, unless `podMonitors.enabled` is false.

## What it renders

| Object | Name |
| --- | --- |
| Kafka | the cluster name: the release name, or `fullnameOverride` |
| KafkaNodePool | each key of `nodePools`; pods are `<cluster>-<pool>-<id>` |
| KafkaTopic | each key of `topics` |
| KafkaUser and Certificate | each key of `users`; the certificate and its Secret are `<user>-kafka-client` |
| CA Certificates and Issuers | `<cluster>-cluster-ca-root`, `<cluster>-clients-ca-root`, bootstrapped by `<cluster>-ca-selfsigned` |
| CertificateRequestPolicies | one per Issuer, same name |
| PodMonitors | `kafka-resources-metrics`, `entity-operator-metrics` |

`Kafka` and `KafkaNodePool` carry no chart labels. Strimzi copies a custom resource's labels onto
every pod it runs, except `app.kubernetes.io/*`, so `helm.sh/chart` would restart the brokers and
controllers on every chart release.

The PodMonitors' names are fixed and select every Kafka pod in the namespace, so run one release
per namespace, beside the workload that uses it.

## Certificates and trust

Each cluster has two CAs, both self-signed roots chained to nothing:

- The **cluster CA** signs the brokers, controllers and Strimzi's operators. The internal
  replication and controller listeners trust only it. Its policy admits only this cluster's
  Strimzi identities (`<cluster>-kafka`, `cluster-operator`, `<cluster>-entity-topic-operator`,
  `<cluster>-entity-user-operator`), organization `io.strimzi`, with DNS names under this cluster's
  Services.
- The **clients CA** signs each user's certificate. The client listener on 9093 trusts only it,
  and Kafka takes the principal from the certificate's CN, `User:CN=<user>`. Its policy admits only
  the users this release declares.

A CA per cluster is what keeps one cluster's certificates out of another. Strimzi's
`cluster-operator` certificate has the same CN in every cluster and is a super user, so with a
shared cluster CA, reading its Secret in one namespace would grant super user on every Kafka
cluster. The rule is in the pki repository's README, "One general-purpose CA per domain, and
purpose CAs only at an authentication boundary".

Strimzi copies each CA's certificate into its own `<cluster>-cluster-ca-cert` and
`<cluster>-clients-ca-cert` Secrets, key `ca.crt`. A client mounts two Secrets:

- `<cluster>-cluster-ca-cert`, to verify the brokers.
- `<user>-kafka-client`, for its own `tls.crt` and `tls.key`. Its `ca.crt` is the clients CA,
  which does not verify the brokers.

Client certificates last 90 days and renew 15 days early. Restart clients that read them once at
start, for example with Reloader on both Secrets.

The CA keys are in this namespace, where the Entity Operator can read them; its Role covers every
Secret in the namespace. It is already a super user of this cluster, and the CAs are trusted by no
other, so that reach ends at this cluster.

Moving a running cluster onto these CAs reissues every broker, controller, operator and client
certificate. Plan it as a rollout of its own.

## Not supported

- Kafka Exporter and Cruise Control: their certificates' CNs are not in the cluster CA's policy.
- Listeners other than the internal TLS listener, and authentication other than client
  certificates.
- Changing a controller pool after the first sync: Strimzi 1.3.1 cannot add, rename, scale, or
  resize one.

## Tests

```sh
helm lint charts/kafka --strict -f charts/kafka/examples/mimir.yaml
helm unittest charts/kafka
python scripts/validate_kafka_schemas.py --cache /tmp/kafka-schema-sources
```

The last renders each example and validates every object against the pinned Strimzi 1.3.1,
cert-manager 1.21.2 and approver-policy 0.28.0 CRDs in
[tests/schema-sources.json](tests/schema-sources.json). CEL rules and admission webhooks need a
cluster.
