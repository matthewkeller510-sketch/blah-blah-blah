#!/bin/sh
# Strict type check of src/ with luau-lsp 1.53.0 and its matching Roblox type definitions.
# Needs rojo and luau-lsp on PATH. The definitions are downloaded once into .cache/ (ignored by git).
set -e
cd "$(dirname "$0")/.."
DEFS="${LUAU_DEFS:-.cache/globalTypes.d.luau}"
if [ ! -f "$DEFS" ]; then
	mkdir -p .cache
	curl -sSfL -o "$DEFS" https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.53.0/scripts/globalTypes.d.luau
fi
mkdir -p .cache
rojo sourcemap default.project.json -o .cache/sourcemap.json >/dev/null
luau-lsp analyze --sourcemap=.cache/sourcemap.json --definitions="$DEFS" src
echo "typecheck: 0 diagnostics"
