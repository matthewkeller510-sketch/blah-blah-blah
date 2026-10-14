#!/bin/sh
# Every static gate in one command: unit tests, compile, strict types, lint, format.
# None of these prove the game works in Roblox Studio or on a device (section 23).
set -e
cd "$(dirname "$0")/.."
lune run tests/run
lune run scripts/check-syntax
sh scripts/typecheck.sh
selene src tests
stylua --check src tests scripts
echo "check-all: every gate passed"
