#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

LOCAL_SCHEMA=${LOCAL_SCHEMA:-public}
SERVER_NAME=${SERVER_NAME:-git_server}
BRANCHES=${BRANCHES:-master,REL_14_STABLE,REL_15_STABLE,REL_16_STABLE,REL_17_STABLE,REL_18_STABLE}
ROOT_BRANCH=${ROOT_BRANCH:-master}
REPO_PATH=${REPO_PATH:?REPO_PATH is required}
INCLUDE_DIFF=${INCLUDE_DIFF:-true}
MAX_COMMITS=${MAX_COMMITS:-0}

normalize_branches "$BRANCHES" "$ROOT_BRANCH"
BRANCH_LIST=$(join_branches_csv)
ROOT_TABLE="git_log_$(branch_suffix "$ROOT_BRANCH")"

cat <<SQL
DROP VIEW IF EXISTS git_log_all;
DROP VIEW IF EXISTS git_log;
DROP SERVER IF EXISTS ${SERVER_NAME} CASCADE;

CREATE SERVER ${SERVER_NAME} FOREIGN DATA WRAPPER ekorre;

IMPORT FOREIGN SCHEMA git
FROM SERVER ${SERVER_NAME}
INTO ${LOCAL_SCHEMA}
OPTIONS (
    repopath $(sql_literal "$REPO_PATH"),
    branches $(sql_literal "$BRANCH_LIST"),
    root_branch $(sql_literal "$ROOT_BRANCH"),
    include_diff $(sql_literal "$INCLUDE_DIFF"),
    max_commits $(sql_literal "$MAX_COMMITS")
);

CREATE OR REPLACE VIEW ${LOCAL_SCHEMA}.git_log AS
SELECT *
FROM ${LOCAL_SCHEMA}.${ROOT_TABLE};

CREATE OR REPLACE VIEW ${LOCAL_SCHEMA}.git_log_all AS
SQL

for index in "${!NORMALIZED_BRANCHES[@]}"; do
	branch_name=${NORMALIZED_BRANCHES[$index]}
	table_name="git_log_$(branch_suffix "$branch_name")"

	if (( index > 0 )); then
		printf 'UNION ALL\n'
	fi

	printf 'SELECT %s AS branch, t.*\n' "$(sql_literal "$branch_name")"
	printf 'FROM %s.%s t\n' "$LOCAL_SCHEMA" "$table_name"

	if [[ "$branch_name" != "$ROOT_BRANCH" ]]; then
		printf 'WHERE NOT EXISTS (\n'
		printf '    SELECT 1\n'
		printf '    FROM %s.%s root_table\n' "$LOCAL_SCHEMA" "$ROOT_TABLE"
		printf '    WHERE root_table.commit_id = t.commit_id\n'
		printf ')\n'
	fi
done

printf ';\n'
