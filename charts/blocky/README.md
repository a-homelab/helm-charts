# Blocky

[Blocky](https://github.com/0xERR0R/blocky) as stateless DNS filtering
replicas. The chart uses the repository's `common` library. Upstream Blocky
publishes only a container image, `ghcr.io/0xerr0r/blocky`, which this chart
runs at its `appVersion`.

## Configuration

`blocky.config` is Blocky's own `config.yml`, rendered verbatim into a
ConfigMap and mounted at `/app/config.yml`, the image's `BLOCKY_CONFIG_FILE`.
Its keys follow the [Blocky configuration
reference](https://0xerr0r.github.io/blocky/latest/configuration/), not this
chart. The chart sets the listeners (DNS on 53, HTTP on 4000), JSON logs and
Prometheus metrics. An instance merges its settings over those and must supply
`upstreams.groups.default`. Helm merges maps and replaces lists, so an
instance's upstream or blocklist lists replace rather than extend.

Check a configuration before committing it with the release binary:

```sh
helm template blocky charts/blocky -f my-values.yaml \
  | yq 'select(.kind == "ConfigMap") | .data["config.yml"]' > /tmp/config.yml
blocky validate --config /tmp/config.yml
```

A configuration change rolls the pods through a checksum annotation, because
the file is a subPath mount and never sees ConfigMap updates.

## Availability

Three replicas spread one per node, roll out with `maxUnavailable: 0`, and
drain one at a time under a PodDisruptionBudget. Blocky keeps no state: each
replica downloads its blocklists at startup and keeps its own answer cache.
The startup and readiness probes run `blocky healthcheck`, which answers only
after the lists have loaded under Blocky's default blocking init strategy.

The container runs as UID 100 with a read-only root filesystem and all
capabilities dropped except `NET_BIND_SERVICE`, which the image's binary needs
for port 53.

## Service

One ClusterIP Service carries DNS over UDP and TCP on 53 and metrics on 4000,
and a ServiceMonitor scrapes `/metrics`. Set
`components.main.services.main.clusterIP` when another resolver forwards to
Blocky by address.
