# Alpha.2 design review follow-up

The review of PR #1 found useful ergonomics in the component model, but also
rendering and validation gaps. This revision addresses those gaps before the
consumer contract settles. It remains an alpha. Validation now includes offline schemas, real API-server
admission and an Istio Gateway traffic test.

## Comparison with other approaches

| Approach | Comparison |
| --- | --- |
| [bjw-s Common/App Template](https://bjw-s-labs.github.io/helm-charts/docs/app-template/) | An established values-driven application framework. This chart groups a workload's Services, routes and listeners beside its containers, derives port wiring and colocates volume definitions with mounts. That reduces references for conventional apps. Both expose typed monitoring and policy resources; bjw-s has a longer-established ecosystem. |
| [HULL](https://github.com/vidispine/hull) | A strong reference for native Kubernetes coverage through values and schemas. Common's component grouping is more concise for a conventional workload bundle; HULL's object-oriented interface exposes more API structure directly. |
| [Bitnami Common](https://github.com/bitnami/charts/tree/main/bitnami/common) | A helper library for consumer templates. Common's whole-application renderer removes more consumer template boilerplate. These are different levels of abstraction. |
| [Bedag raw](https://github.com/bedag/helm-charts/tree/master/charts/raw) | Raw manifests already provide broad expressiveness. Common adds named overlay identities and managed workload relationships; that is its practical benefit, rather than a unique ability to deploy arbitrary containers. |

The strongest advantages here are local organization, component-shaped defaults,
explicit shared-resource ownership, derived wiring, and per-container overrides
before containers become native lists. None establishes universal superiority.
The upstream projects were compared through their documentation and source, not
through a deployment benchmark.

## Confirmed findings addressed

| Finding | Result |
| --- | --- |
| Explicit zero/false values were reset or omitted. | Presence-aware rendering preserves replicas, Job settings, PDB budgets, file modes and boolean options. |
| Null deletion could be lost during Helm coalescing. | Component `remove` survives coalescing; `enabled: false` disables resources. Documentation distinguishes surviving null tombstones from reliable cross-file removal. |
| Nested tombstones crashed reads or leaked into manifests. | Null-safe resolution and cleanup at typed emission; required resolved values have runtime guards. Literal raw YAML preserves explicit nulls across Helm versions. |
| Env/container weights were ignored, and env object values leaked native numbers. | Ordered map conversion is used at container/env/port boundaries; env values become strings. |
| Schema validation was optional, remote-dependent, and inconsistent with overlays. | Offline bundled schemas, strict consumer root schemas, extension composition, partial input types and native output checks. |
| User pod labels could break workload/Service selectors. | Component identity includes main; conflicting pod/controller/Service selectors fail. |
| Long names and overrides could collide. | Hashed generated names and duplicate final identity detection; invalid Service and CronJob name constraints are checked. |
| Managed references could point to disabled or renamed resources. | Managed references check availability; Service ports and names resolve from final manifests; app resource and certificate Secret names follow overrides. Mount targets, container names and final named Service targets are checked. |
| Supporting resources were unnecessarily singular. | Named `services`, `routes` and `listenerSets`; shared route/ListenerSet equivalents. Main can coexist with sibling components. |
| Legitimate Service/route forms were excluded. | Explicit selected ports, numeric target ports, portless ExternalName Services, redirect-only rules, repeated Gateway parents and native sidecar ports. |
| Inline claims ignored overrides and partial sidecar images were discarded. | PVC/claim-template overrides apply, with identity protection; partial images and all-container defaults inherit correctly. |
| Raw resources lost documents, assumed namespace and always evaluated templates. | Explicit one-document manifest entries, Cluster scope and opt-in templates. |
| The merge silently stopped after 1,000 frames. | Recursive merge has no fixed frame queue; a 1,100-entry regression exercises the former failure. |
| Checksums could miss changes to templated config. | The checksum helper hashes rendered ConfigMap data. |
| Per-component entrypoints lacked a shared-resource counterpart. | `common.resources` emits app/raw resources once. |
| Migration normalization hid meaningful empty objects. | Only known metadata/container-resource empties are normalized; removal of `emptyDir: {}` remains a real difference. |
| Stable publishing depended only on lint. | Publication depends on the shared validation workflow. The breaking chart receives a new alpha.2 version and consumers pin it. |

## Additional gaps closed

- Named RBAC roles/bindings, NetworkPolicies and ServiceMonitor/PodMonitor maps,
  with component/service-account/service/peer relationships and native options.
- Shared Gateway and ReferenceGrant resources with explicitly owned permissions.
- Complete built-in output schemas across Kubernetes 1.31-1.37, exact API-version
  matching, bundled Certificate/ExternalSecret/monitoring schemas, and a public
  validator for final manifests with custom CRD/schema registration.
- Checksum-locked upstream sources and a reproducible snapshot updater.
- API-server admission on Kubernetes 1.31, 1.36 and 1.37, covering all five workload
  kinds, supporting resources, and invalid native/CEL cases.
- Istio 1.31 traffic through direct and ListenerSet routes, named Service backend
  resolution, unauthorized ListenerSet rejection, cross-namespace ReferenceGrant enforcement and RBAC permission checks.
- Main-branch publication depends on the full validation suite and uses ordinary
  Helm package/push commands. Harbor owns native tag-policy enforcement.

## Platform boundaries

- Overrides and raw resources remain intentional extension points. Their final
  output must pass the matching output schemas; arbitrary custom APIs require
  an installed CRD and a supplied output schema. A universal chart cannot ship
  every organization's private CRDs.
- JSON Schema does not execute CEL, webhook logic or controllers. The committed
  live suite covers the pinned Kubernetes/Istio combination; other controllers,
  CNIs and operators need runtime checks for their particular features. Typed
  NetworkPolicy and monitoring output does not install a CNI or Prometheus.
- Gateway/ListenerSet attachment and cross-namespace access require the resource
  owner's explicit permission. Typed helpers can express that permission, but
  should not silently grant it on an application's behalf.
- Workload selector changes require recreation of preexisting controllers. Helm
  coalesces structured nulls before templates run; component `remove` and literal
  raw manifests preserve deletion intent and literal nulls respectively.

Consumer updates cover Blender, Mi Casa and Mi Casa Shared, plus the Blender
GitOps values. The older application charts still depend on the legacy library;
their values-v2 files are migration examples, not silently upgraded deployments.

## Verification

- 80 Helm unit tests pass.
- 69 common integration tests pass with both Helm 3.22.0 and 4.3.0.
- Seven Blender tests and seven consumer render scenarios pass; migration
  examples are included in the common integration suite.
- Kubernetes 1.31.9, 1.36.4 and 1.37.0 admit all five workload kinds and the
  supporting-resource fixture, and reject the invalid native/CEL cases.
- Istio 1.31.0 passes direct/ListenerSet HTTP traffic, named backend, RBAC,
  forbidden ListenerSet and cross-namespace ReferenceGrant tests.
- Helm lint and workflow actionlint pass.
- Checksum-locked output snapshots reproduce, and generated consumer schemas
  match the canonical input contract.
