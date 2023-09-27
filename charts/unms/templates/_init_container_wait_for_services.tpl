{{- define "common.initContainersWaitForServices" -}}
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

- name: wait-for-rabbitmq-ready
  image: busybox:1.31.1-glibc
  command:
    - /bin/sh
  args:
    - -c
    - |
        until nc -z unms-rabbitmq 5672;
        do
            echo "Waiting for RabbitMQ..."
            sleep 5;
        done

# - name: wait-for-redis-ready
#   image: bitnami/redis:{{ .Values.global.redis.image.tag }}
#   command:
#     - /bin/sh
#   args:
#     - -c
#     - |
#         until redis-cli -h unms-redis-master -p 6379 ping;
#         do
#             echo "Waiting for Redis..."
#             sleep 5;
#         done

- name: wait-for-siridb-ready
  image: busybox:1.31.1-glibc
  command:
    - /bin/sh
  args:
    - -c
    - |
        until nc -z unms-siridb 9000;
        do
            echo "Waiting for SiriDB..."
            sleep 5;
        done


{{- end -}}
