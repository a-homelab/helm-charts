#!/usr/bin/env bash

for chart_dir in charts/*/; do
    chart=$(basename $chart_dir)
    echo "Packaging $chart..."
    helm package $chart_dir -d dist/charts/$chart
done

helm repo index dist/charts

git add dist/charts
git commit -m "Update charts"
git subtree pull --prefix dist/ origin gh-pages --squash
git subtree push --prefix dist/ origin gh-pages
