#!/bin/sh
# Command-line wrapper: meshrepair FILE [FILE ...]
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
exec "$DIR/.venv/bin/python" "$DIR/meshrepair.py" "$@"
