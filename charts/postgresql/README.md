# PostgreSQL

One CloudNativePG Cluster per release, with optional declarative Database and
DatabaseRole resources, cert-manager TLS, Ceph bucket provisioning, Barman Cloud
plugin backups, scheduled backups, generated/recovered credentials, optional
superuser client certificates, and a chart-owned PodMonitor.

## Compatibility contract

Version 0.2.0 preserves the resource identities and specs rendered by 0.1.0 for
existing homelab values. New behavior requires an explicit opt-in. The old keys
remain supported, including `databaseName`, `clientUsername`, `storageSize`,
`storageClass`, `initdb`, `certificateIssuerRef`, and `backup.storageClassName`.
Existing image pins, bootstrap SQL, credentials, certificates, storage,
in-tree WAL archiving, and operator-owned monitoring remain unchanged.

The resource-level `helm.sh/chart` label reports the new chart version. Legacy
pod labels and topology selectors deliberately retain `postgresql-0.1.0`:
changing that selector triggers CNPG rolling updates. Set
`scheduling.topologySpreadSelector: stable` to adopt `cnpg.io/cluster` during a
maintenance window. Subsequent chart releases then do not affect that selector.

Old and new settings can coexist. Explicit new settings take precedence:

| New setting | Legacy setting it replaces |
| --- | --- |
| `instances` | `replicaCount` when non-null |
| `postgresql` | The whole `postgresqlConfig` object when non-null; `{}` clears it |
| `credentials.existing.userSecretName` | `userCredsSecretName` when the nested field is present |
| `credentials.existing.superuserSecretName` | `superuserCredsSecretName` when present; `""` clears the reference |
| `backup.objectBucket.storageClassName` | `backup.storageClassName` when present |
| `database.localeCType`, `database.localeCollate` | Corresponding `initdb` locales when present; also feed the Database CR |
| `credentials.mode: generated` or `copy` | Legacy credential Secret references; explicit migration required |
| `tls.issuerRef` | TLS profile issuer and `certificateIssuerRef` when nonempty |
| `tls.profile: cnpg` | Legacy issuer fallback; defaults to `cnpg-ca` |
| `database.name`, `database.owner` | `databaseName`, `clientUsername` when nonempty |
| `storage` fields | Corresponding `storageSize` and `storageClass` fields |
| `bootstrap` | The complete generated `bootstrap.initdb` when nonempty |
| `imageCatalogRef` | `image.repository` and `image.tag` |
| `databaseRoles` entries | Inline `managed.roles` entries with the same SQL role name |
| `backup.configuration` | The entire generated Ceph Barman configuration when nonempty |

[examples/compatible-keys.yaml](examples/compatible-keys.yaml) renders exactly the
same resources as the legacy example using the preferred keys. Migrate names by
first adding new keys with the same effective values, compare the complete render,
then remove old keys later. The chart does not infer a feature opt-in from a key
rename: nested existing credentials still use the same SealedSecrets, and an
explicit legacy issuer still issues the same certificates. Keep values valid in
both syntaxes while they coexist; schema validation applies to both.

For homelab consumers, put the preferred keys in a commented migration block in
the existing values file. No additional values file or Application source change
is needed. Keep legacy aliases during adoption, then consolidate the file after
verification. Update the preferred keys in the block when both forms exist: editing
only a legacy alias will not change its effective value. Never repeat the same YAML
mapping key in two blocks; merge fields into the existing mapping when necessary.

`credentials.existing` only applies in existing mode. Generated/copy modes select
their own target names. A nonempty native `bootstrap` still replaces the entire
chart-built initdb object, including its credential reference and locale fields;
copy mode intentionally supplies its recovery credential reference. Locale fields
are creation-time settings, not a way to change an existing database's collation.

Changing a value does not migrate database contents. In particular, new database
names do not rename an existing database, bootstrap does not restore an existing
Cluster, and changing a PostgreSQL major image is not an upgrade procedure.
Keep identities unchanged when first adopting the new keys.

`clusterSpec` accepts additional native Cluster.spec fields such as `walStorage`,
`probes`, `tablespaces`, `serviceAccountTemplate`, `replica`, `podSelectorRefs`, or
`primaryLease`. It rejects fields already managed by the chart because overriding
them independently could disconnect the certificates, backup resources, or
database references. Use the dedicated chart keys for those fields.

