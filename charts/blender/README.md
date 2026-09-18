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

The defaults use Blender 5.2.2 LTS, LinuxServer build `5.2.2-ls240`, with a
readable version tag. The official Blender Lab MCP extension is version `1.0.3`
and requires Blender 5.1 or newer. The amd64 image is the validation target;
verify ARM installations separately.

The chart creates a single Deployment with `Recreate`, a 10 GiB `/config` PVC,
a 50 GiB `/workspace` PVC, and a 1 GiB memory-backed `/dev/shm`. Config and workspace
claims are retained on Helm uninstall and Argo CD deletion/pruning. Back them up
separately; retention is not a backup. Claim sizes and storage classes are configured under
`appResources.pvc.<name>.spec`; each container declares its own `volumeMounts`.

The HTTP service on port 3000 is for a TLS-terminating, authenticated reverse proxy.
Port 3001 provides the container's self-signed HTTPS endpoint for a private tunnel.
No HTTPRoute is enabled by default. The desktop provides code execution and must not
be published without authentication. Desktop readiness does not prove Blender or MCP
health. There is deliberately no liveness restart tied to a busy Blender process.

## NVIDIA

`examples/nvidia-values.yaml` demonstrates the GPU settings. Copy and adapt them
into your application's own values override; deployed instances should own their
resource allocation and scheduling settings. To render the example:

```sh
helm template blender charts/blender \
  --namespace blender \
  -f charts/blender/examples/nvidia-values.yaml
```

The example requests and limits one `nvidia.com/gpu` and requests compute,
utility, graphics, video and display driver capabilities. It leaves device
selection to the NVIDIA device plugin. With native CDI, no explicit RuntimeClass
is needed. For clusters using the legacy NVIDIA runtime, set
`components.main.pod.runtimeClassName: nvidia`. Node selection and tolerations
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

Set `mcp.enabled: true`. The init container downloads the official Blender Lab
`mcp-<version>.zip` release selected by `mcp.version`, verifies `mcp.sha256`, and
caches the verified archive under `/config`. Subsequent starts reuse that cache
without network access. A cache miss requires outbound HTTPS to
`projects.blender.org`. A mismatch fails startup.

The chart maintains `mcp.version` and `mcp.sha256` as a pair. To get the checksum
for an upgrade, run this from the Blender chart directory:

```sh
./scripts/mcp-sha256.sh 1.0.3
```

The script downloads the official extension ZIP and prints only its SHA-256.
Set `mcp.version` to the requested version and `mcp.sha256` to that output in
`values.yaml`. Enabling MCP with the chart defaults needs no checksum override.

The extension is staged in a local system repository outside persistent user
preferences and enabled by a startup module for interactive Blender only.
Enabling MCP also enables Blender's online-access preference,
which the official addon requires even for loopback connections. The bridge binds
`127.0.0.1:9876`; no Service or HTTPRoute exposes it. Background render processes
do not start the bridge. The user-scripts directory is an emptyDir mounted in both
containers and stays empty when MCP is disabled. A bootstrap checksum rolls the
pod when the rendered ConfigMap changes. MCP settings are init-container
environment values, so changing them also updates the pod template.

Run the matching MCP server on the agent's machine and tunnel to the pod:

```sh
kubectl port-forward -n blender deployment/blender 9876:9876
```

The agent's stdio MCP command is:

```sh
uvx --python 3.11 \
  --from 'git+https://projects.blender.org/lab/blender_mcp.git@v1.0.3#subdirectory=mcp' \
  blender-mcp --transport stdio
```

Set `BLENDER_MCP_HOST=127.0.0.1` and `BLENDER_MCP_PORT=9876` in the agent environment.
Use the Git source explicitly: the PyPI name `blender-mcp` is also used by the
unrelated third-party implementation. The previous `mcp.revision`,
`BLENDER_HOST`, and `BLENDER_PORT` settings no longer apply.

Tools that operate on the connected interactive Blender session use the tunnel.
The official server's command-line tools launch Blender on the MCP server's own
machine and require access to the relevant files there; port forwarding does not
provide a local Blender binary or share `/workspace`. Use the connected-session
tools for the remote authoring workspace.

Port forwarding must be re-established after pod replacement. One author controls
the workspace at a time; this generic chart does not implement an application edit
lease or protect against two independently authorized agents editing concurrently.
The official addon is GPL-3.0-or-later code from Blender Lab. Its socket permits
Python execution; only trusted authors should receive tunnel access.

## Validation

```sh
helm lint charts/blender --strict
uv run --project ~/.agents/toolkit pytest charts/blender/tests
```

Before promoting a new image/addon pair, verify scene inspection, a disposable model
save/export, container restart, reopening that saved model, and both GPU backend checks.
The chart tests validate manifests; they do not establish runtime compatibility.

### Verification on 2026-09-18

Helm lint, the generated values schema check, all 14 chart/bootstrap tests, and
schema validation of the seven Mi Casa resources passed. The amd64
`5.2.2-ls240` image started the official `1.0.3` extension in a disposable
software-rendered X11 desktop. A real stdio MCP client listed 26 tools, inspected
the scene, created an object, saved a `.blend`, and exported a GLB. After a
container restart without network access, the addon reused its verified cache,
and MCP reopened the saved object with its expected coordinates. A background
Blender process did not start a second MCP bridge.

These tests used isolated local volumes and a software display. They do not
validate the cluster's NVIDIA desktop, CUDA/OptiX backends, Ceph PVC recovery, or
browser authentication; run those checks before deploying the authoring instance.

Sources: [LinuxServer Blender](https://docs.linuxserver.io/images/docker-blender/),
[Blender Lab MCP](https://projects.blender.org/lab/blender_mcp),
[official setup](https://www.blender.org/lab/mcp-server/).
