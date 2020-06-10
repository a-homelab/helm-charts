#!/usr/bin/env bash

UNMS_VERSION=${UNMS_VERSION:-1.2.3}
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

curl https://unms.com/v1/master/unms-${UNMS_VERSION}.tar.gz -o /tmp/unms-${UNMS_VERSION}.tar.gz

mkdir -p /tmp/unms-${UNMS_VERSION}
tar zxf /tmp/unms-${UNMS_VERSION}.tar.gz -C /tmp/unms-${UNMS_VERSION}

mkdir -p ${SCRIPT_DIR}/installation-files/${UNMS_VERSION}
cp /tmp/unms-${UNMS_VERSION}/docker-compose.yml.template ${SCRIPT_DIR}/installation-files/${UNMS_VERSION}/docker-compose.yml.template
cp /tmp/unms-${UNMS_VERSION}/install-full.sh ${SCRIPT_DIR}/installation-files/${UNMS_VERSION}/install-full.sh
cp /tmp/unms-${UNMS_VERSION}/conf/postgres/create-users.sh ${SCRIPT_DIR}/installation-files/${UNMS_VERSION}/create-users.sh