## Values shape compared with Netail

Feature parity does not make the two values files interchangeable. The comparison
uses Netail commit `97e4f079366331422c5376854b3213d87af7f9e7`. Prefer native CNPG
objects where they avoid a second chart-specific model; retain chart-level keys
for resources that the chart coordinates.

| Netail setting | Preferred homelab setting | Difference |
| --- | --- | --- |
| `database.name`, `owner`, locales, extensions | Same `database` fields | Locales also override generated initdb settings; CR remains opt-in |
| `replicaCount` | `instances` | Native CNPG naming; old name remains supported |
| `postgresqlConfig` | `postgresql` | Native CNPG object, including parameters and pg_hba; old name remains supported |
| `storageSize`, `storageClass` | `storage.size`, `storage.storageClass` | Native StorageConfiguration allows additional settings |
| `certificateIssuerRef` | `tls.issuerRef` or `tls.profile: cnpg` | Explicit override plus operator/external TLS modes |
| `externalSecrets.passwordGenerator.excludeSymbols` | `credentials.password.symbols: 0` | Full Password generator settings, credential modes, and rotation controls |
| `walArchiving.enabled` | `backup.provider: plugin` | Explicit backend selection also preserves in-tree backups during migration |
| `walArchiving.destinationPath`, `wal`, `data` | `backup.configuration.destinationPath`, `wal`, `data` | Complete native Barman configuration, including non-AWS credentials/endpoints |
| `walArchiving.retentionPolicy`, `sidecar` | `backup.retentionPolicy`, `backup.objectStore.instanceSidecarConfiguration` | Plugin settings grouped with backups |
| `backup.enabled`, `schedule`, `method`, `immediate` | Corresponding fields under `backup.scheduled` | Separate schedule from archive configuration; snapshots supported |
| `mode: recovery`, `recovery.source`, `recoveryTarget` | `bootstrap.recovery` plus `externalClusters` | Native recovery supports more source/target forms; no wrapper mode |
| Recovery credential copy inferred from source serverName | `credentials.mode: copy` plus explicit source Secret names | Archive identity and credential identity are independent |
| `computeClass` | `affinity` and `topologySpreadConstraints` | No estate-specific Karpenter node/taint assumptions |
| PushSecret/KMS settings under `externalSecrets` | Not implemented by request | SealedSecret compatibility and generation do not imply external escrow |

Homelab also exposes `databases`, `databaseRoles`, `managed`, `imageCatalogRef`,
`clusterSpec`, and monitoring options. Do not copy Netail's image, replica, storage,
checksum, backup, credential-generation, or issuer defaults onto existing clusters
as part of a naming cleanup. The preferred schema and changing runtime behavior
are separate migrations.

## Feature prerequisites

Install the operator and relevant CRDs before enabling resources. This chart
does not install or upgrade operators. Helm rendering intentionally does not
depend on API discovery, so Argo CD and offline Helm render the same manifests.

| Feature | Prerequisite |
| --- | --- |
| `database.enabled`, `databases` | CNPG Database CRD; examples validated against 1.28.1 and 1.30.1 |
| `managed.roles` | CNPG inline role management; available on the existing operator |
| `databaseRoles` | CNPG 1.30+ DatabaseRole CRD |
| `backup.provider: plugin` | Barman Cloud plugin and ObjectStore CRD; schemas validated against 0.15.1 |
| `backup.scheduled.method: volumeSnapshot` | Snapshot controller, CRDs, and a compatible CSI snapshot class |
| `monitoring.mode: podMonitor` | Prometheus Operator PodMonitor CRD and a matching Prometheus selector |
| `credentials.mode: generated` | ESO ExternalSecret v1 and Password v1alpha1 CRDs; validated against ESO 2.11.0 |
| `credentials.mode: copy` | ESO SecretStore/ExternalSecret v1; source Secrets available in this namespace |
| `tls.profile: cnpg` | Ready `cnpg-ca` ClusterIssuer from homelab cert-issuers; clients trust cluster-local root |
| `tls.mode: certManager` | cert-manager and the configured issuer, whose Secrets contain `ca.crt` |

