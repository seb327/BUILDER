#!/bin/sh
# Test-harness equivalent of web/docker-entrypoint.sh — generates config.js
# against an arbitrary dist directory from the current shell's VITE_* env
# vars, so qa_run.sh and wallet_e2e.sh exercise the exact same runtime-config
# mechanism Railway will actually use, without needing Docker in this sandbox.
# Usage: ./gen_web_config.sh <path-to-dist>
set -e
DIST="${1:?usage: gen_web_config.sh <dist-dir>}"

cat > "$DIST/config.js" <<CONFIGJS
window.__ASCENT_CONFIG__ = {
  VITE_FACTORY_ADDRESS: "${VITE_FACTORY_ADDRESS:-}",
  VITE_API_URL: "${VITE_API_URL:-}",
  VITE_CHAIN_ID: "${VITE_CHAIN_ID:-}",
  VITE_CHAIN_NAME: "${VITE_CHAIN_NAME:-}",
  VITE_RPC_URL: "${VITE_RPC_URL:-}",
  VITE_NATIVE_SYMBOL: "${VITE_NATIVE_SYMBOL:-}",
  VITE_CREATION_FEE: "${VITE_CREATION_FEE:-}"
};
CONFIGJS
