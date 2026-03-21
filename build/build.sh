#!/bin/bash
# build.sh - PCInfo Classic build entry point

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/build_alpine.sh" "$@"
