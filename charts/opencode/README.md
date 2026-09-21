# OpenCode

Persistent OpenCode v2 server with a private Service and an optional GitHub App
authoring workspace. The chart uses the repository's `common` library. It runs
one non-root server with a read-only root filesystem, a Recreate deployment,
and separate retained state and workspace PVCs. It requires Kubernetes 1.31 or
newer for the native token-renewal sidecar.

## File layout

Chart assets are grouped by the process that uses them:

```text
files/
  bootstrap/
    workspace.sh
  services/
    github/
      github_token.py
      git_credentials.py
```

`bootstrap/` runs before the server starts. The server uses the image's default
entrypoint and arguments. Startup and readiness probes use curl with the password supplied
through the environment. `services/github/` contains the token renewer
and Git credential helper. Common's ConfigMap file mappings preserve these directories under the read-only
`/opt/opencode` mount. GitHub CLI is installed in the image and runs directly from `/usr/bin/gh`.
Workspace setup uses jq for configuration and GNU realpath for path validation.

Add reviewed skills and supporting scripts through
`appResources.configMap.configuration.files`. Python
bytecode caches are excluded from the chart.

## Image and server

The server, workspace init and token sidecar use
`ghcr.io/a-homelab/opencode-container:2.0.11-fb3f5aa`. The reusable
[image repo](https://github.com/a-homelab/opencode-container) uses Debian slim
for separate build and runtime stages. The build stage prepares the standalone
OpenCode binary and Python environment; the runtime installs the agent's Debian
packages and copies those artifacts. Git, GitHub CLI, Python, OpenSSL, Bash,
jq, coreutils and other authoring utilities are installed at build time. Runtime containers do not download
tools during Pod startup. APT remains in the image; the non-root user and
read-only root filesystem prevent changes to system packages. A shared uv
toolkit at `/opt/agent-toolkit` contains locked Python skill dependencies
built into the image. Use `uv run --project /opt/agent-toolkit --no-sync python /path/to/script.py`.
Optional `--with <package>` overlays use the writable `/state/cache/uv` cache;
permanent toolkit changes require an image update.

All containers run as UID/GID 65532 with a read-only root filesystem. There is
no tools init container, tools volume or custom library-path configuration.
Argo CD still renders this chart directly from Git; image publication belongs
to the image repo. `components.main.container.image.tag` selects its readable
OpenCode version and seven-character image-repository commit SHA. The server,
workspace init and token sidecar inherit common's `pullPolicy: IfNotPresent`.
Update the tag to deploy a new image build. For a private
GHCR package, set `components.main.pod.imagePullSecrets` to existing registry
credentials in the deployment namespace.
If migrating an existing UID 1000 deployment, check retained PVC ownership and
write access before switching to UID/GID 65532.

`opencode serve --hostname 0.0.0.0 --port 4096` exposes the HTTP API. The server
also serves OpenCode's browser client; no OpenChamber deployment is required.
Keep routes private and use TLS at the gateway. Set
`components.main.container.env.OPENCODE_PASSWORD.valueFrom.secretKeyRef.name`
to an existing Secret containing a nonempty `password`; validate that value when
provisioning the Secret. Health checks authenticate without embedding credentials
in PodSpec probe arguments. No service-account token is mounted.

The image supplies HOME, XDG directories, uv settings, Python bytecode policy
and the default `/workspace` working directory. The chart inherits these defaults
and provides writable `/state`, `/workspace` and `/tmp` mounts. The state PVC
supplies `/state` as HOME. It includes sessions and any provider credentials saved
through OpenCode. Treat this PVC and its backups as confidential. Mount provider
API keys through a separate Secret using `components.main.container.envFrom` if
using environment-based authentication. OpenCode v2 uses `OPENCODE_PASSWORD`
and the `/api/info` readiness endpoint. Integrations must use the v2 API or
`@opencode/client`, rather than v1 `/session` or `/global/health` contracts.

## Immutable configuration, skills and tools

Deployment configuration is mounted read-only at `/opt/opencode-config`,
with `OPENCODE_CONFIG` selecting its JSON file. The chart leaves
`OPENCODE_CONFIG_DIR` unset so the image's `/opt/opencode-defaults` directory
and baked-in global tools guide remain active.
The agent cannot replace this directory by renaming a writable parent in its home volume.
Project OpenCode configuration overrides are disabled by default with the v2
`OPENCODE_CONFIG_PROJECT_DISABLE` flag. This also disables automatic project
AGENTS.md discovery in v2; the purpose prompt tells the agent to read repository
instructions explicitly. Configuration changes update the pod checksum and
trigger a rollout.

| Values | Mounted content |
| --- | --- |
| `opencode.config` | `opencode.json`, using native v2 fields |
| `opencode.instructions` | Mounted `purpose.md`, loaded as `agents.build.system` |
| `appResources.configMap.configuration.files` | Additional files, such as `skills/`, `plugins/` or `tools/` |

The image's `/opt/opencode-defaults/AGENTS.md` supplies global tool instructions;
the deployment's `/opt/opencode-config/purpose.md` supplies its agent purpose.
OpenCode loads these as separate instruction sources and includes both in model
requests. The Helm mount never replaces the image guide. The
[v2 instruction ordering](https://opencode.ai/v2/docs/instructions#ordering)
describes how agent prompts and global instructions are combined.

For a custom named agent, set `opencode.config.default_agent` and its
`agents.<name>.system` value; use `{file:/opt/opencode-config/purpose.md}` to reuse
`opencode.instructions`. V2 does not load the config `instructions` array.

`appResources.configMap.configuration.files` maps relative paths to entries with
a `content` field for literal text or a `file` field for a chart asset.
Bootstrap scripts are declared explicitly under
`appResources.configMap.bootstrap.files`. Common validates paths, loads chart
files, and generates the ConfigMap keys and volume projections. Both volumes
use `configMap.ref`; content changes feed their existing checksum annotations.
See `examples/immutable-config-values.yaml` for a global skill. Supporting scripts
can live alongside SKILL.md and run through their interpreter, for example
`uv run --project /opt/agent-toolkit --no-sync python
/opt/opencode-config/skills/image-generation/generate.py`.

Add OS tools to the image repo's Dockerfile and shared Python dependencies to
its `toolkit/pyproject.toml` and `toolkit/uv.lock`. Build and test the image,
then update its GitOps image reference. Run independent tool services
in sidecars or external MCP servers. Use ConfigMaps for small reviewed instructions
and tool source, Secrets for credentials, and the workspace PVC for generated outputs.
The agent cannot modify the installed managed toolchain.
ConfigMaps have a 1MiB size limit; they are not package stores.

An image-generation integration can follow this same split: a v2-compatible
plugin or tool in a read-only volume or MCP service, its skill/config in the ConfigMap, and its provider
key in a Secret. No GPT image plugin or model access is assumed by the base
chart. Verify the chosen integration against v2 before enabling it; v1 plugins
use a different API. Self-updates use the native v2 `update: disable` setting.

Read-only files and OpenCode permission rules are additional controls, not a
complete sandbox for an agent that can execute code. Use container, network,
credential and server-side authorization boundaries to enforce access. In
particular, a permission pattern cannot enforce branch restrictions on GitHub.

## Cloning and token renewal

Enable `git.enabled` and configure an ordered `git.repositories` list of
`name`/workspace-relative `path` pairs. List parent repositories before children.
An existing Secret named by `git.existingSecret` must contain:

| Key | Value |
| --- | --- |
| `app-id` | GitHub App ID |
| `installation-id` | Installation ID for `git.owner` |
| `private-key` | App RSA private key in PEM format |

`components.main.sidecars.github-token.native: true` selects the native
sidecar behavior provided by common 1.0.0-alpha.6. Startup runs token renewal
(weight 10), then workspace cloning (weight 20).
The renewer's startup probe must succeed before cloning starts. The renewer
continues running alongside OpenCode; it is the only GitHub sidecar.

The App installation needs Contents write and Pull requests write on the approved
repositories. The renewer explicitly requests those two permissions and scopes
each token to `git.repositories`. Git and GitHub CLI share that token for clone,
fetch, feature-branch pushes and PR operations. The token permits writes to main
unless GitHub branch rules prevent them; configure those rules before deployment.

Only the renewer mounts the App private key. It refreshes the installation token
on a timer, normally every 40 minutes, and atomically replaces the credential
files in a memory volume. The agent and clone containers mount that volume
read-only. Git's credential helper reads `token.json` for every authentication
request, checks expiry, and offers the token only for HTTPS GitHub URLs in the
configured repository list.

GitHub CLI reads its native `gh/hosts.yml` from the same memory volume using
`GH_CONFIG_DIR=/run/github-token/gh`. The renewer writes the token under
`github.com.oauth_token` and a versioned `gh/config.yml` that avoids CLI migration
writes. These files use JSON syntax, which is valid YAML. Each new `gh` process
loads the refreshed credentials. Do not set `GH_TOKEN` or `GITHUB_TOKEN` in the
provider Secret: those variables take precedence over native configuration.

Remotes contain no credentials. No token is persisted in the workspace or
OpenCode state by this integration. A renewal outage retains the last token.
Git rejects it with 60 seconds or less remaining; native GitHub CLI relies on
GitHub to reject an expired token during API requests. `gh auth token` only
reads credentials and does not validate their expiry. Rerun a long-running CLI
command if its token expires after the process starts.

OpenCode can execute code and read the installation token. Restrict the App
installation to approved repos, omit administration/workflow permissions, and
never grant it branch-rule bypass. Keep the App key out of the main container.

The init container clones missing repositories into temporary directories and
publishes complete checkouts by rename. It validates existing checkout paths
and origins and otherwise preserves them, including dirty files, branches,
untracked files and worktrees. It performs no automatic fetch, pull, reset,
clean or branch switching. A failed clone never becomes the final checkout.

For an explicit refresh, inspect `git status`, fetch the desired repo, then
fast-forward a clean main checkout with `git merge --ff-only origin/main`.
If the branch is dirty, ahead, diverged or in use by a task, keep it and create
a new task worktree from the fetched base. Never run a background pull through
an active workspace. Only one task may write a checkout at a time.

## Git and pull requests

Use normal Git and GitHub CLI commands from the target checkout:

```sh
git switch -c opencode/example-task
# Make and review the requested changes, then commit them.
git push --set-upstream origin HEAD
gh pr create --draft --base main --title "Describe the change" --body-file /tmp/pr.md
```

Authentication is automatic; do not run `gh auth login` or export a token into
the long-running OpenCode process. With `git.enabled: false`, `GH_CONFIG_DIR`
points to `/state/config/gh` for normal CLI configuration.

Local commits use `git.author.name` and `git.author.email`. Authentication as the
App identifies the pusher and PR creator; it does not rewrite the author or
committer of locally created Git commits. Follow each target repository's
attribution policy and required Assisted-by trailer with the actual harness/model.
Never add AI co-authors or human sign-offs.

GitHub enforces main-branch protection. Require PRs and human approval, block
force pushes and deletion, and give the App no bypass or administration access.
If only humans may merge, also restrict updates to main to the intended human
maintainers: requiring approval alone still permits a writer to merge an approved
PR. OpenCode permissions and AGENTS.md instructions are additional guidance, not
the enforcement boundary. Private personal repos need GitHub Pro; private
organization repos need GitHub Team or another qualifying plan. The chart does
not purchase a plan or configure these rules.

There is no GitHub MCP container, socket bridge, custom publisher or Git MCP
server. Other integrations remain in `opencode.config.mcp.servers`, including
Blender in the GitOps deployment.

## Routes and rollout

The chart defaults to ClusterIP only. Enable `components.main.routes.main` with
Gateway API hostnames and parentRefs for the deployment. Request timeouts are
disabled on the route to accommodate event streams. Gateway-level idle limits
still need to support long-lived connections.

If the namespace injects a classic Istio sidecar, the token/clone init containers
may lack egress before that proxy starts. Disable injection on this authoring
pod, or use a verified native-sidecar mesh setup. This chart does not install
mesh policy, DNS records, provider credentials or GitHub branch rules.

Retain and back up state/workspace PVCs before upgrades. Test session recovery
and unfinished worktree recovery after restarts. Applying Secrets, Argo sync
and checking actual ingress/provider/MCP access are separate
deployment steps; a successful Helm render does not establish deployment.

## Validation

```sh
mkdir -p charts/opencode/charts
helm package charts/common --destination charts/opencode/charts
python scripts/common_schema.py charts/opencode --extensions charts/opencode/schema/extensions.json --check
helm lint charts/opencode --strict
python -m pytest charts/opencode/tests -q
shellcheck charts/opencode/files/bootstrap/*.sh
python charts/opencode/tests/smoke_image.py
```

The normal chart CI runs render, isolation, clone preservation and credential
tests. ShellCheck covers the workspace bootstrap script. The
optional Docker smoke test runs the image with the real chart scripts as
non-root with a read-only root filesystem and configuration, checks authenticated health,
sessions, the mounted purpose prompt, image environment defaults, offline uv
toolkit, skills and HTTPS Git, and rejects unauthenticated sessions and writes
to managed files. A local mock provider captures a model request and verifies
that both the image tools guide and deployment purpose are included, without
using real provider credentials or making a paid model request. It rotates
disposable fake tokens and verifies both Git and GitHub CLI read the replacement. It also verifies Git rejects
expired tokens and GitHub CLI fails when its credentials are missing.
It does not test live App permissions or branch-rule enforcement. It requires
Docker and network access and creates no image or remote Git changes.

Sources: [GitHub CLI environment configuration](https://cli.github.com/manual/gh_help_environment),
[OpenCode v2](https://opencode.ai/v2/docs),
[v2 configuration](https://opencode.ai/v2/docs/config),
[v2 API](https://opencode.ai/v2/docs/api),
[runtime image](https://github.com/a-homelab/opencode-container),
[GitHub App installation authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation),
[GitHub branch protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).
