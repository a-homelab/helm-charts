{{- define "common.loggingSidecar" -}}

- name: wait-for-db-ready
  image: bitnami/postgresql:{{ .Values.global.postgresql.image.tag }}
  command:
    - /bin/sh
  args:
    - -c
    - |
        until pg_isready -h unms-postgresql -p 5432 -U unms;
        do
            echo "Waiting for database...";
            sleep 5;
        done

{{- end -}}
