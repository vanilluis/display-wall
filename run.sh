#!/bin/bash
set -e
SCRIPT="$(readlink -f "$0")"
cd "$(dirname "$SCRIPT")"
exec swift display-wall.swift "$@"
