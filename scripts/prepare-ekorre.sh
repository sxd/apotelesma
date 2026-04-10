#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EKORRE_REPO_URL=${EKORRE_REPO_URL:-https://github.com/sxd/ekorre.git}
EKORRE_SRC_DIR=${EKORRE_SRC_DIR:-"$ROOT_DIR/.cache/ekorre"}
EKORRE_REF=${EKORRE_REF:-}
PG_CONFIG=${PG_CONFIG:-/usr/lib/postgresql/18/bin/pg_config}

mkdir -p "$(dirname "$EKORRE_SRC_DIR")"

if [[ ! -d "$EKORRE_SRC_DIR/.git" ]]; then
	git clone "$EKORRE_REPO_URL" "$EKORRE_SRC_DIR" >/dev/null
fi

if [[ -n "$EKORRE_REF" ]]; then
	git -C "$EKORRE_SRC_DIR" fetch --depth 1 origin "$EKORRE_REF" >/dev/null
	git -C "$EKORRE_SRC_DIR" checkout --detach FETCH_HEAD >/dev/null
fi

make -C "$EKORRE_SRC_DIR" PG_CONFIG="$PG_CONFIG" >/dev/null
printf '%s\n' "$EKORRE_SRC_DIR/ekorre.so"
