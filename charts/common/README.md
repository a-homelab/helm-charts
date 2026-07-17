# common

Component-oriented Helm library chart. A consumer chart declares **components**
(workloads), **appResources** (typed application-scoped resources) and **rawResources** (verbatim manifests) entirely through values;
its whole `templates/` directory is one line:

```yaml
{{- include "common.all" . }}
```

## Design

### Top-level values keys

```yaml
global:      # injected platform context (gateway, domain, secret store)
defaults:    # component-shaped defaults merged under every component
components:  # named workloads; empty -> one implicit component "main"
appResources: # typed application-scoped resources: appResources.<type>.<name>
rawResources: # raw manifests rendered verbatim (map of key -> manifest|string)
labels:      # stamped on every rendered resource (pods included)
annotations: # stamped on every rendered resource (pods excluded)
# plus the familiar Helm keys: nameOverride, fullnameOverride, namespaceOverride
```

Keys inside a component mirror the Kubernetes ownership model — container
fields live under `container`, pod fields under `pod`, controller fields
under the block matching `kind` (`deployment`, `statefulset`, `cronjob`, ...),
and each per-component resource (`service`, `httpRoute`, `hpa`, `pdb`,
`serviceAccount`) has its own block. If you know where a field lives in the
k8s API, you know where it lives in values.

### Resolution

Each component resolves through a layered deep-merge:

```
libraryDefaults  <-  .Values.defaults  <-  .Values.components.<name>
```

- Later layers win, **including `false`, `0` and `""`** (unlike sprig's
  `mergeOverwrite`).
- Explicit **null deletes**: any layer can remove a whole resource
  (`service: ~`), a map entry (`env.DEPRECATED: ~`), or prune a derived
  entry (`service.ports.http: ~`).
- The library's own defaults only contain values that work standalone.
  Required-by-nature fields (`container.image.repository`,
  `cronjob.schedule`) have **no default** and fail fast with a clear error.
- The component named `main` renders resources as `<fullname>`; every other
  component as `<fullname>-<name>`. Declaring any component replaces the
  implicit `main`.

### Maps, not arrays

Every collection whose entries have identity is a map: `env`, `ports`,
`volumes`, `mounts`, `sidecars`, `initContainers`, `tolerations`,
`parentRefs`, `appResources.*`, `rawResources`, ... Map keys give entries identity across layers
and values files (add/override/delete individual entries from an overlay);
rendering converts maps to deterministically ordered lists (sorted by
optional `weight`, then key), so manifests are byte-stable and GitOps diffs
never churn. Arrays remain only where order is semantic (`command`, `args`,
`httpRoute.rules`) or for raw k8s passthrough (`affinity`, `hpa.behavior`).

### Derived wiring

Cross-resource plumbing is computed at render time, never stored in values:

- Service ports mirror the union of all containers' named ports
  (service-side port = `expose | port`); no ports -> no Service.
- HTTPRoute hostnames default to `<name>.<global.domain>`, parentRefs to
  `global.gateway`, rules to one catch-all whose backendRef targets the
  component's Service and first port.
- `serviceAccountName`, PVCs from `volumes.type: pvc`, probe ports by port
  name, selector labels — all automatic.

### Metadata rules

1. Selector labels are locked and never merged with user labels: `name` +
   `instance`, plus `component` for named components. The component named
   `main` gets no component/part-of labels (classic single-app layout, and
   migrations from plain charts never touch the immutable Deployment
   selector) — which is why mixing `main` with named components is
   rejected: sibling selectors could otherwise match main's pods.
2. Volatile generated labels (`helm.sh/chart`, `version`) stay off pod
   templates, so a chart version bump alone never rolls pods.
3. Top-level `annotations` never touch pod templates; pod annotations come
   only from `pod.annotations` (tpl-rendered — checksums go here).
4. Top-level `labels` reach everything, pods included.

Cascade (later wins): generated -> top-level -> component -> resource.

### Shared resources: two scopes, and sharing = hoist + reference

Every resource has one owner. Component scope (inside `components.<name>`,
named `<componentResourceName>-<key>`) or app scope (`appResources.<type>.<key>`,
named `<fullname>-<key>`). Sharing is never one component reaching into
another — anything shared is hoisted to `appResources` and consumed **by key**;
the library resolves keys to rendered names and fails on dangling
references at render time:

| You write | Resolves to | Emits |
|---|---|---|
| volume `type: pvc` (inline) | claim `<component>-<key>` | component-scoped PVC |
| volume `type: pvc, ref: k` | claim of `appResources.pvc.k` | nothing |
| volume `type: configMap/secret, ref: k` | that appResources resource | nothing |
| volume `type: secret, certRef: k` | `appResources.certificate.k`'s secretName | nothing |
| env `valueFrom` / `envFrom` `ref: k` | that appResources resource | nothing |
| route backendRef `component: c` | `c`'s Service + resolved port (name or first) | nothing |
| appResources entry `component: c` | named/labeled under `c` | component-scoped resource |

`appResources.httpRoute.<key>` fans one hostname across components (rules
required, backendRefs by `component:`); `appResources.certificate.<key>` renders
a cert-manager Certificate (issuer from `global.certIssuer`, secret
`<name>-tls`, dnsNames from `global.domain`).

### Template API (stable, for tpl-rendered values)

Inside any tpl-rendered string (env values, annotations, hostnames,
overrides, rawResources), these named templates are the supported way to
reference other parts of the chart — all validated, so dangling
references fail at render time:

