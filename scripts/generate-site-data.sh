#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_DIR=$ROOT_DIR/scripts
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

PG_CONFIG=${PG_CONFIG:-/usr/lib/postgresql/18/bin/pg_config}
POSTGRES_REPO=${POSTGRES_REPO:?POSTGRES_REPO is required}
EKORRE_SRC_DIR=${EKORRE_SRC_DIR:-"$ROOT_DIR/.cache/ekorre"}
BRANCHES=${BRANCHES:-master,REL_14_STABLE,REL_15_STABLE,REL_16_STABLE,REL_17_STABLE,REL_18_STABLE}
ROOT_BRANCH=${ROOT_BRANCH:-master}
INCLUDE_DIFF=${INCLUDE_DIFF:-true}
MAX_COMMITS=${MAX_COMMITS:-0}
SITE_DIR=${SITE_DIR:-"$ROOT_DIR/site"}
DATA_DIR=${DATA_DIR:-"$SITE_DIR/data"}
SITE_DIST_DIR=${SITE_DIST_DIR:-"$SITE_DIR/dist"}
TMP_ROOT=${TMP_ROOT:-"$ROOT_DIR/.tmp"}

cleanup()
{
	"$SCRIPT_DIR/temp-postgres.sh" stop >/dev/null 2>&1 || true
	rm -rf "$RUN_DIR"
}

mkdir -p "$TMP_ROOT" "$DATA_DIR"
RUN_DIR=$(mktemp -d "$TMP_ROOT/run.XXXXXX")
export PG_CONFIG
export PGDATA=${PGDATA:-"$RUN_DIR/pgdata"}
export PGHOST=${PGHOST:-"$RUN_DIR/socket"}
export PGPORT=${PGPORT:-55432}
export PGLOG=${PGLOG:-"$RUN_DIR/postgresql.log"}
export PGDATABASE=${PGDATABASE:-postgres}
export PGUSER=${PGUSER:-postgres}
export ROOT_BRANCH
trap cleanup EXIT

normalize_branches "$BRANCHES" "$ROOT_BRANCH"
NORMALIZED_BRANCH_CSV=$(join_branches_csv)
MODULE_PATH=${MODULE_PATH:-"$("$SCRIPT_DIR/prepare-ekorre.sh")"}

"$SCRIPT_DIR/temp-postgres.sh" init
"$SCRIPT_DIR/temp-postgres.sh" start
"$SCRIPT_DIR/temp-postgres.sh" psql -v module_path="$MODULE_PATH" -f "$SCRIPT_DIR/load-fdw.sql"

REPO_PATH=$POSTGRES_REPO \
BRANCHES=$NORMALIZED_BRANCH_CSV \
ROOT_BRANCH=$ROOT_BRANCH \
INCLUDE_DIFF=$INCLUDE_DIFF \
MAX_COMMITS=$MAX_COMMITS \
"$SCRIPT_DIR/render-bootstrap-sql.sh" > "$RUN_DIR/bootstrap.sql"

"$SCRIPT_DIR/temp-postgres.sh" psql -f "$RUN_DIR/bootstrap.sql"
"$SCRIPT_DIR/temp-postgres.sh" psql -f "$ROOT_DIR/views.sql"
"$SCRIPT_DIR/temp-postgres.sh" psql -c "REFRESH MATERIALIZED VIEW authors"
"$SCRIPT_DIR/temp-postgres.sh" psql -c "REFRESH MATERIALIZED VIEW commits"

DATA_DIR=$DATA_DIR ROOT_BRANCH=$ROOT_BRANCH REPOSITORY_PATH=$POSTGRES_REPO bash "$SCRIPT_DIR/export-json.sh"

{
	printf '{\n'
	printf '  "root_branch": %s,\n' "$(json_string "$ROOT_BRANCH")"
	printf '  "branches": [\n'
	for index in "${!NORMALIZED_BRANCHES[@]}"; do
		separator=','
		if (( index == ${#NORMALIZED_BRANCHES[@]} - 1 )); then
			separator=''
		fi
		printf '    %s%s\n' "$(json_string "${NORMALIZED_BRANCHES[$index]}")" "$separator"
	done
	printf '  ],\n'
	printf '  "include_diff": %s,\n' "$INCLUDE_DIFF"
	printf '  "max_commits": %s,\n' "$MAX_COMMITS"
	printf '  "repository_path": %s\n' "$(json_string "$POSTGRES_REPO")"
	printf '}\n'
} > "$DATA_DIR/branches.json"

SITE_DATA_DIR=$DATA_DIR SITE_DIST_DIR=$SITE_DIST_DIR "$SCRIPT_DIR/build-site.sh"
