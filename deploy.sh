#!/usr/bin/env bash
for chart_dir in charts/*/; do
    chart=$(basename $chart_dir)
    echo "Packaging $chart..."
    set -x
    helm package $chart_dir -d dist/charts/$chart
    set +x
done

echo "Creating chart index..."
set -x
helm repo index dist/charts
set +x

echo "Deploying chart to Github Pages..."

set -x
git add dist/charts
git commit -m "Update charts"
git subtree push --prefix dist/charts origin gh-pages
set +x
