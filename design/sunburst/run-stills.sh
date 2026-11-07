#!/bin/bash
cd "$(dirname "$0")"
set -a; . ~/src/atelier/.env >/dev/null 2>&1; set +a
for n in "$@"; do /usr/bin/python3 still.py "$n" & done; wait
