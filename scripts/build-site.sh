#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SITE_SRC_DIR=${SITE_SRC_DIR:-"$ROOT_DIR/site/src"}
SITE_DATA_DIR=${SITE_DATA_DIR:-"$ROOT_DIR/site/data"}
SITE_DIST_DIR=${SITE_DIST_DIR:-"$ROOT_DIR/site/dist"}
GRAFANA_SRC_DIR=${GRAFANA_SRC_DIR:-"$ROOT_DIR/grafana"}
AFFILIATION_DATA_DIR=${AFFILIATION_DATA_DIR:-"$ROOT_DIR/data/author-affiliations"}

rm -rf "$SITE_DIST_DIR"
mkdir -p "$SITE_DIST_DIR/data" "$SITE_DIST_DIR/grafana"

cp -R "$SITE_SRC_DIR"/. "$SITE_DIST_DIR"/
find "$SITE_DATA_DIR" -maxdepth 1 -type f -name '*.json' -exec cp {} "$SITE_DIST_DIR/data/" \;
# Always derive from the exact published commits, never a stale pilot snapshot.
# Research lives outside both the disposable database and site/data cleanup.
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT_DIR/scripts/author_company_history.py" build-site \
  --data-dir "$AFFILIATION_DATA_DIR" \
  --commits "$SITE_DIST_DIR/data/commits.json" \
  --out-dir "$SITE_DIST_DIR/data" \
  --timestamp-basis committer
find "$GRAFANA_SRC_DIR" -maxdepth 1 -type f -name '*.json' -exec cp {} "$SITE_DIST_DIR/grafana/" \;
touch "$SITE_DIST_DIR/.nojekyll"