| Template | Returns |
|---|---|
| `common.fullname` (ctx) | release-scoped app name |
| `common.name` (ctx) | chart/app name |
| `common.namespace` (ctx) | target namespace |
| `common.ref` (list ctx type key) | rendered name of an `appResources` entry |
| `common.ref.component` (list ctx name) | a component's resource/Service name |
| `common.ref.serviceHost` (list ctx name) | `<service>.<namespace>.svc` |
| `common.ref.tlsSecret` (list ctx key) | Secret name a certificate writes |

```yaml
env:
  CONFIG_NAME: '{{ include "common.ref" (list . "configMap" "config") }}'
  WORKER_URL: 'http://{{ include "common.ref.serviceHost" (list . "worker") }}:9090'
  TLS_SECRET: '{{ include "common.ref.tlsSecret" (list . "web") }}'
pod:
  annotations:
    checksum/config: '{{ .Values.appResources.configMap.config.data | toYaml | sha256sum }}'
```

Deliberate non-feature: shared volumes do not auto-mount into components.
Mount paths, readOnly and subPaths differ per consumer, so `pod.volumes`
stays the single complete description of each component's filesystem.

### Escape hatches, three altitudes

Every resource block accepts `overrides:` — tpl-rendered and deep-merged
onto the rendered manifest. Crucially, `container.overrides` and
`pod.overrides` apply **before** containers are assembled into lists, so
any container/pod field the library doesn't model is still reachable
(deep-merge cannot patch list elements, so patching happens pre-assembly).
For entire resource types the library doesn't model, use
`rawResources.<name>` — full manifests (as maps or literal YAML strings) that still get standard
labels and tpl rendering.

## Minimal consumer

```yaml
# values.yaml — a complete single-app chart
components:
  main:
    container:
      image:
        repository: lscr.io/linuxserver/sonarr
      env:
        TZ: America/Chicago
      ports:
        http:
          port: 8989
    pod:
      volumes:
        config:
          type: pvc
          size: 1Gi
          mounts:
            /config: {}
    httpRoute:
      enabled: true      # hostname: <fullname>.<global.domain>
```

Renders Deployment, Service, ServiceAccount, HTTPRoute and PVC, fully wired.

## Multi-component

```yaml
defaults:                # shared across all components
  pod:
    securityContext:
      runAsNonRoot: true

components:
  api:
    container:
      image: { repository: ghcr.io/example/app }
      ports: { http: { port: 8080 } }
    sidecars:
      oauth-proxy:
        image: { repository: quay.io/oauth2-proxy/oauth2-proxy, tag: v7.6.0 }
        ports: { proxy: { port: 4180, expose: 80 } }
    httpRoute: { enabled: true }
  worker:
    container:
      image: { repository: ghcr.io/example/app }
      command: [./worker]
    service: ~           # delete the inherited Service
```

## Values schema

[`schema/values.schema.json`](schema/values.schema.json) validates the
library's structural keys and delegates every Kubernetes-typed field
(probes, securityContext, affinity, resources, strategies, HPA metrics, ...)
to the upstream [kubernetes-json-schema](https://github.com/yannh/kubernetes-json-schema)
definitions via remote `$ref` (pinned k8s version) — no upstream logic is
duplicated here.

It deliberately does **not** live at the chart's magic `values.schema.json`
path: Helm's validator eagerly fetches remote `$ref`s at render time, which
would make every `helm template` (and every ArgoCD render) network-dependent.
Instead:

- **Editor**: consumer values files opt in with a modeline —
  `# yaml-language-server: $schema=charts/common/schema/values.schema.json`
  (or the raw GitHub URL once published).
- **CI**: fixtures are validated with `check-jsonschema` (resolves remote
  refs) in the test workflow.

## Testing

The sibling [`common-tests`](../common-tests/) harness chart depends on this
chart via `file://../common`. Unit tests use
[helm-unittest](https://github.com/helm-unittest/helm-unittest) and cover
deployment basics, metadata propagation rules, env/config conversion,
persistence (PVCs, existingClaim, configMap refs, emptyDir, custom volumes,
statefulset volumeClaimTemplates), service/route derivation, overrides at
all three altitudes, multi-component resolution, and all controller kinds.

```sh
helm plugin install https://github.com/helm-unittest/helm-unittest.git --version v0.5.2
helm dependency update charts/common-tests
helm unittest charts/common-tests

# render fixtures directly
helm template t charts/common-tests                                        # single-app
helm template t charts/common-tests -f charts/common-tests/ci/multi-component-values.yaml
helm template t charts/common-tests -f charts/common-tests/ci/controllers-values.yaml

# validate values against the schema
uvx check-jsonschema --schemafile charts/common/schema/values.schema.json <values.yaml>
```

CI runs lint + unit tests + fixture rendering + schema validation on every
PR touching `charts/**` (`.github/workflows/test-charts.yaml`).

## Status / roadmap

v1.0.0-alpha: Deployment, StatefulSet (incl. volumeClaimTemplates),
DaemonSet, CronJob, Job; Service, HTTPRoute, HPA, PDB, ServiceAccount;
appResources: configMap, secret, externalSecret, pvc, certificate, httpRoute;
rawResources (map- and string-form); values schema
(upstream k8s refs); helm-unittest suite in CI.

Planned: NetworkPolicy, ServiceMonitor, GRPCRoute/TCPRoute/TLSRoute,

migration of existing app charts.
