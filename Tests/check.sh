#!/bin/sh
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc Shared/Usage.swift Tests/main.swift -o "$out/check"
"$out/check"
