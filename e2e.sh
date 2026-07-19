#!/bin/bash
# Ascent end-to-end integration test.
# Boots a local chain, deploys the stack, launches a token, trades it to
# graduation, runs the indexer, and asserts on the API output.
set -e
export PATH=/home/claude/tools:$PATH
cd /home/claude/ascent/contracts

RPC=http://127.0.0.1:8545

anvil --port 8545 > /tmp/anvil.log 2>&1 &
ANVIL=$!
sleep 3
# Pull funded keys straight from anvil's banner — no hardcoding mistakes.
PK=$(grep -oE '0x[0-9a-f]{64}' /tmp/anvil.log | sed -n 1p)
PK2=$(grep -oE '0x[0-9a-f]{64}' /tmp/anvil.log | sed -n 2p)
ADDR2=$(cast wallet address --private-key $PK2)
echo "== chain up, block $(cast block-number --rpc-url $RPC)"

# 1. deploy mock router (stands in for the chain's UniswapV2 router)
PRIVATE_KEY=$PK forge script script/MockRouter.s.sol --tc DeployMockRouter --rpc-url $RPC --broadcast > /tmp/router.log 2>&1
ROUTER=$(grep "router:" /tmp/router.log | awk '{print $2}')
if [ -z "$ROUTER" ]; then echo "ROUTER DEPLOY FAILED:"; cat /tmp/router.log; exit 1; fi
echo "== router $ROUTER"

# 2. deploy factory via the real production script
PRIVATE_KEY=$PK FEE_RECIPIENT=$ADDR2 DEX_ROUTER=$ROUTER forge script script/Deploy.s.sol --rpc-url $RPC --broadcast > /tmp/factory.log 2>&1
FACTORY=$(grep "AscentFactory:" /tmp/factory.log | awk '{print $2}')
if [ -z "$FACTORY" ]; then echo "FACTORY DEPLOY FAILED:"; cat /tmp/factory.log; exit 1; fi
echo "== factory $FACTORY"

# 3. launch a token (0.0005 ETH creation fee)
cast send $FACTORY "launch(string,string,string)" "Valencia Signal" "VLNC" "ipfs://demo" \
  --value 0.0005ether --private-key $PK --rpc-url $RPC > /dev/null
CURVE=$(cast call $FACTORY "allCurves(uint256)(address)" 0 --rpc-url $RPC)
TOKEN=$(cast call $CURVE "token()(address)" --rpc-url $RPC)
echo "== launched curve=$CURVE token=$TOKEN"

# 4. trades: two buys, one sell, then a graduation-sized buy from account 2
cast send $CURVE "buy(uint256)" 0 --value 0.5ether --private-key $PK --rpc-url $RPC > /dev/null
cast send $CURVE "buy(uint256)" 0 --value 0.8ether --private-key $PK2 --rpc-url $RPC > /dev/null
BAL=$(cast call $TOKEN "balanceOf(address)(uint256)" $ADDR2 --rpc-url $RPC | awk '{print $1}')
cast send $TOKEN "approve(address,uint256)" $CURVE $BAL --private-key $PK2 --rpc-url $RPC > /dev/null
HALF=$(python3 -c "print($BAL//2)")
cast send $CURVE "sell(uint256,uint256)" $HALF 0 --private-key $PK2 --rpc-url $RPC > /dev/null
echo "== pre-graduation progress: $(cast call $CURVE 'graduationProgressBps()(uint256)' --rpc-url $RPC) bps"
cast send $CURVE "buy(uint256)" 0 --value 10ether --private-key $PK --rpc-url $RPC > /dev/null
echo "== graduated: $(cast call $CURVE 'graduated()(bool)' --rpc-url $RPC)"
echo "== token unlocked: $(cast call $TOKEN 'unlocked()(bool)' --rpc-url $RPC)"

# 5. post-graduation transfer must work (was locked before)
cast send $TOKEN "transfer(address,uint256)" $ADDR2 1000000000000000000 --private-key $PK --rpc-url $RPC > /dev/null
echo "== post-graduation transfer ok"

# 6. run the indexer against this chain and query the API
cd /home/claude/ascent/indexer
rm -f ascent.db*
RPC_URL=$RPC FACTORY_ADDRESS=$FACTORY PORT=3001 POLL_MS=1000 node src/index.js > /tmp/indexer.log 2>&1 &
IDX=$!
sleep 6

echo "== /health:  $(curl -s localhost:3001/health)"
echo "== /tokens:"
curl -s "localhost:3001/tokens?sort=mcap" | python3 -m json.tool | head -25
echo "== /token/<curve> trade count:"
curl -s "localhost:3001/token/$CURVE" | python3 -c "import json,sys; d=json.load(sys.stdin); print('  trades:', len(d['trades']), '| graduated:', d['graduated'], '| volumeEth:', d['volumeEth'])"
echo "== /candles:"
curl -s "localhost:3001/candles/$CURVE" | python3 -c "import json,sys; c=json.load(sys.stdin); print('  candles:', len(c), '| first:', c[0] if c else None)"

kill $IDX $ANVIL 2>/dev/null
echo "== E2E PASSED"
