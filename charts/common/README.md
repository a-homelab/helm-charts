# Common library chart

Common turns a consumer chart's values into workloads and their supporting
resources. Put `{{- include "common.all" . }}` in `templates/all.yaml`, add this
library as a dependency, and describe the application in `values.yaml`.

This is the breaking `1.0.0-alpha.3` contract. Update consumers together with the
library. Alpha.1 values are not compatible.

## A small application

```yaml
components:
  main:
    container:
      image:
        repository: ghcr.io/example/web
        tag: "1.2.3"
      ports:
        http:
          port: 8080
          expose: 80
    routes:
      main:
        hostnames: [app.example.com]
        parentRefs:
          edge:
            name: public-gateway
            namespace: gateways
            sectionName: https
```

The main component gets the chart's fullname. Adding `components.worker` creates
another workload with a `-worker` suffix. Every component, including `main`, has
its own selector label. If `components` is omitted, an implicit `main`
uses `defaults`. Disable the last component with `enabled: false`; deleting its
key can make the implicit component return if the components map is also removed.

Supported workloads are Deployment, StatefulSet, DaemonSet, Job and CronJob.
`kind` defaults to Deployment. Enabled workloads need an image repository, and
CronJobs also need `cronjob.schedule`. The image tag defaults to `appVersion`,
then `latest`; a `sha256:` tag uses a digest reference.

## Resource cardinality

| Values location | Per component | Reason |
| --- | --- | --- |
| Component workload | One | A component is one pod group and its lifecycle. |
| `services` | Many | Internal/public endpoints, headless discovery, separate port sets. |
| `routes` | Many | Hosts, protocols, filters and attachment policies can differ. |
| `listenerSets` | Many | Each set attaches listeners to one Gateway. |
| `container`, `sidecars`, `initContainers` | One main, many others | Containers share the component's PodSpec. |
| `pod.volumes`, `container.volumeMounts` | Many | Native volume sources and independent mounts for each container. |
| `statefulset.volumeClaimTemplates` | Many | Native PVC metadata and spec, keyed by claim name. |
| `hpa` | Zero or one | Multiple autoscalers would compete to scale this same workload. |
| `pdb` | Zero or one | One disruption policy for this component's shared pod selector. |
| `serviceAccount` | One selected account | Kubernetes selects one account for a pod; it may be existing. |
| `appResources.<type>` | Many | ConfigMaps, Secrets, ExternalSecrets, PVCs, certificates, routes and ListenerSets can be shared or component-scoped. |
| `rbac.roles`, `rbac.bindings` | Many | Independent permission sets, role scopes and subject lists. |
| `networkPolicies` | Many | Independent ingress/egress permissions combine additively. |
| `serviceMonitors`, `podMonitors` | Many | Independent scrape selections and settings. |
| `rawResources` | Many | Additional Kubernetes and custom resources with native manifests. |

Shared maps also include RBAC, NetworkPolicy, monitors, Gateway and ReferenceGrant.
The remaining singular resources represent one workload's lifecycle, identity or
scale target. Native manifests remain available for additional resource kinds.

## Named Services

```yaml
components:
  main:
    kind: StatefulSet
    container:
      image: {repository: postgres, tag: "17"}
      ports:
        postgres: {port: 5432}
        metrics: {port: 9187}
    statefulset:
      service: discovery
    services:
      discovery:
        clusterIP: None
        publishNotReadyAddresses: true
        ports:
          postgres: {}
      main:
        ports:
          postgres: {}
      metrics:
        ports:
          metrics: {}
```

- Omitted or empty `services` derives `main` when the workload has ports.
  For StatefulSet, that implicit Service is headless, including when portless.
- Declaring any Service entries replaces the implicit collection. A collection
  containing only disabled entries stays disabled.
- `main` uses the component's resource name; other keys append `-<key>`.
  `name` can override that name. Long generated names use a stable hash suffix.
