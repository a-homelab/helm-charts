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

deployment:
  replicas: 1
  strategy: {}
  revisionHistoryLimit: 10

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
  backoffLimit: 6

cronjob:
  schedule: ""
  timeZone: ""
  concurrencyPolicy: Forbid
  suspend: false
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1

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
