# Blender

A LinuxServer Blender desktop built with the `common` library chart. The chart
contains no house data or application-specific modeling behavior.

`templates/all.yaml` only calls `common.all`. Values define the bootstrap
ConfigMap, init container, volumes and rollout checksum. The init container
inherits the main container's image. The schema extension enforces the single
writer Deployment settings and validates MCP pins when enabled.

## Installation

```sh
helm dependency build charts/blender
helm upgrade --install blender charts/blender --namespace blender --create-namespace
```

The defaults use Blender 4.5.3 LTS, LinuxServer build `4.5.3-ls192`, pinned by
multi-platform image digest. This is a compatibility baseline, not a claim that
it is the newest release. Review image and addon compatibility before upgrades.
The pinned ARM image may contain a different Blender version; verify it separately.

The chart creates a single Deployment with `Recreate`, a 10 GiB `/config` PVC,
a 50 GiB `/workspace` PVC, and a 1 GiB memory-backed `/dev/shm`. Config and workspace
claims are retained on Helm uninstall and Argo CD deletion/pruning. Back them up
separately; retention is not a backup. Claim sizes and storage classes are configured under
`appResources.pvc.<name>.spec.resources.requests.storage` and
`appResources.pvc.<name>.spec.storageClassName`.

The HTTP service on port 3000 is for a TLS-terminating, authenticated reverse proxy.
Port 3001 provides the container's self-signed HTTPS endpoint for a private tunnel.
No HTTPRoute is enabled by default. The desktop provides code execution and must not
be published without authentication. Desktop readiness does not prove Blender or MCP
health. There is deliberately no liveness restart tied to a busy Blender process.

## NVIDIA

`examples/nvidia-values.yaml` demonstrates the GPU settings. Copy and adapt them
into your application's own values override; deployed instances should own their
runtime class, resource allocation and scheduling settings. To render the example:

```sh
helm template blender charts/blender \
  --namespace blender \
  -f charts/blender/examples/nvidia-values.yaml
```

The example selects `runtimeClassName: nvidia`, requests and limits one
`nvidia.com/gpu`, and requests compute, utility, graphics, video and display driver
capabilities. It leaves device selection to the NVIDIA device plugin. Override the
runtime class for clusters using a different handler. Node selection and tolerations
remain normal `components.main.pod` settings. CPU installations omit these overrides.

Do not set `NVIDIA_VISIBLE_DEVICES=all`: the allocated device must come from the
device plugin. With NVIDIA time slicing, one allocation is a shared slot, not an
exclusive GPU or a reserved fraction of GPU memory. Avoid parallel heavy renders
until memory use is measured. No host device mounts or privileged pod are enabled.

An accelerated desktop is not proof of Cycles GPU rendering. Test CUDA and OptiX
explicitly against the actual host driver and pinned image:

```sh
kubectl exec -n blender deploy/blender -c main -- blender \
  --background --factory-startup --python-exit-code 1 \
  --python /opt/blender-bootstrap/verify_gpu.py -- --backend CUDA
```

Repeat with `--backend OPTIX`. The script disables CPU devices, requires a matching
GPU, and renders a small PNG. Failure returns a nonzero exit code; it never silently
accepts CPU rendering. It uses the factory scene and does not open the user's model.

## Optional Blender MCP addon

Set `mcp.enabled: true`. The init container downloads `addon.py` at the exact
`mcp.revision`, verifies `mcp.sha256`, and caches the verified bytes under `/config`.
Subsequent starts reuse that cache without network access. A cache miss requires
outbound HTTPS to `raw.githubusercontent.com`. A mismatch fails startup.

The addon is staged outside persistent user preferences and enabled by a startup
module for interactive Blender only. It starts on loopback port 9876. The chart
does not expose that port through a Service or HTTPRoute. Background render processes
do not load the bridge. The user-scripts directory is an emptyDir mounted in both
containers; it stays empty when MCP is disabled. A bootstrap checksum rolls the
pod when the rendered ConfigMap changes. MCP settings are init-container
environment values, so changing them also updates the pod template.

Run the matching MCP server on the agent's machine and tunnel to the pod:

```sh
kubectl port-forward -n blender deployment/blender 9876:9876
```

The agent's stdio MCP command is:

```sh
uvx --python 3.11 \
  --from git+https://github.com/ahujasid/blender-mcp.git@5f8ddaf6e987c4aa0c3467fcc548838b28f64477 \
  blender-mcp
```

Set `BLENDER_HOST=127.0.0.1` and `BLENDER_PORT=9876` in the agent environment.
Port forwarding must be re-established after pod replacement. One author controls
the workspace at a time; this generic chart does not implement an application edit
lease or protect against two independently authorized agents editing concurrently.

The addon is third-party MIT-licensed code from `ahujasid/blender-mcp`, not an
official Blender Foundation addon. Its socket permits Python execution. Only trusted
authors should receive tunnel access. It is distinct from the MCP stdio server.

## Validation

```sh
helm lint charts/blender --strict
uv run --project ~/.agents/toolkit pytest charts/blender/tests
```

Before promoting a new image/addon pair, verify scene inspection, a disposable model
save/export, container restart, reopening that saved model, and both GPU backend checks.
The chart tests validate manifests; they do not establish runtime compatibility.

Sources: [LinuxServer Blender](https://docs.linuxserver.io/images/docker-blender/),
[Blender MCP](https://github.com/ahujasid/blender-mcp).
