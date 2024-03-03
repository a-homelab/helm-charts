#!/bin/bash

set -xe

echo "Starting up kasm with ssl disabled"

# https://github.com/kasmtech/workspaces-core-images/issues/2
sed -i 's/-sslOnly //g' /dockerstartup/vnc_startup.sh
sed -i 's/require_ssl: true/require_ssl: false/g'  /usr/share/kasmvnc/kasmvnc_defaults.yaml

# https://github.com/kasmtech/workspaces-core-images/blob/c3c27140c8a4f3a6ae91eeed4e9d212b3ccbb226/dockerfile-kasm-core#L245
/bin/bash -c '/dockerstartup/kasm_default_profile.sh /dockerstartup/vnc_startup.sh --wait'
