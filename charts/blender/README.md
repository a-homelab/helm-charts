# Blender

A LinuxServer Blender desktop built with the `common` library chart. The chart
contains no house data or application-specific modeling behavior.

`templates/all.yaml` calls `common.all`; values select the optional MCP sidecar.
Values define the containers, bootstrap ConfigMap, volumes and rollout checksum.
The init container and MCP sidecar inherit the main container's image. The schema extension enforces the single
writer Deployment settings, validates MCP pins when enabled, and requires MCP for its route.
Common's conditional entries bind the MCP sidecar and temporary volume to
`mcp.enabled`. Its typed templates keep the sidecar UID/GID aligned with the
desktop's `PUID`/`PGID`; no chart-specific template logic is needed.

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

## Optional Blender MCP addon and server

Set `mcp.enabled: true` to enable both the addon and HTTP server sidecar.
The init container downloads the official Blender Lab
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

One author controls the workspace at a time; this generic chart does not implement
an application edit lease or protect against concurrent agent edits. The official
addon is GPL-3.0-or-later code from Blender Lab. MCP permits Python execution;
only trusted authors should receive access.

## HTTP MCP sidecar

`mcp.enabled` controls the addon, server bootstrap and sidecar together. It defaults
to `false`. The former `mcp.server.enabled` setting is removed; delete it from
existing values. Gateway routing remains a separate opt-in:

```yaml
mcp:
  enabled: true
components:
  main:
    routes:
      mcp:
        enabled: true
        hostnames: [blender-mcp.example.com]
        parentRefs:
          internal-gateway:
            namespace: istio-system
            sectionName: https
```

Without a route, the MCP server is available on Service port 8000. For local access:

```sh
kubectl port-forward -n blender deployment/blender 8000:8000
```

Connect the agent's HTTP MCP client to `http://127.0.0.1:8000/`.
Re-establish port forwarding after pod replacement.

The sidecar inherits `components.main.container.image` through `helm-common`.
It overrides the LinuxServer entrypoint with `files/mcp-server/start_server.py`,
which starts `blender-mcp --transport http --host 0.0.0.0 --port 8000` from the
pinned official Blender Lab release. There is no custom image to build or publish. No custom server code, authentication, tool filtering, or
health endpoints are added. The internal gateway owns access control.

The HTTPRoute forwards `/` to port 8000 and allows 350 seconds for the backend,
exceeding the connected addon's 300-second socket timeout. Startup and readiness
use TCP probes. These check the MCP listener, not the addon connection. There is
no liveness restart tied to a busy Blender operation. After a mutation timeout,
inspect the scene before retrying; the operation may have completed.

All 26 official tools remain available. The six `_for_cli` tools launch a separate
`blender --background` process inside the sidecar, using the same upstream Blender
image as the authoring container. Both containers mount `/workspace` at the same path; keep referenced
scene assets there. The sidecar also mounts writable temporary storage at `/tmp`.
It receives no GPU allocation, so CLI rendering is CPU-based. Connected-session
tools execute in the GPU-enabled authoring container. Configure resources under
`components.main.sidecars.mcp` for the expected CLI workload.

### Persistent server environment

`prepare.sh` handles directories, ownership, downloads, SHA-256 verification,
virtualenv creation and pip. The image has no `unzip`, so a short inline Python
block validates ZIP paths and extracts the addon using the standard library.

The prepare init container runs `prepare.sh`, which creates the MCP virtualenv under
`/config/blender-mcp-server/environments/<environment-key>` on the existing config
PVC. It uses the Blender image's Python and pip to install `requirements.txt`.
That file declares only the official Blender MCP Git reference; pip resolves and
installs its dependencies. No uv installation or custom image is needed. Pip
checks the installed dependencies and imports the server before marking the
environment ready.

Only prepare installs dependencies. After successful verification, it atomically
points `/config/blender-mcp-server/current` at the ready environment.
`start_server.py` only executes that environment's `blender-mcp` HTTP server.
Kubernetes completes prepare before starting either the desktop or sidecar.
The sidecar runs as the configured `PUID`/`PGID` with a read-only root filesystem;
it needs read/execute access to the prepared environment, not package-install access.

