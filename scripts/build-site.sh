#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SITE_SRC_DIR=${SITE_SRC_DIR:-"$ROOT_DIR/site/src"}
SITE_DATA_DIR=${SITE_DATA_DIR:-"$ROOT_DIR/site/data"}
SITE_DIST_DIR=${SITE_DIST_DIR:-"$ROOT_DIR/site/dist"}
GRAFANA_SRC_DIR=${GRAFANA_SRC_DIR:-"$ROOT_DIR/grafana"}

rm -rf "$SITE_DIST_DIR"
mkdir -p "$SITE_DIST_DIR/data" "$SITE_DIST_DIR/grafana"

cp -R "$SITE_SRC_DIR"/. "$SITE_DIST_DIR"/
find "$SITE_DATA_DIR" -maxdepth 1 -type f -name '*.json' -exec cp {} "$SITE_DIST_DIR/data/" \;
find "$GRAFANA_SRC_DIR" -maxdepth 1 -type f -name '*.json' -exec cp {} "$SITE_DIST_DIR/grafana/" \;
touch "$SITE_DIST_DIR/.nojekyll"
