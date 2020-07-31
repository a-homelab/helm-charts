#!/usr/bin/env bash

CHARTS_DIR=charts
DIST_DIR=dist/charts

for chart_dir in $CHARTS_DIR/*/; do
    chart=$(basename $chart_dir)
    echo "Packaging $chart..."
    set -x
    ( cd $chart_dir && helm dependency update )
    helm package $chart_dir -d $DIST_DIR/$chart
    set +x
done

echo "Creating chart index..."
set -x
helm repo index $DIST_DIR
set +x

echo "Deploying chart to Github Pages..."

set -x
cd $DIST_DIR && \
    git add --all && \
    git commit -m "Update charts" && \
    git push origin gh-pages
set +x