Environments are keyed by the image reference, LinuxServer build ID, Python
version/path, CPU architecture, requirements and prepare script. An unchanged
pod restart reuses the ready environment without dependency installation or
network access. An image, requirements or prepare-script change creates a new
environment; a partial installation is rebuilt on retry. The current pointer
changes only after success. Previous environments remain available for rollback.

Pip's download/build cache also lives on the PVC. First installation and changed
environments may require HTTPS access to PyPI, its package CDN and
`projects.blender.org`; the cache is not a complete offline installation bundle.
Monitor config-PVC capacity and remove obsolete environments during maintenance.
Older uv-based caches are unused by this bootstrap and are not deleted automatically.
The server source is pinned, but its transitive dependencies are not: newly built
environments may resolve newer compatible versions. Existing ready environments
are reused without upgrades.

Bump Blender in `components.main.container.image` only. Keep the server source
pin and addon version/checksum aligned when upgrading MCP. Review and test the
resolved dependencies when the image changes Python versions.

Keep the official source reference in `files/mcp-server/requirements.txt` aligned
with the addon release. After dependency changes, verify `pip check`, MCP tool
listing and a background Blender call in the prepared environment.

## Validation

```sh
helm lint charts/blender --strict
uv run --project ~/.agents/toolkit pytest charts/blender/tests
```

Before promoting a new image/addon pair, verify scene inspection, a disposable model
save/export, container restart, reopening that saved model, and both GPU backend checks.
Run `shellcheck charts/blender/files/prepare.sh` for the init entrypoint.
The chart tests validate manifests; they do not establish runtime compatibility.

### Shell init and pip virtualenv verification on 2026-09-18

All 26 chart/bootstrap tests passed on Helm 3.22.0 and 4.3.0, along with strict
Helm lint, schema freshness, ShellCheck and the server's Ruff checks. The shell
checks cover checksum rejection, archive traversal, disabled MCP, environment
reuse, changed inputs, and interrupted installation recovery.

The rendered bootstrap ConfigMap completed a fresh addon download and pip install
inside `5.2.2-ls240` with a 1 GiB memory limit. A replacement init with networking
disabled reused the addon cache and ready virtualenv. A separate container running
as UID/GID 1000, with networking disabled and read-only config/root filesystems,
launched `start_server.py`, listed all 26 tools and executed a background Blender
CLI call. No package installation occurs in the server launcher.

Evidence is under `/tmp/blender-shell-validation/`. These checks did not change
cluster resources or re-test the interactive GPU desktop.

### Historical uv-based inherited-image verification on 2026-09-18

The sidecar and authoring desktop now use the same upstream LinuxServer image.
All 23 chart/bootstrap tests, Helm lint, strict runtime-project Ruff checks,
lockfile freshness, values-schema checks, and offline validation of the eight
rendered Mi Casa resources passed.

A cold-started sidecar exposed all 26 tools and executed a background Blender
call. Replacing it with networking disabled reused the completed environment
without changing its ready marker. Changing the image identity created a separate
environment entirely from cached dependencies; this tests invalidation, not
compatibility with a different Blender release. A disposable desktop/sidecar pair
also passed connected save/export, shared-workspace CLI reads, and offline
restart/reopen using the same persisted config directory.

Raw local evidence is under `/tmp/blender-mcp-persistent/` and
`/tmp/blender-mcp-persistent-integration/`. No custom image was built or published,
and no cluster resources changed. Cluster GPU behavior, gateway access, and
production PVC replacement remain deployment checks.

### Historical custom-image sidecar verification on 2026-09-18

The direct upstream server exposes all 26 tools. The standalone image passed an
HTTP/CLI smoke test; an isolated desktop/sidecar pair also passed connected tool
calls, save/export, shared-workspace CLI reads, and offline restart/reopen. All 18
chart/bootstrap tests, Helm lint, schema checks, and Kubernetes server-side dry
runs of the eight resources passed. No image was published or cluster resources
changed. Gateway reachability and cluster GPU behavior remain deployment checks.
Raw local evidence is under `/tmp/blender-mcp-simplify/`.

### Prior addon-only verification on 2026-09-18

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
