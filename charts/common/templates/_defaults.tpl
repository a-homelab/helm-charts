{{/*
=============================================================================
Library defaults — the first layer of the component resolution chain:

  libraryDefaults -> .Values.defaults -> .Values.components.<name>

This block is component-shaped. Two rules govern what belongs here:
1. Every key present must have a value that works standalone.
2. Anything that is expected to always be customized (image.repository,
   env, ports, cronjob.schedule, ...) is deliberately ABSENT or empty and,
   where required, validated at render time with a clear error.
=============================================================================
*/}}
{{- define "common.defaults.component" -}}
enabled: true
kind: Deployment
labels: {}
annotations: {}

container:
  image:
    repository: ""
    tag: ""
    pullPolicy: IfNotPresent
  command: []
  args: []
  workingDir: ""
  env: {}
  envFrom: {}
  ports: {}
  probes:
    liveness: {}
    readiness: {}
    startup: {}
  resources: {}
  securityContext: {}
  lifecycle: {}
  overrides: {}

sidecars: {}
initContainers: {}

pod:
  labels: {}
  annotations: {}
  securityContext: {}
  nodeSelector: {}
  tolerations: {}
  topologySpreadConstraints: {}
  affinity: {}
  hostAliases: {}
  imagePullSecrets: {}
  priorityClassName: ""
  runtimeClassName: ""
  schedulerName: ""
  hostNetwork: false
  enableServiceLinks: false
  dnsPolicy: ""
  dnsConfig: {}
  volumes: {}
  overrides: {}

# Fields whose values would merely restate the Kubernetes defaults
# (revisionHistoryLimit, concurrencyPolicy, job history limits, ...) are
# deliberately absent: the library renders them only when explicitly set,
# so manifests stay minimal and migrations from plain charts stay diff-free.
deployment:
  replicas: 1
  strategy: {}

statefulset:
  replicas: 1
  serviceName: ""
  podManagementPolicy: ""
  updateStrategy: {}
  volumeClaimTemplates: {}

daemonset:
  updateStrategy: {}

# The job block applies to kind: Job AND to the jobTemplate of kind: CronJob.
job:
  restartPolicy: OnFailure

cronjob:
  schedule: ""
  timeZone: ""

overrides: {}

service:
  enabled: true
  type: ClusterIP
  clusterIP: ""
  labels: {}
  annotations: {}
  ports: {}
  overrides: {}

httpRoute:
  enabled: false
  hostnames: []
  parentRefs: {}
  rules: []
  labels: {}
  annotations: {}
  overrides: {}

hpa:
  enabled: false
  min: 1
  max: 3
  metrics: {}
  behavior: {}
  labels: {}
  annotations: {}
  overrides: {}

pdb:
  enabled: false
  labels: {}
  annotations: {}
  overrides: {}

serviceAccount:
  enabled: true
  name: ""
  labels: {}
  annotations: {}
  overrides: {}
{{- end -}}
