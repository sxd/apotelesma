#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/apotelesma-commits-cache-test.XXXXXX")

cleanup()
{
	PGDATA="$RUN_DIR/pgdata" \
	PGHOST="$RUN_DIR/socket" \
	PGPORT="${PGPORT:-55439}" \
	PGLOG="$RUN_DIR/postgresql.log" \
	"$ROOT_DIR/scripts/temp-postgres.sh" stop >/dev/null 2>&1 || true
	rm -rf "$RUN_DIR"
}

export PGDATA="$RUN_DIR/pgdata"
export PGHOST="$RUN_DIR/socket"
export PGPORT="${PGPORT:-55439}"
export PGLOG="$RUN_DIR/postgresql.log"
export PGDATABASE=postgres
export PGUSER=postgres
trap cleanup EXIT

"$ROOT_DIR/scripts/temp-postgres.sh" init
"$ROOT_DIR/scripts/temp-postgres.sh" start
"$ROOT_DIR/scripts/temp-postgres.sh" psql -f "$ROOT_DIR/tests/commits-cache.sql"
