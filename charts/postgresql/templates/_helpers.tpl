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
{{- $labels := mustMergeOverwrite (deepCopy .Values.labels) (include "postgresql.selectorLabels" . | fromYaml) (dict "helm.sh/chart" (include "postgresql.chart" .) "app.kubernetes.io/managed-by" .Release.Service) -}}
{{- if .Chart.AppVersion -}}
{{- $_ := set $labels "app.kubernetes.io/version" .Chart.AppVersion -}}
{{- end -}}
{{- toYaml $labels -}}
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
{{- $labels := include "postgresql.labels" . | fromYaml -}}
{{- $_ := unset $labels "helm.sh/chart" -}}
{{- toYaml $labels -}}
{{- end -}}

{{- define "postgresql.annotations" -}}
{{- $annotations := deepCopy .Values.annotations -}}
{{- if ne (toString .Values.syncWave) "" -}}
{{- $_ := set $annotations "argocd.argoproj.io/sync-wave" (toString .Values.syncWave) -}}
{{- end -}}
{{- toYaml $annotations -}}
{{- end -}}

{{- define "postgresql.databaseWave" -}}
{{- if ne (toString .Values.databaseSyncWave) "" -}}
{{- .Values.databaseSyncWave -}}
{{- else -}}
{{- $annotations := include "postgresql.annotations" . | fromYaml -}}
{{- add 1 (int (get $annotations "argocd.argoproj.io/sync-wave" | default "0")) -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.databaseName" -}}
{{- required "database.name is required" .Values.database.name -}}
{{- end -}}
{{- define "postgresql.databaseOwner" -}}
{{- required "database.owner is required" .Values.database.owner -}}
{{- end -}}

{{- define "postgresql.objectStoreName" -}}
{{- default (include "postgresql.fullname" .) .Values.backup.objectStore.existingName -}}
{{- end -}}

{{- define "postgresql.backupConfiguration" -}}
{{- if .Values.backup.configuration -}}
{{- $_ := required "backup.configuration.destinationPath is required" .Values.backup.configuration.destinationPath -}}
{{- toYaml .Values.backup.configuration -}}
{{- else -}}
{{- if not .Values.backup.objectBucket.enabled -}}
{{- fail "backup.configuration is required without backup.objectBucket.enabled" -}}
{{- end -}}
destinationPath: "s3://{{ include "postgresql.fullname" . }}-backup/"
endpointURL: http://rook-ceph-rgw-k8s-store-ssd.rook-ceph.svc
s3Credentials:
  accessKeyId:
    name: "{{ include "postgresql.fullname" . }}-backup-bucket"
    key: AWS_ACCESS_KEY_ID
  secretAccessKey:
    name: "{{ include "postgresql.fullname" . }}-backup-bucket"
    key: AWS_SECRET_ACCESS_KEY
wal:
  compression: gzip
  maxParallel: 8
{{- end -}}
{{- end -}}

{{- define "postgresql.resourceName" -}}
{{- $name := printf "%s-%s" (include "postgresql.fullname" .root) .suffix -}}
{{- if or (gt (len $name) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name)) -}}
{{- fail (printf "resource name %q must be a DNS label of at most 63 characters; shorten fullnameOverride or the SQL name" $name) -}}
{{- end -}}
{{- $name -}}
{{- end -}}

{{- define "postgresql.sqlResourceName" -}}
{{- $sqlName := trimAll "-" (regexReplaceAll "[^a-z0-9]+" (lower .sqlName) "-") -}}
{{- if not $sqlName -}}{{- fail (printf "SQL name %q cannot form a Kubernetes resource name" .sqlName) -}}{{- end -}}
{{- include "postgresql.resourceName" (dict "root" .root "suffix" (ternary $sqlName (printf "%s-%s" .prefix $sqlName) (empty .prefix))) -}}
{{- end -}}

{{- define "postgresql.credentialResourceName" -}}
{{- $admin := eq .suffix "superuser" -}}
{{- /* The superuser's Secret is <cluster>-superuser, CNPG's own name for it,
rather than <cluster>-postgres; the application role's is <cluster>-<role>. */ -}}
{{- $sqlName := "superuser" -}}
{{- if not $admin -}}{{- $sqlName = include "postgresql.databaseOwner" .root -}}{{- end -}}
{{- $prefix := ternary "recovery" "" (eq .root.Values.credentials.mode "copy") -}}
{{- $name := include "postgresql.sqlResourceName" (dict "root" .root "prefix" $prefix "sqlName" $sqlName) -}}
{{- /* <cluster>-<role> shares the namespace with Secrets CNPG and this chart name
after the cluster; a role with one of these names would take one over. */ -}}
{{- $fullname := include "postgresql.fullname" .root -}}
{{- range list "ca" "server" "replication" "superuser" "backup-bucket" -}}
{{- if and (not $admin) (eq $name (printf "%s-%s" $fullname .)) -}}
{{- fail (printf "credential Secret %q would collide with the cluster's %s Secret; rename database.owner" $name .) -}}
{{- end -}}
{{- end -}}
{{- $name -}}
{{- end -}}

{{- define "postgresql.validate" -}}
{{- if and (ne .Values.credentials.mode "existing") .Values.enableSuperuserAccess -}}
{{- if eq (include "postgresql.credentialResourceName" (dict "root" . "suffix" "app")) (include "postgresql.credentialResourceName" (dict "root" . "suffix" "superuser")) -}}
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
{{- if has $source (list (include "postgresql.credentialResourceName" (dict "root" $ "suffix" "app")) (include "postgresql.credentialResourceName" (dict "root" $ "suffix" "superuser"))) -}}
{{- fail "credential copy source must differ from its destination" -}}
{{- end -}}
{{- end -}}
{{- range $field, $expected := dict "database" (include "postgresql.databaseName" .) "owner" (include "postgresql.databaseOwner" .) -}}
{{- if and (get $.Values.bootstrap.recovery $field) (ne (get $.Values.bootstrap.recovery $field) $expected) -}}
{{- fail (printf "bootstrap.recovery.%s must match the chart database identity when copying credentials" $field) -}}
{{- end -}}
{{- end -}}
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

{{- define "postgresql.issuerRef" -}}
{{- if .Values.tls.issuerRef -}}
{{- toYaml .Values.tls.issuerRef -}}
{{- else -}}
name: cnpg-ca
kind: ClusterIssuer
{{- end -}}
{{- end -}}

{{- define "postgresql.serverCASecretName" -}}
{{- $name := include "postgresql.fullname" . -}}
{{- if eq .Values.tls.mode "certManager" -}}
{{- printf "%s-server-tls" $name -}}
{{- else if eq .Values.tls.mode "external" -}}
{{- dig "serverCASecret" (printf "%s-ca" $name) .Values.tls.certificates -}}
{{- else -}}
{{- printf "%s-ca" $name -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.connectionData" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $name := include "postgresql.fullname" $root -}}
{{- $host := printf "%s-rw.%s" $name $root.Release.Namespace -}}
{{- $fqdn := printf "%s.svc.%s" $host $root.Values.clusterDomain -}}
{{- $user := $role.username | urlquery | replace "+" "%20" -}}
{{- $db := $role.database | urlquery | replace "+" "%20" -}}
{{- $passwordURI := `{{ .password | urlquery | replace "+" "%20" }}` -}}
{{- $passwordQuery := `{{ .password | urlquery }}` -}}
{{- $pgUser := $role.username | replace "\\" "\\\\" | replace ":" "\\:" -}}
{{- $pgDB := (ternary "*" $role.database (eq $role.suffix "superuser")) | replace "\\" "\\\\" | replace ":" "\\:" -}}
{{- $pgPassword := `{{ .password | replace "\\" "\\\\" | replace ":" "\\:" }}` -}}
username: {{ $role.username | quote }}
{{- if eq $root.Values.credentials.mode "copy" }}
password: {{ printf `{{ if ne .username %q }}{{ fail "source credential username does not match the restored role" }}{{ end }}{{ .password }}` $role.username | quote }}
{{- else }}
password: '{{ "{{ .password }}" }}'
{{- end }}
host: {{ printf "%s-rw" $name | quote }}
port: "5432"
dbname: {{ $role.database | quote }}
user: {{ $role.username | quote }}
pgpass: {{ printf "%s-rw:5432:%s:%s:%s\n" $name $pgDB $pgUser $pgPassword | quote }}
uri: {{ printf "postgresql://%s:%s@%s:5432/%s" $user $passwordURI $host $db | quote }}
jdbc-uri: {{ printf "jdbc:postgresql://%s:5432/%s?password=%s&user=%s" $host $db $passwordQuery ($role.username | urlquery) | quote }}
fqdn-uri: {{ printf "postgresql://%s:%s@%s:5432/%s" $user $passwordURI $fqdn $db | quote }}
fqdn-jdbc-uri: {{ printf "jdbc:postgresql://%s:5432/%s?password=%s&user=%s" $fqdn $db $passwordQuery ($role.username | urlquery) | quote }}
{{- end -}}

{{- define "postgresql.userSecretName" -}}
{{- default "" .Values.credentials.existing.userSecretName -}}
{{- end -}}

{{- define "postgresql.superuserSecretName" -}}
{{- default "" .Values.credentials.existing.superuserSecretName -}}
{{- end -}}

{{- define "postgresql.poolerName" -}}
{{- include "postgresql.resourceName" (dict "root" .root "suffix" (printf "pooler-%s" .key)) -}}
{{- end -}}

{{- define "postgresql.poolerAuthSecretName" -}}
{{- printf "%s-pooler-auth-tls" (include "postgresql.fullname" .) -}}
{{- end -}}

{{/*
Pooler Service DNS names. CNPG serves pooler client TLS with the cluster's server
certificate unless a Pooler sets clientTLSSecret.
*/}}
{{- define "postgresql.poolerDNSNames" -}}
{{- $names := list -}}
{{- range $key, $pooler := .Values.poolers -}}
{{- $name := include "postgresql.poolerName" (dict "root" $ "key" $key) -}}
{{- $names = concat $names (list $name (printf "%s.%s" $name $.Release.Namespace) (printf "%s.%s.svc" $name $.Release.Namespace) (printf "%s.%s.svc.%s" $name $.Release.Namespace $.Values.clusterDomain)) -}}
{{- end -}}
{{- toJson $names -}}
{{- end -}}

{{/*
CNPG serializes spec lists and maps with omitempty, so the operator's own writes
(for example adding a finalizer) drop empty ones and Argo CD reports drift.
Render Database and DatabaseRole specs without empty top-level lists and maps.
*/}}
{{- define "postgresql.pruneEmpty" -}}
{{- $out := dict -}}
{{- range $key, $value := . -}}
{{- if not (and (has (kindOf $value) (list "slice" "map")) (empty $value)) -}}
{{- $_ := set $out $key $value -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}
