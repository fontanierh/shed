#!/bin/bash
cd "$(dirname "$0")"
set -a; . ~/src/atelier/.env >/dev/null 2>&1; set +a
for n in $(ls motion/prompts | sed 's/.txt$//'); do /usr/bin/python3 motion.py "$n" & done; wait