- Omitted `ports` derives all ports from the main container, sidecars, and native
  sidecars (`sidecars` native by default, or `initContainers` with
  `restartPolicy: Always`).
- Present `ports` selects only the listed entries. `{}` derives the matching
  container port. An empty ports map selects none.
- `port` changes the Service-side port; `targetPort` accepts a declared port name
  or a number. Numeric target ports do not require a declared ContainerPort.
- `enabled: false` disables an entry. A portless ExternalName Service is supported
  with `type: ExternalName`, `externalName`, and `ports: {}`.

A managed StatefulSet governing Service must be headless. Select its key through
`statefulset.service` (default `main`), or use `statefulset.serviceName` for an
external Service. The two settings are mutually exclusive. Other Services can
expose the same StatefulSet to clients.

## Routes and ListenerSets

Each `routes.<key>` defaults to HTTPRoute. Other supported kinds are GRPCRoute,
TLSRoute, TCPRoute and UDPRoute. No route or ListenerSet is implicit.

```yaml
components:
  main:
    container:
      image: {repository: ghcr.io/example/web}
      ports:
        http: {port: 8080}
    listenerSets:
      public:
        parentRef:
          name: edge
          namespace: gateways
        listeners:
          https:
            hostname: app.example.com
            port: 443
            protocol: HTTPS
            tls:
              mode: Terminate
              certificateRefs:
                - certRef: web
    routes:
      main:
        hostnames: [app.example.com]
        parentRefs:
          secure:
            listenerSet: public
            sectionName: https
        rules:
          - backendRefs:
              - component: main
                service: main
                port: http
      redirect:
        parentRefs:
          plain: {name: edge, namespace: gateways, sectionName: http}
        rules:
          - filters:
              - type: RequestRedirect
                requestRedirect: {scheme: https, statusCode: 301}
appResources:
  certificate:
    web:
      dnsNames: [app.example.com]
      issuerRef: {name: public, kind: ClusterIssuer}
```

Parent-reference map keys are logical identifiers. An explicit `name` allows
several entries for the same Gateway with different listeners or namespaces.
`listenerSet` resolves a component ListenerSet; `component` can select another
component. `ref` resolves an `appResources.listenerSet` key. `certRef` in a
ListenerSet certificate reference resolves an `appResources.certificate` Secret.

`global.gateway` supplies omitted parent references. `global.domain` supplies an
omitted hostname as `<resourceName>.<domain>`. Explicit empty maps/lists suppress
these defaults. TLSRoute requires hostnames. TCPRoute and UDPRoute do not accept
them. ListenerSet needs listeners and a parent Gateway, either explicit or from
`global.gateway`.

Omitted route rules derive a backend to the component's `main` Service only when
that Service has exactly one port. Explicit rules are ordered native rules:
missing or empty `backendRefs` stay that way. An empty backend entry `{}` requests
the default component and Service. Choose `port` when a Service has multiple
ports. A managed backend accepts a numeric port or its Service port name and is
resolved against the final Service, including overrides. External backends use
native `name`, numeric `port`, and optional namespace/kind/group.

Shared routes live in `appResources.route`, with the same route shape. An optional
`component` scopes their labels/name and default backend. App-scoped routes need
explicit rules. Shared ListenerSets live in `appResources.listenerSet`.

