#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PG_CONFIG=${PG_CONFIG:-/usr/lib/postgresql/18/bin/pg_config}
PG_BINDIR=$("$PG_CONFIG" --bindir)
PGDATA=${PGDATA:-"$ROOT_DIR/.tmp/pgdata"}
PGHOST=${PGHOST:-"$ROOT_DIR/.tmp/run"}
PGPORT=${PGPORT:-55432}
PGLOG=${PGLOG:-"$ROOT_DIR/.tmp/postgresql.log"}
PGDATABASE=${PGDATABASE:-postgres}
PGUSER=${PGUSER:-postgres}
POSTGRES_OPTS="-F -k $PGHOST -p $PGPORT -c listen_addresses=''"
COMMAND=${1:-}

mkdir -p "$(dirname "$PGLOG")" "$PGHOST"

case "$COMMAND" in
	init)
		if [[ -f "$PGDATA/PG_VERSION" ]]; then
			exit 0
		fi

		mkdir -p "$PGDATA"
		"$PG_BINDIR/initdb" \
			--pgdata="$PGDATA" \
			--auth=trust \
			--username="$PGUSER" \
			--encoding=UTF8 \
			--locale=C >/dev/null
		;;
	start)
		"$PG_BINDIR/pg_ctl" -D "$PGDATA" -l "$PGLOG" -o "$POSTGRES_OPTS" start -w
		;;
	stop)
		if [[ -f "$PGDATA/postmaster.pid" ]]; then
			"$PG_BINDIR/pg_ctl" -D "$PGDATA" stop -m fast -w
		fi
		;;
	psql)
		shift
		exec env PGTZ=UTC "$PG_BINDIR/psql" \
			-X \
			-h "$PGHOST" \
			-p "$PGPORT" \
			-U "$PGUSER" \
			-d "$PGDATABASE" \
			-v ON_ERROR_STOP=1 \
			"$@"
		;;
	single)
		shift
		exec env PGTZ=UTC "$PG_BINDIR/postgres" --single -D "$PGDATA" "$PGDATABASE" "$@"
		;;
	*)
		echo "usage: $0 {init|start|stop|psql|single}" >&2
		exit 1
		;;
esac
