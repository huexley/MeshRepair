#!/bin/sh
# `meshrepair` command installed by the PKG (linked from /usr/local/bin)
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 exec "$DIR/python/bin/python3" "$DIR/meshrepair.py" "$@"
