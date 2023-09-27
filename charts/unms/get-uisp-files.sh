#!/usr/bin/env bash

UISP_VERSION=${UISP_VERSION:-2.3.35}
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

curl -L https://uisp.ui.com/v1/master/unms-${UISP_VERSION}.tar.gz -o /tmp/uisp-${UISP_VERSION}.tar.gz

mkdir -p /tmp/uisp-${UISP_VERSION}
tar zxf /tmp/uisp-${UISP_VERSION}.tar.gz -C /tmp/uisp-${UISP_VERSION}

mkdir -p ${SCRIPT_DIR}/installation-files/${UISP_VERSION}
cp /tmp/uisp-${UISP_VERSION}/docker-compose.yml.template ${SCRIPT_DIR}/installation-files/${UISP_VERSION}/docker-compose.yml.template
cp /tmp/uisp-${UISP_VERSION}/install-full.sh ${SCRIPT_DIR}/installation-files/${UISP_VERSION}/install-full.sh
cp /tmp/uisp-${UISP_VERSION}/metadata ${SCRIPT_DIR}/installation-files/${UISP_VERSION}/metadata
