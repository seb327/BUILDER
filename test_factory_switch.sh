#!/bin/bash
# Verifies: if FACTORY_ADDRESS changes between indexer runs (e.g. someone
# changes the Railway variable to point at a redeployed contract), the
# indexer detects it and resets cleanly instead of silently mixing state
# from two different factories.
set -e
export PATH=/home/claude/tools:$PATH
ROOT=/home/claude/ascent
RPC=http://127.0.0.1:8545

pkill -9 anvil 2>/dev/null || true
pkill -9 -f "node src/index.js" 2>/dev/null || true
sleep 1

cd $ROOT/contracts
anvil --port 8545 > /tmp/anvil.log 2>&1 &
ANVIL_PID=$!
sleep 3
PK=$(grep -oE '0x[0-9a-f]{64}' /tmp/anvil.log | sed -n 1p)
ADDR2=$(cast wallet address --private-key $(grep -oE '0x[0-9a-f]{64}' /tmp/anvil.log | sed -n 2p))

PRIVATE_KEY=$PK forge script script/MockRouter.s.sol --tc DeployMockRouter --rpc-url $RPC --broadcast > /tmp/router.log 2>&1
ROUTER=$(grep "router:" /tmp/router.log | awk '{print $2}')

deploy_factory() {
  PRIVATE_KEY=$PK FEE_RECIPIENT=$ADDR2 DEX_ROUTER=$ROUTER forge script script/Deploy.s.sol --tc Deploy --rpc-url $RPC --broadcast > /tmp/factory.log 2>&1
  grep "AscentFactory:" /tmp/factory.log | awk '{print $2}'
}

FACTORY_A=$(deploy_factory)
echo "== factory A: $FACTORY_A"
cast send $FACTORY_A "launch(string,string,string)" "Token A" "TKA" "data:application/json,%7B%7D" \
  --value 0.0005ether --private-key $PK --rpc-url $RPC > /dev/null
echo "== launched a token on factory A"

cd $ROOT/indexer
rm -f ascent.db*

echo "== starting indexer pointed at factory A"
RPC_URL=$RPC FACTORY_ADDRESS=$FACTORY_A PORT=3001 POLL_MS=500 timeout 6 node src/index.js > /tmp/indexer_a.log 2>&1 || true
TOKENS_A=$(node -e "const D=require('better-sqlite3')('ascent.db'); console.log(D.prepare('SELECT COUNT(*) c FROM tokens').get().c);")
echo "== after run 1: $TOKENS_A token(s) indexed for factory A"

FACTORY_B=$(cd $ROOT/contracts && deploy_factory)
echo "== factory B (different contract): $FACTORY_B"
cast send $FACTORY_B "launch(string,string,string)" "Token B" "TKB" "data:application/json,%7B%7D" \
  --value 0.0005ether --private-key $PK --rpc-url $RPC > /dev/null
echo "== launched a token on factory B"

echo "== restarting indexer pointed at factory B (same ascent.db on disk)"
RPC_URL=$RPC FACTORY_ADDRESS=$FACTORY_B PORT=3001 POLL_MS=500 timeout 6 node src/index.js > /tmp/indexer_b.log 2>&1 || true

echo "--- indexer log from the factory-B run ---"
grep -i "FACTORY_ADDRESS changed" /tmp/indexer_b.log || echo "NO RESET MESSAGE LOGGED — BUG"

TOKENS_B=$(node -e "const D=require('better-sqlite3')('ascent.db'); for (const r of D.prepare('SELECT name, symbol FROM tokens').all()) console.log(r.name, r.symbol);")
echo "--- tokens in DB after switching to factory B ---"
echo "$TOKENS_B"
if echo "$TOKENS_B" | grep -q "Token A"; then
  echo "FAIL: stale Token A data survived the factory switch"
  exit 1
fi
if ! echo "$TOKENS_B" | grep -q "Token B"; then
  echo "FAIL: Token B was not indexed after the switch"
  exit 1
fi
echo "PASS: factory switch cleanly reset state and indexed only the new factory's token"

kill $ANVIL_PID 2>/dev/null || true
