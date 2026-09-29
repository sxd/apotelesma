#!/usr/bin/env bash
set -euo pipefail

AFFILIATION_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AFFILIATION_TEST_DIR=$(mktemp -d /tmp/apotelesma-affiliation-schema-test.XXXXXX)
export PGDATA="$AFFILIATION_TEST_DIR/pgdata"
export PGHOST="$AFFILIATION_TEST_DIR/socket"
export PGPORT=55443
export PGLOG="$AFFILIATION_TEST_DIR/postgresql.log"
export PGDATABASE=postgres
export PGUSER=postgres

cleanup()
{
    "$AFFILIATION_ROOT/scripts/temp-postgres.sh" stop >/dev/null 2>&1 || true
    rm -rf "$AFFILIATION_TEST_DIR"
}
trap cleanup EXIT

"$AFFILIATION_ROOT/scripts/temp-postgres.sh" init
"$AFFILIATION_ROOT/scripts/temp-postgres.sh" start
"$AFFILIATION_ROOT/scripts/temp-postgres.sh" psql -f "$AFFILIATION_ROOT/sql/author-company-history.sql"
"$AFFILIATION_ROOT/scripts/temp-postgres.sh" psql -f "$AFFILIATION_ROOT/sql/author-company-history.sql"
"$AFFILIATION_ROOT/scripts/temp-postgres.sh" psql -f "$AFFILIATION_ROOT/tests/author-company-history.sql"
