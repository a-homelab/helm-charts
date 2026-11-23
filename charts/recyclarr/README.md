# Recyclarr

[Recyclarr](https://recyclarr.dev) as a CronJob that syncs TRaSH Guides quality
profiles, custom formats and quality sizes into Sonarr and Radarr. The chart
uses the repository's `common` library and runs
`ghcr.io/recyclarr/recyclarr` at its `appVersion`.

## Configuration

`recyclarr.config` is Recyclarr's own `recyclarr.yml`, rendered verbatim into a
ConfigMap and mounted at `/config/recyclarr.yml`. Its keys follow the
[Recyclarr configuration reference](https://recyclarr.dev/reference/configuration/),
not this chart. It is a string rather than a map so that Recyclarr's YAML tags,
such as `!secret`, reach the file unchanged. An empty configuration fails the
render.

Keep API keys out of the configuration with `!secret` tags. Set
`recyclarr.secretName` to an existing Secret with a `secrets.yml` key; the chart
mounts it at `/config/secrets.yml`, where Recyclarr reads it
([value substitution](https://recyclarr.dev/reference/configuration/value-substitution/#secrets)).

Each run reads the files at its start, so a change applies from the next run.

## Schedule

The CronJob runs `recyclarr sync` at the top of every hour, never overlapping
a run that is still going. A failed run gets one retry in a fresh pod, so the
failed pod's log stays readable. Override `components.main.cronjob.schedule` to
change the cadence.

## Storage

`/config` is a 1Gi ReadWriteOnce claim, `<release>-data`. Recyclarr keeps its
clones of the TRaSH Guides and config-templates repositories, its cache and
its logs there, so a run fetches only what changed. Set
`appResources.pvc.data.spec.storageClassName` to choose the storage class.

The container runs as UID 1000, the image's user, with a read-only root
filesystem, all capabilities dropped and no service account token.
