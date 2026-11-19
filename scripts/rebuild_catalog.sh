#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
.venv/bin/python -m photohub.catalog