The live homelab was CNPG 1.28.1 on Kubernetes 1.31.14 during the
[2026-10-01 review](docs/2026-10-01-review.md). It had neither ObjectStore nor
DatabaseRole CRDs. CNPG 1.30 supports Kubernetes 1.34-1.36; 1.31 is tested but
unsupported. Latest feature availability is separate from a supported platform
upgrade. See the [upstream support matrix](https://cloudnative-pg.io/docs/1.30/supported_releases/).

## Declarative databases and roles

[examples/declarative.yaml](examples/declarative.yaml) uses capabilities present
on the installed CNPG version. `database.enabled` manages the bootstrap database
as `<cluster>-app`. `databases` maps stable Kubernetes suffixes to native
Database.spec objects. For example, `databases.visibility.name: temporal_visibility`
creates a CR named `<cluster>-visibility`, allowing SQL names with underscores.
The chart supplies the Cluster reference and defaults `databaseReclaimPolicy`
to `retain`. Native `extensions`, `schemas`, `fdws`, `servers`, and other database
fields pass through. Extension binaries must be present in the operand image.

The default Database/DatabaseRole wave is one greater than the Cluster wave;
`databaseSyncWave` overrides it, and `database.syncWave` can override the single
application Database. Role and database controllers retry dependencies within
that wave. Application migration jobs must run later and verify the database is
usable. Argo sync waves alone do not establish SQL readiness without appropriate
resource health checks.

To adopt an existing database:

1. Keep its Cluster name, SQL database name, owner, and credential Secret unchanged.
2. Check that another Database CR does not already manage that SQL database. Move
   ownership deliberately if one exists, including the Temporal visibility CR in
   the application resources chart. Do not emit a second controller for it.
3. Enable `database.enabled` or add a `databases` entry, retaining the default
   reclaim policy. Verify `.status.applied` and `.status.observedGeneration`.
4. Move extension/schema declarations out of bootstrap SQL when appropriate.
   SQL hooks remain supported for operations without a declarative equivalent.

Database CRs apply changes when their generation changes; they do not continuously
undo all manual SQL changes. Omitting an extension does not drop it. Explicit
`ensure: absent` can delete objects, even when the database reclaim policy is
`retain`. See [database management](https://cloudnative-pg.io/docs/1.30/declarative_database_management/).

`managed` is the native Cluster.spec.managed object. `databaseRoles` maps stable
suffixes to native DatabaseRole.spec objects and defaults
`databaseRoleReclaimPolicy: retain`. If both forms name the same SQL role, the
chart renders only the DatabaseRole definition for that role. Other inline roles
and managed services remain intact.

Before transferring role management, install the DatabaseRole CRD, record the
existing attributes and memberships, and express all required privileges,
`inRoles`, and the existing password Secret in the new entry. Apply the Cluster
and DatabaseRole together, then verify role status and application authentication
before removing the old values. To follow upstream's staged handoff, first apply
the rendered DatabaseRole alone while the old inline definition still exists;
CNPG reports the overlap until the final chart sync removes that inline entry.
Reversing the transfer requires removing the CR
with `retain` and restoring the equivalent inline definition. Role adoption can
reset omitted attributes and memberships. See [role management](https://cloudnative-pg.io/docs/1.30/declarative_role_management/).

Operator-issued role client certificates require `tls.mode: operator` in this
chart. The default cert-manager setup does not expose the CA signing key to CNPG.
An explicit `clientCertificate.enabled: false` is allowed with any TLS mode.

## Credentials and rotation

`credentials.mode: existing` preserves the legacy SealedSecret references and
renders no ESO resources. Do not point ESO at a Secret still reconciled by Sealed
Secrets: the controllers would compete over its data.

[examples/generated.yaml](examples/generated.yaml) opts into
`credentials.mode: generated`. CNPG creates `<cluster>-app`, and optionally
`<cluster>-superuser` when `enableSuperuserAccess` is true. The chart omits custom
bootstrap/superuser Secret references in this mode, even if legacy values remain.
ESO Password generators provide independent passwords and ExternalSecrets use
`creationPolicy: Merge` on those CNPG-owned Secrets. No Vault, SecretStore,
PushSecret, plaintext Helm Secret, Helm randomness, or cluster lookup is involved.
Use chart `initdb` settings in this mode; native `bootstrap` remains available
with existing or recovery-copy credentials.

This follows the [CNPG integration](https://cloudnative-pg.io/docs/1.30/cncf-projects/external-secrets/),
including `cnpg.io/reload: "true"`. The chart also updates both FQDN connection
strings omitted from the upstream example, percent-encodes URI credentials, and
escapes `.pgpass` separators. `clusterDomain` defaults to `cluster.local`; match
CNPG's configured Kubernetes cluster domain. Superuser connection strings and
`dbname` use `postgres`, while `.pgpass` retains a wildcard database match.

Generated ExternalSecrets and Cluster share a sync wave: Merge needs CNPG to
create its target first. An earlier health-gated ExternalSecret wave would block
bootstrap. Wait for both Cluster readiness and ExternalSecret `Ready=True` before
starting consumers. The first ESO reconciliation changes CNPG's initial password.

Rotation is disabled by default (`Periodic`, `refreshInterval: 0s`). Zero prevents
scheduled refresh, not all future changes: recreating the ExternalSecret or
changing managed target data can cause a new password. Keep these objects stable.
To enable scheduled rotation later:

```yaml
credentials:
  mode: generated
  rotation:
    enabled: true
    interval: 24h
```

Enabling rotation can immediately change the password. Deploy Reloader first,
and put this annotation on each consuming Deployment/StatefulSet's metadata,
substituting the actual Secret name:

```yaml
metadata:
  annotations:
    secret.reloader.stakater.com/reload: example-postgres-app
```

The annotation belongs to the application workload, not to the CNPG Cluster or
its inherited pod metadata. All referenced Secrets must be in the workload's
namespace. Reloader restarts consumers; CNPG reloads the database password.
These operations are asynchronous and do not guarantee uninterrupted new
connections. Test reconnects and rolling availability for each application
before enabling rotation. Reloader is absent from the live cluster as checked
2026-10-01; automatic rotation remains deferred. See
[Reloader's workload configuration](https://github.com/stakater/Reloader#how-to-use-reloader).

For an existing cluster, leave `existing` on the initial chart upgrade. Migrate
credentials separately: back up the current credential Secrets, record all app
references and managed-role passwordSecret references, adopt the new target
names deliberately, wait for ESO/CNPG reconciliation, and verify authentication
before switching consumers. Existing `bootstrap.initdb` fields do not reinitialize
an existing database. Do not assume removing a custom bootstrap Secret adopts
all historical role passwords; validate the selected owner/role management path.
Keep the original SealedSecrets for rollback until the migration is verified.

Generated passwords are not automatically sealed or backed up to an external
store. Losing the cluster can lose those Secrets. Include them in disaster
recovery backups, or deliberately reset restored passwords and update consumers.
Committed SealedSecrets recover only the credentials they actually contain; they
do not track later ESO-generated passwords.

### Recovery credential copy

`credentials.mode: copy` complements `bootstrap.recovery` for a new CNPG Cluster.
It copies username/password from explicitly named Secrets in the same namespace
into `<new-cluster>-recovery-app` and optionally `-recovery-superuser`, and rebuilds
connection fields for the replacement hostname. It checks the copied username
against the intended role. The new bootstrap Secret reference overrides the
legacy name and any explicit `bootstrap.recovery.secret`.

The physical backup contains role password hashes but no Kubernetes Secrets.
CNPG applies the copied application's password after promotion using the declared
recovery database/owner. Copying credentials is therefore separate from restoring
base backup files and WAL. It requires the source Secrets to remain accessible;
a complete cluster loss needs separately recovered Secrets. For another namespace
or cluster, pre-stage credentials there with Sealed Secrets or another supported
process and use existing mode. Do not grant broad cross-cluster access by default.

Copy mode grants a dedicated ServiceAccount only `get` on the named source
Secrets. ESO uses Kubernetes' normal authenticated-user self-review permissions
and the operator's ServiceAccount token permission. There is no secret list/watch
permission. Copies use `creationPolicy: Orphan`, `deletionPolicy: Retain`, and
interval zero: deleting ExternalSecret does not garbage-collect the copied
Secret. After successful copying, source password changes do not propagate.
If a retained target is lost, deliberately recreate the ExternalSecret while its
source is still available. Credential retention does not retain the database or
its PVCs when a Cluster is deleted.

## Certificates and the new CNPG CA

The chart previously issued server, application-user, and replication certificates;
it did not issue a `postgres` superuser client certificate. Set
`tls.superuserCertificate: true` to create `<cluster>-client-superuser-tls`, with
CN `postgres` and client-auth usage. Password-based superuser access remains
independent and disabled by default.

New-cluster examples use `tls.profile: cnpg`, defaulting to ClusterIssuer
`cnpg-ca`, declared in homelab's cert-issuers chart under `cluster-local-ca`.
This profile also includes full service FQDN SANs. Legacy values retain the
`apps-ca-issuer` signer and their original SANs. `tls.issuerRef` explicitly
overrides either profile; Helm cannot infer whether a release is new, so there
is no automatic change of existing issuers.

Sync the new CA first and verify its Certificate and ClusterIssuer are Ready.
Before migrating an existing cluster, distribute the new root trust to consumers,
then change issuer/profile during a planned certificate migration. Verify the
issued leaf chains and client connections before retiring old trust. Server
clients can mount the existing `homelab-cluster-local-ca` bundle in namespaces
labelled `bundle.benfu.me/inject: "true"`. No additional root bundle is needed.

The CNPG intermediate provides a dedicated signer, **not an isolated client-auth
trust domain**. cert-manager puts the shared cluster-local root in leaf `ca.crt`,
which the chart exposes to CNPG. Stock PostgreSQL does not enable partial-chain
verification, so replacing that root with only an intermediate breaks validation;
retaining it accepts valid sibling-CA client chains subject to HBA checks.
See [cert-manager CA chains](https://cert-manager.io/docs/configuration/ca/) and
[PostgreSQL's TLS verification implementation](https://github.com/postgres/postgres/blob/REL_16_STABLE/src/backend/libpq/be-secure-openssl.c).
A separately rooted CNPG domain would be a distinct PKI design change.

Issuing a superuser certificate does not enable certificate login. Add a scoped
HBA rule through `postgresql.pg_hba`, for example the following documentation
CIDR replaced with the actual admin source network:

```yaml
postgresql:
  pg_hba:
    - hostssl postgres postgres 192.0.2.0/24 cert
```

Use `sslmode=verify-full`, a server SAN hostname, the root certificate, and the
client certificate/key with appropriate private-key permissions. Restrict who can
request/read `postgres` certificates and which clients can reach PostgreSQL.
See [PostgreSQL certificate authentication](https://www.postgresql.org/docs/16/auth-cert.html).
No broad HBA rule is injected automatically.

## Backups and recovery

Legacy `backup.provider: inTree` preserves the existing Ceph endpoint, bucket,
credential Secret keys, WAL compression, and retention. Setting
`backup.scheduled.enabled: true` adds a ScheduledBackup with the corresponding
method. Schedules have six fields, with seconds first. `immediate: true` triggers
a backup on initial schedule creation. WAL archiving alone is not a base backup.

To migrate an existing archive to the Barman plugin:

1. Install and verify compatible plugin/controller versions and CRDs. Confirm the
   existing bucket, Secrets, archival health, and a restorable base backup.
2. Plan for a rolling restart. Set only `backup.provider: plugin` initially.
   Keep `backup.objectBucket.enabled: true`, the Cluster name, image, endpoint,
   destination, and credentials unchanged. The chart creates an ObjectStore with
   the same configuration and moves retention there. In one Cluster spec update,
   it removes in-tree Barman configuration and activates the WAL archiver plugin.
3. Enable the schedule if needed. Verify plugin readiness, continuous archiving,
   a completed base backup, and recovery into a separate Cluster before treating
   the migration as proven. Update alert/dashboard queries for plugin metric names.
4. Only after backups work, consider moving from a system image with bundled
   Barman to an explicitly pinned standard/minimal image at the same PostgreSQL
   major. Keep the version tag when pinning a digest: `repository:tag@digest`.

Follow the [upstream migration procedure](https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/)
and [observability guidance](https://cloudnative-pg.io/plugin-barman-cloud/docs/observability/).
In-tree Barman is deprecated and scheduled for removal in CNPG 1.31. Its default
here is a compatibility bridge, not the recommendation for new installations.

`backup.configuration` is a complete native Barman configuration. It replaces
Ceph defaults rather than mixing credential providers. For an externally managed
ObjectStore, use `backup.objectStore.existingName`; configure retention and
credentials on that resource. Disabling `backup.objectBucket.enabled` removes
the OBC from desired manifests and may cause GitOps pruning and bucket deletion.
Do not disable it just to switch backup providers. `backup.provider: none` alone
keeps the claim but stops archiving.

[examples/recovery.yaml](examples/recovery.yaml) shows native plugin recovery and
a PITR target. Create a new release with a distinct Cluster name and destination,
using the same PostgreSQL major as the backup. The source ObjectStore and its
credentials must exist in the target namespace. Supply the recovered application's
credential Secret deliberately, or use the example's `credentials.mode: copy`
to copy it from the source cluster. Copying a Secret does not copy database data.
With cert-manager TLS, keep `clientUsername`/`database.owner` available or disable
`tls.clientCertificate`. Verify recovered data before application cutover.

[examples/snapshot.yaml](examples/snapshot.yaml) schedules volume snapshots while
retaining WAL archiving. Restore testing must cover both data and separate WAL
volumes. See [CNPG backup guidance](https://cloudnative-pg.io/docs/1.30/backup/).

The [local restore tools](local-restore/README.md) were copied from Netail and
are explicitly **untested against homelab backups**. Their sanitizer rewrites
configuration and runs `pg_resetwal`; it does not anonymize data or perform a
consistent WAL recovery. Prefer logical dumps or CNPG recovery.

## Further opt-ins

[examples/modern.yaml](examples/modern.yaml) demonstrates DatabaseRole, plugin
backups, generated credentials, the CNPG CA and admin certificate, checksums at
initdb, stable scheduling labels, switchover updates, and an
explicit PodMonitor. It is a starting point for a new cluster, not an overlay to
apply wholesale to an existing database. Select a current operand image for the
required PostgreSQL major, or use an existing ImageCatalog via `imageCatalogRef`.
The example intentionally does not change the chart's legacy image default.

`monitoring.mode: podMonitor` disables the deprecated operator-created monitor
and creates `<cluster>-metrics`, avoiding ownership conflicts with the existing
`<cluster>` monitor. Ensure Prometheus selects the new monitor's labels and
scrapes it successfully; remove any old monitor left behind after checking
ownership. See [CNPG monitoring](https://cloudnative-pg.io/docs/1.30/monitoring/).

`postgresql` accepts native configuration, including synchronous replication
and supported extension-image definitions. Extension image volumes additionally
require PostgreSQL 18+, an appropriate Kubernetes ImageVolume feature gate/runtime,
and matching extension images. The current homelab does not meet those prerequisites.
See [image volume extensions](https://cloudnative-pg.io/docs/1.30/imagevolume_extensions/).
Adding `clusterSpec.walStorage` to an existing Cluster is supported; removing it
later is not. See [storage](https://cloudnative-pg.io/docs/1.30/storage/).

## Validation

From the repository root:

```sh
helm lint charts/postgresql --strict -f charts/postgresql/examples/legacy.yaml
python -m pytest charts/postgresql/tests -q
python scripts/validate_postgresql_schemas.py --cache /tmp/postgresql-schema-sources
python scripts/check_postgresql_consumers.py \
  --baseline-ref fc4c7194ec2fb1e2adf2fbe201bad3f8b80aeb9c \
  --manifests ../kubernetes-manifests
```

Python checks require PyYAML, pytest, and jsonschema. The schema checker downloads
checksum-locked upstream CRDs into its external cache, reuses repository
Certificate/PodMonitor and Kubernetes schemas, ESO 2.11.0 CRDs, and rejects
unknown native fields. It does not
evaluate Kubernetes CEL, admission webhooks, credentials, or runtime behavior.
ObjectBucketClaim compatibility is covered by the original consumer render
comparison rather than upstream schema validation.

The consumer checker renders the actual Argo Applications and compares every
resource spec and identity, ignoring only the CR chart-version label and empty
metadata annotations. It fails on unhandled inline Helm overrides. An optional
`--live-clusters <report.json>` checks that every live cluster identity is covered;
that identity check does not claim to detect all live configuration drift.
