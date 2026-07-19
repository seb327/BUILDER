#!/bin/bash
# ASCENT — one-shot live deploy. Fill in the six values below, then run:
#
#   ./deploy_live.sh
#
# This does everything code can do for you: deploys the contracts, creates
# two Railway services, sets every environment variable, deploys both, and
# prints the live URLs at the end. It cannot run inside the environment that
# built this repo — it has no network path to any RPC or to Railway. It runs
# on YOUR machine, using YOUR credentials, which is the only place a real
# deploy can happen.
#
# Requires: forge (curl -L https://foundry.paradigm.xyz | bash && foundryup),
# node 18+, and a Railway account (free — the script triggers login).
set -euo pipefail

# ---- fill these in -----------------------------------------------------------
PRIVATE_KEY=""          # deployer wallet private key, funded with native gas
RPC_URL=""              # your target chain's RPC endpoint
FEE_RECIPIENT=""        # address that receives trade + creation fees
DEX_ROUTER=""           # UniswapV2-compatible router address on that chain
CHAIN_ID=""             # e.g. 8453 for Base, 1 for Ethereum mainnet
CHAIN_NAME=""           # display name, e.g. "Base"
# --------------------------------------------------------------------------------

# optional overrides — sane defaults shown
VIRTUAL_ETH="${VIRTUAL_ETH:-1200000000000000000}"      # 1.2 native
GRADUATION_ETH="${GRADUATION_ETH:-4800000000000000000}" # 4.8 native
CREATION_FEE="${CREATION_FEE:-500000000000000}"          # 0.0005 native
MAX_BUY_BPS="${MAX_BUY_BPS:-300}"                        # anti-snipe cap, 3%
NATIVE_SYMBOL="${NATIVE_SYMBOL:-ETH}"

for v in PRIVATE_KEY RPC_URL FEE_RECIPIENT DEX_ROUTER CHAIN_ID CHAIN_NAME; do
  if [ -z "${!v}" ]; then
    echo "Missing $v — edit the top of this script before running it."
    exit 1
  fi
done

command -v forge >/dev/null || { echo "forge not found. Install Foundry first: https://book.getfoundry.sh/getting-started/installation"; exit 1; }
command -v railway >/dev/null || npm install -g @railway/cli

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== 1/4 deploying contracts to $CHAIN_NAME"
cd "$ROOT/contracts"
DEPLOY_OUT=$(PRIVATE_KEY=$PRIVATE_KEY FEE_RECIPIENT=$FEE_RECIPIENT DEX_ROUTER=$DEX_ROUTER \
  VIRTUAL_ETH=$VIRTUAL_ETH GRADUATION_ETH=$GRADUATION_ETH CREATION_FEE=$CREATION_FEE MAX_BUY_BPS=$MAX_BUY_BPS \
  forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast)
FACTORY=$(echo "$DEPLOY_OUT" | grep "AscentFactory:" | awk '{print $2}')
if [ -z "$FACTORY" ]; then
  echo "Contract deploy failed. Full output:"
  echo "$DEPLOY_OUT"
  exit 1
fi
echo "   factory deployed: $FACTORY"

echo "== 2/4 signing in to Railway (browser will open if needed)"
railway login

echo "== 3/4 deploying indexer"
cd "$ROOT/indexer"
railway init -n ascent-indexer 2>/dev/null || true
railway add --database >/dev/null 2>&1 || true   # harmless if it already exists
railway variable set RPC_URL="$RPC_URL"
railway variable set FACTORY_ADDRESS="$FACTORY"
railway variable set VIRTUAL_ETH="$VIRTUAL_ETH"
railway variable set GRADUATION_ETH="$GRADUATION_ETH"
railway variable set DB_PATH="/data/ascent.db"
railway volume add -m /data 2>/dev/null || true
railway up -y --detach
railway domain 2>/dev/null || true
INDEXER_URL=$(railway domain 2>/dev/null | grep -oE 'https?://[^ ]+' | head -1)
echo "   indexer: ${INDEXER_URL:-<check Railway dashboard — domain not auto-detected>}"

echo "== 4/4 deploying web app"
cd "$ROOT/web"
railway init -n ascent-web 2>/dev/null || true
railway variable set VITE_FACTORY_ADDRESS="$FACTORY"
railway variable set VITE_API_URL="$INDEXER_URL"
railway variable set VITE_CHAIN_ID="$CHAIN_ID"
railway variable set VITE_CHAIN_NAME="$CHAIN_NAME"
railway variable set VITE_RPC_URL="$RPC_URL"
railway variable set VITE_NATIVE_SYMBOL="$NATIVE_SYMBOL"
railway variable set VITE_CREATION_FEE="$(python3 -c "print($CREATION_FEE/1e18)")"
railway up -y --detach
railway domain 2>/dev/null || true
WEB_URL=$(railway domain 2>/dev/null | grep -oE 'https?://[^ ]+' | head -1)

echo ""
echo "== DONE"
echo "Factory:  $FACTORY"
echo "Indexer:  ${INDEXER_URL:-check Railway dashboard}"
echo "Web app:  ${WEB_URL:-check Railway dashboard}"
echo ""
echo "If a domain didn't print above, run 'railway domain' inside the"
echo "matching service directory — Railway sometimes needs a few seconds"
echo "after first deploy before a domain can be generated."
