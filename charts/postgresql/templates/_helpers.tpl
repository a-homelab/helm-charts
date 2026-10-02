{{/*
Expand the name of the chart.
*/}}
{{- define "postgresql.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
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
{{- $name := default .Chart.Name .Values.nameOverride }}
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

{{- define "postgresql.podLabels" -}}
{{- $labels := include "postgresql.labels" . | fromYaml -}}
{{- if eq .Values.scheduling.topologySpreadSelector "legacy" -}}
{{- $_ := set $labels "helm.sh/chart" "postgresql-0.1.0" -}}
{{- end -}}
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
{{- required "databaseName or database.name is required" (coalesce .Values.database.name .Values.databaseName) -}}
{{- end -}}
{{- define "postgresql.databaseOwner" -}}
{{- required "clientUsername or database.owner is required" (coalesce .Values.database.owner .Values.clientUsername) -}}
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
{{- fail (printf "resource name %q must be a DNS label of at most 63 characters; shorten fullnameOverride or set resourceName explicitly" $name) -}}
{{- end -}}
{{- $name -}}
{{- end -}}

{{- define "postgresql.sqlResourceName" -}}
{{- if .resourceName -}}
{{- if or (gt (len .resourceName) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" .resourceName)) -}}
{{- fail (printf "resourceName %q must be a DNS label of at most 63 characters" .resourceName) -}}
{{- end -}}
{{- .resourceName -}}
{{- else -}}
{{- $sqlName := trimAll "-" (regexReplaceAll "[^a-z0-9]+" (lower .sqlName) "-") -}}
{{- if not $sqlName -}}{{- fail "SQL name cannot form a Kubernetes resource name; set resourceName explicitly" -}}{{- end -}}
{{- include "postgresql.resourceName" (dict "root" .root "suffix" (printf "%s-%s" .prefix $sqlName)) -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.credentialResourceName" -}}
{{- $admin := eq .suffix "superuser" -}}
{{- $key := ternary "superuser" "user" $admin -}}
{{- $username := "postgres" -}}
{{- if not $admin -}}{{- $username = include "postgresql.databaseOwner" .root -}}{{- end -}}
{{- $prefix := ternary "recovery-creds" "creds" (eq .root.Values.credentials.mode "copy") -}}
{{- include "postgresql.sqlResourceName" (dict "root" .root "prefix" $prefix "sqlName" $username "resourceName" (get .root.Values.credentials.resourceNames $key)) -}}
{{- end -}}

{{- define "postgresql.validate" -}}
{{- if and (ne .Values.credentials.mode "existing") .Values.enableSuperuserAccess -}}
{{- if eq (include "postgresql.credentialResourceName" (dict "root" . "suffix" "app")) (include "postgresql.credentialResourceName" (dict "root" . "suffix" "superuser")) -}}
{{- fail "duplicate credential resource name; set distinct credentials.resourceNames.user and superuser" -}}
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
{{- $owned := list "inheritedMetadata" "imageName" "imageCatalogRef" "imagePullPolicy" "imagePullSecrets" "instances" "enableSuperuserAccess" "postgresql" "managed" "bootstrap" "externalClusters" "superuserSecret" "certificates" "primaryUpdateStrategy" "primaryUpdateMethod" "storage" "affinity" "topologySpreadConstraints" "resources" "plugins" "backup" "replicationSlots" "monitoring" -}}
{{- range $key, $_ := .Values.clusterSpec -}}
{{- if has $key $owned -}}{{- fail (printf "clusterSpec.%s conflicts with a chart-owned field; use its chart value" $key) -}}{{- end -}}
{{- end -}}
{{- if and (eq .Values.credentials.mode "existing") .Values.enableSuperuserAccess (not (include "postgresql.superuserSecretName" .)) -}}
{{- fail "credentials.existing.superuserSecretName or superuserCredsSecretName is required when enableSuperuserAccess=true" -}}
{{- end -}}

{{- if and (eq .Values.tls.mode "external") (not .Values.tls.certificates) -}}
{{- fail "tls.certificates is required when tls.mode=external" -}}
{{- end -}}
{{- if and (ne .Values.tls.mode "external") .Values.tls.certificates -}}
{{- fail "tls.certificates requires tls.mode=external" -}}
{{- end -}}
{{- if and .Values.imageCatalogRef .Values.image.digest -}}
{{- fail "imageCatalogRef and image.digest are mutually exclusive" -}}
{{- end -}}
{{- if hasKey .Values.monitoring.configuration "enablePodMonitor" -}}
{{- fail "use monitoring.mode instead of monitoring.configuration.enablePodMonitor" -}}
{{- end -}}
{{- if .Values.backup.objectStore.existingName -}}
{{- if ne .Values.backup.provider "plugin" -}}{{- fail "backup.objectStore.existingName requires backup.provider=plugin" -}}{{- end -}}
{{- if .Values.backup.configuration -}}{{- fail "backup.configuration is unused with an existing ObjectStore" -}}{{- end -}}
{{- end -}}
{{- if and (eq .Values.backup.provider "plugin") .Values.backup.configuration.serverName -}}
{{- fail "plugin ObjectStore configuration.serverName must be empty; set recovery serverName on externalClusters instead" -}}
{{- end -}}
{{- if .Values.backup.scheduled.enabled -}}
{{- $method := .Values.backup.scheduled.method | default (ternary "plugin" "barmanObjectStore" (eq .Values.backup.provider "plugin")) -}}
{{- if eq $method "volumeSnapshot" -}}
{{- if not .Values.backup.volumeSnapshot -}}{{- fail "scheduled volumeSnapshot requires backup.volumeSnapshot" -}}{{- end -}}
{{- else if or (and (eq $method "plugin") (ne .Values.backup.provider "plugin")) (and (eq $method "barmanObjectStore") (ne .Values.backup.provider "inTree")) -}}
{{- fail "backup.scheduled.method must match backup.provider, or use volumeSnapshot" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.issuerRef" -}}
{{- if .Values.tls.issuerRef -}}
{{- toYaml .Values.tls.issuerRef -}}
{{- else if eq .Values.tls.profile "cnpg" -}}
name: cnpg-ca
kind: ClusterIssuer
{{- else -}}
{{- toYaml .Values.certificateIssuerRef -}}
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
{{- if hasKey .Values.credentials.existing "userSecretName" -}}
{{- .Values.credentials.existing.userSecretName -}}
{{- else -}}
{{- default "" .Values.userCredsSecretName -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.superuserSecretName" -}}
{{- if hasKey .Values.credentials.existing "superuserSecretName" -}}
{{- .Values.credentials.existing.superuserSecretName -}}
{{- else -}}
{{- default "" .Values.superuserCredsSecretName -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.bucketStorageClassName" -}}
{{- if hasKey .Values.backup.objectBucket "storageClassName" -}}
{{- .Values.backup.objectBucket.storageClassName -}}
{{- else -}}
{{- .Values.backup.storageClassName -}}
{{- end -}}
{{- end -}}