ListenerSet and TLSRoute default to `gateway.networking.k8s.io/v1`, requiring
Gateway API 1.5 or newer. HTTPRoute and GRPCRoute also use v1. TCPRoute and UDPRoute
use v1alpha2 from the experimental channel. `apiVersion` can be supplied for an
installed compatible API, but only the documented defaults are schema-tested.
The parent Gateway must allow ListenerSet attachment, and the Gateway controller
must implement the requested features. See the upstream
[ListenerSet guide](https://gateway-api.sigs.k8s.io/guides/user-guides/listener-set/)
and [API overview](https://gateway-api.sigs.k8s.io/concepts/api-overview/).

## Inheritance and removal

Components resolve `library defaults -> defaults -> components.<key>`. Maps merge
recursively; lists replace. `containerDefaults` supplies policy to every main,
sidecar and init container before its specific settings. `defaults.container`
applies only to main containers. Sidecars and init containers can inherit the
main image, including a partial override such as `image: {tag: debug}`.

Helm can remove null values while coalescing chart defaults and `-f` files before
this library sees them. Null entries that survive are deletion tombstones, but
null is not a reliable cross-file deletion instruction. Use `enabled: false` to
disable components or supporting resources. Use component `remove` for inherited
fields and entries in explicitly declared maps:

```yaml
components:
  main:
    remove:
      - /container/env/OBSOLETE
      - /container/probes/readiness/httpGet
```

These are JSON pointers relative to the resolved component (`~1` escapes `/`,
`~0` escapes `~`). Removal runs after inheritance and before derivation. Parent maps must exist;
use an explicit Service ports map to select a subset of derived ports. The list
itself replaces under Helm overlays, so include every required removal in the
last overlay. Remove `/services` to suppress the complete derived collection.
Removal of required workload settings fails rendering.

Identity maps cross into ordered lists using `weight` (integer 0-999999, default
100), then the map key. Weight is available for containers, env, ports and other
ordered identity maps, and is stripped from native output. Put referenced env
variables before their dependents. Native route backend `weight` keeps its
Gateway API meaning because backend references are already a list.

### Native sidecars and startup ordering

Entries in `components.<name>.sidecars` render under `spec.initContainers` with
`restartPolicy: Always` by default. Set `native: false` on an entry to keep it
in `spec.containers` instead. This changes the previous classic sidecar default. Native
sidecars and regular init containers share one ordering: ascending `weight`
(default 100), then map key. Their keys and rendered container names must be
unique. The chart strips `native` and `weight` from the container output.

When migrating, set lower weights on init containers that prepare files or tools
needed by sidecars. A native sidecar's startup probe must not depend on the main
application starting, because that probe gates the remaining init containers and
the application. Use `native: false` for sidecars that need classic startup
behavior.

Native sidecars use the same image inheritance, probes, mounts, resources,
security context and `enabled` handling as other sidecars. `native: true`
sets `restartPolicy: Always` after container overrides. Existing native
sidecars declared directly in `initContainers` remain supported.

```yaml
components:
  main:
    container:
      image: {repository: example/app, tag: "1.0"}
    initContainers:
      tools:
        weight: 0
        command: [install-tools]
      clone:
        weight: 20
        command: [clone-repositories]
    sidecars:
      token-renewal:
        native: true
        weight: 10
        command: [renew-token]
        probes:
          startup:
            exec:
              command: [check-token]
            periodSeconds: 5
            failureThreshold: 60
```

With this sequence, tools completes, token renewal starts, its startup probe
succeeds, cloning completes, and the main application starts. Token renewal
continues running. A readiness probe alone does not gate the next init
container; use `probes.startup` for that dependency. See the
[Kubernetes sidecar lifecycle documentation](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/#sidecar-containers-and-pod-lifecycle).
Kubernetes v1.31.14 supports this behavior with `SidecarContainers` enabled.

### Conditional containers and typed user IDs

Sidecars and init containers accept `enabled`, defaulting to `true`. It accepts a
boolean or a template that evaluates to `true` or `false`. Disabled entries are
removed after inheritance and explicit removal, before pod and Service derivation;
their ports do not enter Services. The main container follows its component's
existing `enabled` setting.

Container `securityContext.runAsUser` and `runAsGroup` accept integer values or
templates that resolve to non-negative integers. Rendered values are integers,
including zero; other security-context fields retain their native types.

```yaml
components:
  main:
    sidecars:
      worker:
        enabled: '{{ .Values.worker.enabled }}'
        securityContext:
          runAsUser: '{{ .Values.worker.uid }}'
          runAsGroup: '{{ .Values.worker.gid }}'
```

Define the referenced `worker` settings in the consumer's values and schema.

## Shared resources and storage

`appResources` supports `configMap`, `secret`, `externalSecret`, `pvc`,
`certificate`, `route` and `listenerSet`, each as a named map. Most entries support
`enabled`, `name`, `component`, labels, annotations and overrides. PVC entries use
native `metadata` and `spec` as described below.

- ConfigMap `data` and Secret `stringData` evaluate templates only with `tpl: true`.
- ExternalSecret uses `storeRef`, `target`, `data` and `dataFrom`. Shared defaults
  are under `global.externalSecrets`.
- Certificate supports `dnsNames`, `secretName`, `issuerRef`, duration and usages.
  Shared issuer defaults are under `global.certIssuer`.
- PVC uses native `metadata` and `spec`, including `spec.storageClassName`,
  `spec.accessModes` and `spec.resources.requests.storage`. Set
  `spec.storageClassName: ""` to disable default storage-class selection. PVC entries
  also accept `enabled` and the optional `component` naming/label back-reference.

Define `pod.volumes` as a map keyed by volume name. Each value contains native
Kubernetes Volume source fields such as `emptyDir`, `persistentVolumeClaim`,
`configMap`, `secret`, `projected`, `csi` or `ephemeral`. The chart supplies `name`
from the key; do not repeat it in the value. Exactly one source is required.

Define `volumeMounts` independently in `container`, each `sidecars` entry, and
each `initContainers` entry. The map key is a logical mount ID used only for Helm
overrides. Each value contains native VolumeMount fields, including explicit
`name` and `mountPath`. The same volume can be mounted multiple times in one
container and with different paths, permissions or subpaths in other containers.
Volumes and mounts also accept `enabled` with the same boolean/template behavior
as sidecars. This chart-only field is stripped from Kubernetes output. Coordinate
the conditions: an enabled mount referencing a disabled volume fails validation.
Disabled entries are skipped before evaluating their native field templates.

```yaml
appResources:
  pvc:
    workspace:
      metadata:
        annotations:
          helm.sh/resource-policy: keep
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 50Gi

components:
  main:
    pod:
      volumes:
        workspace:
          persistentVolumeClaim:
            claimName: '{{ include "common.ref" (list . "pvc" "workspace") }}'
    container:
      volumeMounts:
        workspace:
          name: workspace
          mountPath: /workspace
          readOnly: true
        exports:
          name: workspace
          mountPath: /exports
          subPath: exports
          readOnly: true
    initContainers:
      prepare:
        volumeMounts:
          workspace:
            name: workspace
            mountPath: /workspace
            readOnly: false
```

An override can change only `container.volumeMounts.workspace.readOnly` without
repeating the mount or replacing other mounts. Omitted entries inherit normally;
null removes explicit map entries during merging. Use the component `remove`
JSON pointers when removing inherited defaults across values layers. Removing a
volume does not remove mounts or delete a separately declared PVC: update all
references explicitly. Changing a volume's source requires removing the old
source field as well as adding the new one.

Resource-name strings support templates. Use `common.ref` in native `claimName`,
`configMap.name` or `secret.secretName`, and `common.ref.tlsSecret` for a
Certificate's Secret. Literal names reference existing resources directly.

PVCs are created only by `appResources.pvc`. A Pod volume only references a claim.
StatefulSet `volumeClaimTemplates` is a map of native PVC `metadata` and `spec`
objects; its key supplies `metadata.name`. Containers mount those claims by the
same name. Claim templates and explicit pod volumes must have distinct names.
Unknown mount references, duplicate volume names, duplicate mount paths within a
container, and conflicting subpath settings fail rendering.

Storage input schemas use the vendored Kubernetes 1.37 field definitions with
required fields relaxed for partial overlays. Validate final manifests against
the actual target Kubernetes version; newer fields can require newer versions
or feature gates.

## References, templates and overrides

Template-enabled fields include image tags, commands/args, env values,
annotations, route rules/hostnames, and override objects. Use these helpers inside
such strings:

```yaml
container:
  env:
    API_HOST: '{{ include "common.ref.serviceHost" (list . "api" "main") }}'
    CONFIG_NAME: '{{ include "common.ref" (list . "configMap" "config") }}'
pod:
  annotations:
    checksum/config: '{{ include "common.checksum.configMap" (list . "config") }}'
```

`common.ref.service` returns the final Service name. `common.ref.serviceHost`
returns `<name>.<namespace>.svc`. Both take a component and optional Service key
(default `main`). `common.ref.component` returns the workload name;
`common.ref.tlsSecret` returns a certificate's Secret name. Disabled or missing
managed references fail. The checksum helper hashes effective rendered ConfigMap
data, so changes to values referenced by templates trigger rollouts.

`overrides` is a free-form, template-evaluated deep merge at the natural boundary:
container object, PodSpec (`pod.overrides`), workload manifest, or supporting
resource manifest. Lists replace. Use it for native fields the chart does not
model yet. Typed resource overrides cannot change apiVersion/kind or move a
resource out of the release namespace (or `namespaceOverride`). Workload identity,
component selector labels and inline claim names are protected. Other managed
names can change; reference helpers follow them. Cyclic Service template
references fail explicitly.

Overrides are intentionally outside values type validation. Validate emitted
manifests against the APIs installed in your cluster. Schema validity alone does
not prove admission, controller support, authorization or cross-namespace grants.

Resource-only charts can set `components: {}` and declare only `appResources`
or `rawResources`. For overlays of existing workloads, disable their named entries
with `enabled: false`; Helm merges maps rather than clearing them with `{}`.

## RBAC, network policy and monitoring

Components own named `rbac.roles`, `rbac.bindings`, `networkPolicies`,
`serviceMonitors` and `podMonitors` maps. These collections have no implicit
entries. Their entries support `enabled`, `name`, labels, annotations and
manifest overrides, like Services and routes.

```yaml
components:
  main:
    container:
      image:
        repository: example/app
        tag: "1.0"
      ports:
        http: {port: 8080}
        metrics: {port: 9090}
    services:
      main:
        ports:
          http: {}
      metrics:
        ports:
          metrics: {}
    rbac:
      roles:
        reader:
          rules:
            pods:
              apiGroups: [""]
              resources: [pods]
              verbs: [get, list]
      bindings:
        reader:
          role: reader
    networkPolicies:
      metrics:
        ingress:
          scrape:
            from:
              - namespaceSelector:
                  matchLabels:
                    kubernetes.io/metadata.name: monitoring
            ports:
              - port: metrics
                protocol: TCP
    serviceMonitors:
      main:
        service: metrics
        endpoints:
          metrics:
            interval: 30s
    podMonitors:
      direct:
        endpoints:
          metrics: {}
```

Role rules, binding subjects, network ingress/egress rules and monitor endpoints
are ordered maps and accept `weight`. A binding's `role` selects a role in its
component; `ref` selects `appResources.role`; native `roleRef` references an
existing role. Omitted subjects select the component's effective ServiceAccount.
Explicit subjects may use `component: worker` or native ServiceAccount/User/Group
fields. `kind: ClusterRole` and `kind: ClusterRoleBinding` create cluster resources;
their generated names include the namespace to avoid cross-namespace release
collisions. Explicit names remain the caller's responsibility.

Component NetworkPolicies select that component's pods. Peers in native `from`
or `to` arrays can use `component: api` to select another component in the same
namespace. Native namespace/pod selectors and IP blocks remain available.
`ingress: {}` or `egress: {}` explicitly denies that direction; multiple policies
combine according to Kubernetes' additive policy rules. Your CNI must enforce
NetworkPolicy.

ServiceMonitor selects the final named Service, including name overrides, using
a chart-managed identity label. PodMonitor selects component pods. Endpoint keys
default the named port; explicit `port`, `portNumber` (PodMonitor), or `targetPort`
uses native endpoint selection. Named ports are checked during rendering. Native
monitor options go under `spec`; endpoint options stay beside the port.
Managed selectors and namespace selection cannot be overridden. Prometheus must
select the monitor's labels and namespace, and its operator CRDs must be installed.

Shared equivalents are `appResources.role`, `roleBinding`, `networkPolicy`,
`serviceMonitor` and `podMonitor`. Shared monitors require `component`; shared
bindings need `component` or explicit subjects; shared policies need `component`
or an explicit native `podSelector` (including `{}` for every pod).

`appResources.gateway` and `appResources.referenceGrant` are named maps with a
native `spec`. A Gateway owner explicitly configures `spec.allowedListeners`;
a ReferenceGrant owner explicitly selects permitted source and destination
resources. These permissions are never inferred from an application's request.
Use a separate release in the owning namespace, or explicit raw resources,
when the application does not own that namespace.

One workload controller, ServiceAccount, HPA and PDB remain associated with each
component. A workload uses one service account; competing HPAs would control the
same replica count, and overlapping PDBs can prevent evictions. Use separate
components for separate workloads and raw resources for deliberate exceptional
policy relationships.

## Arbitrary resources

```yaml
rawResources:
  permissions:
    scope: Cluster
    manifest:
      apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRole
      metadata:
        name: example-reader
      rules: []
  custom:
    tpl: true
    manifest: |
      apiVersion: example.io/v1
      kind: Widget
      spec:
        release: {{ .Release.Name }}
```

Each entry contains one structured or string `manifest`, plus optional `enabled`,
`scope` (Namespaced or Cluster) and `tpl` (default false). String manifests must
contain one document without YAML document separators. Literal manifest strings preserve explicit nulls and other systems' template
syntax unless template evaluation was requested. Structured manifests remain
subject to Helm coalescing, which can strip nulls before rendering; use a literal
manifest string when an API requires an explicit null. Standard metadata is supplied only as defaults. Cluster scope omits
namespace. Duplicate final resource identities fail instead of silently replacing
one another.

## Schemas and validation

`schema/values.schema.json` is the source contract. It bundles its Kubernetes
references offline. Consumer charts need their own root `values.schema.json`
because Helm validates a library dependency's values separately from its parent.
Generate it with:

```sh
python scripts/common_schema.py charts/my-app
python scripts/common_schema.py charts/my-app --extensions charts/my-app/schema/extensions.json
python scripts/common_schema.py charts/my-app --check
```

An extension JSON file supplies additional root `properties`, `definitions`,
optional `required` keys, and `allOf` constraints. Use `allOf` to narrow common
values for an application, such as requiring one Deployment replica, without
replacing common definitions. Structural chart keys are
strict; arbitrary Kubernetes fields belong in the documented overrides. Input
schemas accept partial overlays; rendering checks required resolved values and
managed relationships. The integration suite also validates native outputs.

CI exercises Helm 3.22.0 and 4.3.0. Offline output validation covers every
built-in Kubernetes resource in versions 1.31 through 1.37, Gateway API 1.5,
cert-manager 1.21.2, External Secrets 2.10.0 and Prometheus Operator 0.94.0.
The input contract uses Kubernetes 1.31 as its portability baseline. Newer native
fields can use overrides and the matching output version.

```sh
helm template app charts/my-app > /tmp/app.yaml
python scripts/validate_manifests.py /tmp/app.yaml --kubernetes-version 1.36
python scripts/validate_manifests.py /tmp/app.yaml --crd schemas/widgets.example.com.yaml
python scripts/validate_manifests.py /tmp/app.yaml --schemas schemas/custom-output.json
```

Custom output JSON files map `apiVersion/kind` to complete JSON Schemas, with
local references only. CRD files contribute each served version's OpenAPI schema.
Unknown API versions and kinds fail closed, including raw resources. Custom
schemas cannot replace bundled contracts. Always validate the final render,
including application templates and raw resources, rather than only values.
Schema checks do not execute CEL, admission webhooks, or controllers.

The disposable-cluster suite admits all five workload kinds and supporting
resources on Kubernetes 1.31, 1.36 and 1.37. It checks rejection of invalid native
and Gateway CEL configurations, and runs a Job that verifies writable init mounts
and read-only main-container mounts of the same volume. Kubernetes 1.36 with Istio 1.31 also verifies HTTP
traffic through direct Gateway and ListenerSet attachments, multiple named
Services, denied ListenerSet attachment, cross-namespace ReferenceGrant enforcement, and RBAC authorization. Other controllers,
CNIs and optional operators need their own runtime compatibility tests.

```sh
kind create cluster --name common-validation --kubeconfig /tmp/common-kubeconfig \
  --image kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
python scripts/test_common_cluster.py --kubeconfig /tmp/common-kubeconfig --cache /tmp/common-crds --gateway
kind delete cluster --name common-validation
```

Use the pinned node images in `.github/workflows/test-common.yaml` when reproducing
CI. The script refuses contexts outside `kind-common-validation*`. It installs
CRDs and, with `--gateway`, Istio only in that disposable cluster.

Upstream schema URLs and SHA-256 digests live in `schema/vendor/sources.json`.
`python scripts/update_common_schemas.py --cache /tmp/common-crds` reproduces the
committed output snapshots and rejects changed upstream bytes. Vendor snapshots
are excluded from the Helm archive; consumer input schemas are self-contained.

Pull requests run the validation suite. After merge, the main-branch publishing
workflow packages the chart and pushes it with Helm. Chart versions and consumer
dependency pins remain explicit; publish changes under a new chart version.
Registry tag policies are configured and enforced natively in Harbor. The chart
and CI do not create policies, manage robot permissions, or call Harbor's admin API.

## Migrating the storage contract

This is a breaking values change; publish it with a new common chart version.

- Replace `pod.volumes.<name>.type` and flattened fields with the native source
  object. For example, `type: emptyDir, medium: Memory` becomes
  `emptyDir: {medium: Memory}`; `type: custom` becomes its source object directly.
- Move every nested `mounts` entry into the target container's `volumeMounts`
  map. Give it a stable ID and explicit `name` and `mountPath`; there is no
  implicit main-container mount or shared `containers` target list.
- Move inline PVCs into `appResources.pvc`, with `metadata` and `spec`. Preserve
  the old claim name and retention annotations. The optional `component` field
  preserves component-scoped naming and labels; it does not create an implicit
  connection to any Pod volume.
- Replace `ref` and `certRef` with name helper calls in native source fields.
- Move StatefulSet claim settings into `metadata` and `spec`; move its mounts to
  the containers. Keep the existing claim-template keys to preserve claim names.
- Update instance storage overrides to `appResources.pvc.<key>.spec`, regenerate
  consumer schemas and rebuild dependencies when publishing the new version.

## Migrating from alpha.1

- Replace component `service` with `services.main` and `httpRoute` with
  `routes.main`. Replace `appResources.httpRoute` with `appResources.route`.
- Rewrite Service port pruning as explicit selected port maps. Route rules that
  need a default backend must include `backendRefs: [{}]`; choose a port when
  there are several.
- Wrap raw resources in `manifest`, select Cluster scope where applicable, and
  enable `tpl` where previously relied upon.
- Replace cross-file null deletions with disabled entries or component `remove`.
- Regenerate consumer schemas and update the dependency and lockfile to alpha.3.
- Main component selectors now include `app.kubernetes.io/component: main`.
  This is an immutable selector change for existing workloads and requires
  recreation. The legacy migration checker deliberately reports it as different.

The chart favors concise component-local wiring, map-based overlays and a strict
consumer contract. Other common-chart frameworks offer broader established
resource catalogs and deployment history. This implementation is flexible through
native overrides and raw manifests, but its new typed relationships still need
controller-level testing before a stable release.
