#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
NVM_NODE="$HOME/.nvm/versions/node/v22.18.0/bin/node"

if [[ -x "$NVM_NODE" ]] && "$NVM_NODE" --version >/dev/null 2>&1; then
  exec "$NVM_NODE" "$PROJECT_DIR/src/server.mjs"
fi

if command -v node >/dev/null 2>&1 && node --version >/dev/null 2>&1; then
  exec node "$PROJECT_DIR/src/server.mjs"
fi

print -u2 "No se encontró una instalación funcional de Node.js 20 o posterior."
exit 1
