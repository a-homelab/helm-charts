{{/*
Expand the name of the chart.
*/}}
{{- define "kafka.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
The Kafka cluster's name, and the prefix of every name Strimzi derives from it. The release name when
it contains the chart name, as mimir-kafka does.
*/}}
{{- define "kafka.fullname" -}}
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
{{- define "kafka.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- /*
Labels for the cert-manager, approver-policy and monitoring objects. Kafka and KafkaNodePool never
carry them: Strimzi copies a custom resource's labels onto the pods it runs, except
app.kubernetes.io/* (STRIMZI_LABELS_EXCLUSION_PATTERN), so helm.sh/chart would restart every broker
and controller on each chart release.
*/ -}}
{{- define "kafka.labels" -}}
app.kubernetes.io/name: {{ include "kafka.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "kafka.chart" . }}
{{- end }}

{{- /* The sync-wave annotation of the release's own resources, when syncWave is set. */ -}}
{{- define "kafka.syncWaveAnnotation" -}}
{{- if ne (toString .Values.syncWave) "" }}
argocd.argoproj.io/sync-wave: {{ .Values.syncWave | toString | quote }}
{{- end }}
{{- end }}

{{- /*
The release sync wave minus .by, for the CA chain that must be Ready before Strimzi requests its
certificates. Takes a dict with root and by.
*/ -}}
{{- define "kafka.syncWaveBefore" -}}
{{- sub (int (toString .root.Values.syncWave | default "0")) .by -}}
{{- end }}

{{- /*
The sorted names of the users whose authMethod is .authMethod ("certificate" or "password"), as a
YAML list for fromYamlArray. authMethod defaults to certificate. Takes a dict with root and
authMethod.
*/ -}}
{{- define "kafka.userNames" -}}
{{- $names := list }}
{{- range $user, $spec := .root.Values.users }}
{{- if eq ($spec.authMethod | default "certificate") $.authMethod }}
{{- $names = append $names $user }}
{{- end }}
{{- end }}
{{- toYaml $names }}
{{- end }}
