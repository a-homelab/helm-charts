{{/*
Expand the name of the chart.
*/}}
{{- define "postgresql.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "postgresql.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := .Chart.Name }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "postgresql.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "postgresql.labels" -}}
{{ include "postgresql.podLabels" . }}
helm.sh/chart: {{ include "postgresql.chart" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "postgresql.selectorLabels" -}}
app.kubernetes.io/name: {{ include "postgresql.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- /* Pods never carry the chart version: CNPG patches inherited labels onto
every instance, so a version label would touch every pod on each chart release. */ -}}
{{- define "postgresql.podLabels" -}}
{{ include "postgresql.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with omit .Values.labels "app.kubernetes.io/name" "app.kubernetes.io/instance" "app.kubernetes.io/managed-by" "helm.sh/chart" }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "postgresql.annotations" -}}
{{- $annotations := deepCopy .Values.annotations -}}
{{- if ne (toString .Values.syncWave) "" -}}
{{- $_ := set $annotations "argocd.argoproj.io/sync-wave" (toString .Values.syncWave) -}}
{{- end -}}
{{- toYaml $annotations -}}
{{- end -}}

{{- define "postgresql.syncWave" -}}
{{- .Values.syncWave | toString | default (get .Values.annotations "argocd.argoproj.io/sync-wave") -}}
{{- end -}}

{{- /* The release sync wave minus .by, for resources that must exist before the release's own Certificates. Takes a dict with root and by. */ -}}
{{- define "postgresql.syncWaveBefore" -}}
{{- sub (int (include "postgresql.syncWave" .root | default "0")) .by -}}
{{- end -}}

{{- define "postgresql.databaseWave" -}}
{{- if ne (toString .Values.databaseSyncWave) "" -}}
{{- .Values.databaseSyncWave -}}
{{- else -}}
{{- add 1 (int (include "postgresql.syncWave" . | default "0")) -}}
{{- end -}}
{{- end -}}

{{- /* Annotations for resources that state their own sync wave. */ -}}
{{- define "postgresql.extraAnnotations" -}}
{{- with omit .Values.annotations "argocd.argoproj.io/sync-wave" -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.databaseName" -}}
{{- required "database.name is required" .Values.database.name -}}
{{- end -}}
{{- define "postgresql.databaseOwner" -}}
{{- required "database.owner is required" .Values.database.owner -}}
{{- end -}}

{{- define "postgresql.dnsLabel" -}}
{{- if or (gt (len .) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" .)) -}}
{{- fail (printf "resource name %q must be a DNS label of at most 63 characters; shorten fullnameOverride or the SQL name" .) -}}
{{- end -}}
{{- . -}}
{{- end -}}

{{- /* SQL names allow more than DNS labels do: lowercase, hyphenate the rest. */ -}}
{{- define "postgresql.sqlSlug" -}}
{{- $slug := trimAll "-" (regexReplaceAll "[^a-z0-9]+" (lower .) "-") -}}
{{- if not $slug -}}{{- fail (printf "SQL name %q cannot form a Kubernetes resource name" .) -}}{{- end -}}
{{- $slug -}}
{{- end -}}

{{- define "postgresql.sqlResourceName" -}}
{{- printf "%s-%s-%s" (include "postgresql.fullname" .root) .prefix (include "postgresql.sqlSlug" .sqlName) | include "postgresql.dnsLabel" -}}
{{- end -}}

{{- define "postgresql.poolerName" -}}
{{- printf "%s-pooler-%s" (include "postgresql.fullname" .root) .key | include "postgresql.dnsLabel" -}}
{{- end -}}

{{- define "postgresql.credentialPrefix" -}}
{{- include "postgresql.fullname" . -}}-{{- if eq .Values.credentials.mode "copy" -}}recovery-{{- end -}}
{{- end -}}

{{- define "postgresql.ownerSecretName" -}}
{{- if eq .Values.credentials.mode "existing" -}}
{{- required "credentials.existing.userSecretName is required" .Values.credentials.existing.userSecretName -}}
{{- else -}}
{{- $fullname := include "postgresql.fullname" . -}}
{{- $slug := include "postgresql.sqlSlug" (include "postgresql.databaseOwner" .) -}}
{{- $name := printf "%s%s" (include "postgresql.credentialPrefix" .) $slug | include "postgresql.dnsLabel" -}}
{{- /* <cluster>-<role> shares the namespace with Secrets CNPG and this chart name
after the cluster; a role with one of these names would take one over. */ -}}
{{- range list "ca" "server" "replication" "superuser" "backup-bucket" -}}
{{- if eq $name (printf "%s-%s" $fullname .) -}}
{{- fail (printf "credential Secret %q would collide with the cluster's %s Secret; rename database.owner" $name .) -}}
{{- end -}}
{{- end -}}
{{- $name -}}
{{- end -}}
{{- end -}}

{{- /* The superuser's Secret is <cluster>-superuser, CNPG's own name for it,
rather than <cluster>-postgres. */ -}}
{{- define "postgresql.superuserSecretName" -}}
{{- if eq .Values.credentials.mode "existing" -}}
{{- default "" .Values.credentials.existing.superuserSecretName -}}
{{- else -}}
{{- printf "%ssuperuser" (include "postgresql.credentialPrefix" .) | include "postgresql.dnsLabel" -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.validate" -}}
{{- if and (ne .Values.credentials.mode "existing") .Values.enableSuperuserAccess -}}
{{- if eq (include "postgresql.ownerSecretName" .) (include "postgresql.superuserSecretName" .) -}}
{{- fail "database.owner superuser collides with the superuser credential Secret; rename database.owner" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.credentials.rotation.enabled (ne .Values.credentials.mode "generated") -}}
{{- fail "credentials.rotation requires credentials.mode=generated" -}}
{{- end -}}
{{- if and (eq .Values.credentials.mode "generated") .Values.bootstrap -}}
{{- fail "credentials.mode=generated requires the chart initdb settings; use copy or existing credentials for native bootstrap" -}}
{{- end -}}
{{- if eq .Values.credentials.mode "existing" -}}
{{- range $method, $settings := .Values.bootstrap -}}
{{- if not (dig "secret" "name" "" $settings) -}}
{{- fail (printf "bootstrap.%s.secret.name is required; CNPG-generated credential Secrets are disabled" $method) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if eq .Values.credentials.mode "copy" -}}
{{- if not .Values.bootstrap.recovery -}}{{- fail "credentials.mode=copy requires bootstrap.recovery" -}}{{- end -}}
{{- $_ := required "credentials.copy.userSecretName is required" .Values.credentials.copy.userSecretName -}}
{{- if .Values.enableSuperuserAccess -}}
{{- $_ := required "credentials.copy.superuserSecretName is required with superuser access" .Values.credentials.copy.superuserSecretName -}}
{{- end -}}
{{- range $source := list .Values.credentials.copy.userSecretName .Values.credentials.copy.superuserSecretName -}}
{{- if has $source (list (include "postgresql.ownerSecretName" $) (include "postgresql.superuserSecretName" $)) -}}
{{- fail "credential copy source must differ from its destination" -}}
{{- end -}}
{{- end -}}
{{- range $field, $expected := dict "database" (include "postgresql.databaseName" .) "owner" (include "postgresql.databaseOwner" .) -}}
{{- if and (get $.Values.bootstrap.recovery $field) (ne (get $.Values.bootstrap.recovery $field) $expected) -}}
{{- fail (printf "bootstrap.recovery.%s must match the chart database identity when copying credentials" $field) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if eq .Values.tls.clientCAOwner (include "postgresql.fullname" .) -}}
{{- fail "tls.clientCAOwner names this release; leave it empty for the cluster's own client CA" -}}
{{- end -}}
{{- if and .Values.tls.superuserCertificate (ne .Values.tls.mode "certManager") -}}
{{- fail "tls.superuserCertificate requires tls.mode=certManager" -}}
{{- end -}}
{{- $owned := list "inheritedMetadata" "imageName" "imageCatalogRef" "imagePullPolicy" "imagePullSecrets" "instances" "enableSuperuserAccess" "postgresql" "managed" "bootstrap" "externalClusters" "superuserSecret" "certificates" "primaryUpdateStrategy" "primaryUpdateMethod" "smartShutdownTimeout" "storage" "affinity" "topologySpreadConstraints" "resources" "plugins" "backup" "replicationSlots" "monitoring" -}}
{{- range $key, $_ := .Values.extraClusterSpec -}}
{{- if has $key $owned -}}{{- fail (printf "extraClusterSpec.%s conflicts with a chart-owned field; use its chart value" $key) -}}{{- end -}}
{{- end -}}
{{- if and (eq .Values.credentials.mode "existing") .Values.enableSuperuserAccess (not (include "postgresql.superuserSecretName" .)) -}}
{{- fail "credentials.existing.superuserSecretName is required when enableSuperuserAccess=true" -}}
{{- end -}}

{{- if and (eq .Values.tls.mode "external") (not .Values.tls.certificates) -}}
{{- fail "tls.certificates is required when tls.mode=external" -}}
{{- end -}}
{{- if and (ne .Values.tls.mode "external") .Values.tls.certificates -}}
{{- fail "tls.certificates requires tls.mode=external" -}}
{{- end -}}
{{- if and (eq .Values.database.authMethod "certificate") (not (and (eq .Values.tls.mode "certManager") .Values.tls.clientCertificate)) -}}
{{- fail "database.authMethod=certificate requires tls.mode=certManager and tls.clientCertificate, which issue the owner's <cluster>-client-user-tls" -}}
{{- end -}}
{{- if and .Values.imageCatalogRef (or .Values.image.tag .Values.image.digest) -}}
{{- fail "imageCatalogRef replaces image.tag and image.digest; remove them so the values show the running version" -}}
{{- end -}}
{{- if hasKey .Values.monitoring.configuration "enablePodMonitor" -}}
{{- fail "use monitoring.podMonitor.enabled instead of monitoring.configuration.enablePodMonitor" -}}
{{- end -}}
{{- if .Values.backup.objectStore.existingName -}}
{{- if not .Values.backup.enabled -}}{{- fail "backup.objectStore.existingName requires backup.enabled" -}}{{- end -}}
{{- if .Values.backup.configuration -}}{{- fail "backup.configuration is unused with an existing ObjectStore" -}}{{- end -}}
{{- end -}}
{{- if and .Values.backup.serverName (not .Values.backup.enabled) -}}
{{- fail "backup.serverName requires backup.enabled" -}}
{{- end -}}
{{- if and .Values.tls.serverAltDNSNames (eq .Values.tls.mode "external") -}}
{{- fail "tls.serverAltDNSNames is unused with tls.mode=external; put serverAltDNSNames in tls.certificates" -}}
{{- end -}}
{{- if and .Values.backup.enabled .Values.backup.configuration.serverName -}}
{{- fail "plugin ObjectStore configuration.serverName must be empty; set recovery serverName on externalClusters instead" -}}
{{- end -}}
{{- if .Values.backup.scheduled.enabled -}}
{{- $method := .Values.backup.scheduled.method | default "plugin" -}}
{{- if eq $method "volumeSnapshot" -}}
{{- if not .Values.backup.volumeSnapshot -}}{{- fail "scheduled volumeSnapshot requires backup.volumeSnapshot" -}}{{- end -}}
{{- else if not .Values.backup.enabled -}}
{{- fail "backup.scheduled.method plugin requires backup.enabled, or use volumeSnapshot" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.validateDatabases" -}}
{{- if hasKey .Values.databases "app" -}}{{- fail "databases.app is reserved for the database key" -}}{{- end -}}
{{- $cluster := include "postgresql.fullname" . -}}
{{- $mainName := include "postgresql.databaseName" . -}}
{{- $names := dict $mainName true -}}
{{- $slugs := dict (include "postgresql.sqlSlug" $mainName) true -}}
{{- range $key, $database := .Values.databases -}}
{{- $_ := required (printf "databases.%s.name is required" $key) $database.name -}}
{{- $_ := required (printf "databases.%s.owner is required" $key) $database.owner -}}
{{- if hasKey $names $database.name -}}{{- fail (printf "duplicate database name %s" $database.name) -}}{{- end -}}
{{- $_ := set $names $database.name true -}}
{{- $slug := include "postgresql.sqlSlug" $database.name -}}
{{- if hasKey $slugs $slug -}}{{- fail (printf "duplicate Database resource name %s-db-%s; database names must differ after normalization" $cluster $slug) -}}{{- end -}}
{{- $_ := set $slugs $slug true -}}
{{- if hasKey $database "cluster" -}}{{- fail "Database cluster is assigned by this chart" -}}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.validateDatabaseRoles" -}}
{{- $cluster := include "postgresql.fullname" . -}}
{{- $names := dict -}}
{{- $slugs := dict -}}
{{- range $key, $role := .Values.databaseRoles -}}
{{- $_ := required (printf "databaseRoles.%s.name is required" $key) $role.name -}}
{{- if hasKey $names $role.name -}}{{- fail (printf "duplicate DatabaseRole name %s" $role.name) -}}{{- end -}}
{{- $_ := set $names $role.name true -}}
{{- $slug := include "postgresql.sqlSlug" $role.name -}}
{{- if hasKey $slugs $slug -}}{{- fail (printf "duplicate DatabaseRole resource name %s-role-%s; role names must differ after normalization" $cluster $slug) -}}{{- end -}}
{{- $_ := set $slugs $slug true -}}
{{- if hasKey $role "cluster" -}}{{- fail "DatabaseRole cluster is assigned by this chart" -}}{{- end -}}
{{- if eq ($role.ensure | default "present") "absent" -}}{{- fail "DatabaseRole removal uses databaseRoleReclaimPolicy, not ensure: absent" -}}{{- end -}}
{{- if and (dig "clientCertificate" "enabled" (hasKey $role "clientCertificate") $role) (ne $.Values.tls.mode "operator") -}}
{{- fail "DatabaseRole clientCertificate requires tls.mode=operator; cert-manager does not expose the CA private key" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.issuerRef" -}}
{{- if .Values.tls.issuerRef -}}
{{- toYaml .Values.tls.issuerRef -}}
{{- else -}}
name: cnpg-ca
kind: ClusterIssuer
{{- end -}}
{{- end -}}

{{- define "postgresql.clientIssuerRef" -}}
{{- if eq .Values.tls.clientCA "cluster" -}}
name: "{{ .Values.tls.clientCAOwner | default (include "postgresql.fullname" .) }}-client-ca"
kind: Issuer
group: cert-manager.io
{{- else -}}
{{- include "postgresql.issuerRef" . -}}
{{- end -}}
{{- end -}}

{{- /* The owner, plus postgres when superuser access is on, as a YAML list. */ -}}
{{- define "postgresql.credentialRoles" -}}
- secretName: {{ include "postgresql.ownerSecretName" . | quote }}
  username: {{ include "postgresql.databaseOwner" . | quote }}
  database: {{ include "postgresql.databaseName" . | quote }}
  pgpassDatabase: {{ include "postgresql.databaseName" . | quote }}
  source: {{ .Values.credentials.copy.userSecretName | quote }}
{{- if .Values.enableSuperuserAccess }}
- secretName: {{ include "postgresql.superuserSecretName" . | quote }}
  username: postgres
  database: postgres
  pgpassDatabase: "*"
  source: {{ .Values.credentials.copy.superuserSecretName | quote }}
{{- end }}
{{- end -}}

{{- /* Nonempty when a Pooler relies on the chart-issued auth_query certificate. */ -}}
{{- define "postgresql.poolerAuthCertificateNeeded" -}}
{{- if eq .Values.tls.mode "certManager" -}}
{{- range .Values.poolers -}}
{{- if not (dig "pgbouncer" "authQuerySecret" "" .) -}}true{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.poolerAuthSecretName" -}}
{{- printf "%s-pooler-auth-tls" (include "postgresql.fullname" .) -}}
{{- end -}}

{{/*
Pooler Service DNS names as YAML list items. CNPG serves pooler client TLS with
the cluster's server certificate unless a Pooler sets clientTLSSecret.
*/}}
{{- define "postgresql.poolerDNSNames" -}}
{{- range $key, $_ := .Values.poolers }}
{{- $name := include "postgresql.poolerName" (dict "root" $ "key" $key) }}
- {{ $name }}
- {{ $name }}.{{ $.Release.Namespace }}
- {{ $name }}.{{ $.Release.Namespace }}.svc
- {{ $name }}.{{ $.Release.Namespace }}.svc.{{ $.Values.clusterDomain }}
{{- end }}
{{- end -}}

{{/*
CNPG serializes spec lists and maps with omitempty, so the operator's own writes
(for example adding a finalizer) drop empty ones and Argo CD reports drift.
Render the native fields of Database and DatabaseRole specs without empty
top-level lists and maps.
*/}}
{{- define "postgresql.pruneEmpty" -}}
{{- $out := dict -}}
{{- range $key, $value := . -}}
{{- if not (and (has (kindOf $value) (list "slice" "map")) (empty $value)) -}}
{{- $_ := set $out $key $value -}}
{{- end -}}
{{- end -}}
{{- with $out -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}
