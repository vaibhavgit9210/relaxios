#!/bin/bash
# Builds bin/storm-render and bin/avcheck (macOS, Command Line Tools only).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O src/*.swift -o bin/storm-render
swiftc -O tools/avcheck.swift -o bin/avcheck
echo "built bin/storm-render bin/avcheck"
