#!/bin/bash
# Boots the entire stack for live visual QA: chain -> contracts -> seed trades
# -> indexer -> production web build served statically. Leaves everything
# running in the background; call teardown_stack.sh to stop it.
set -e
export PATH=/home/claude/tools:$PATH
ROOT=/home/claude/ascent
RPC=http://127.0.0.1:8545

pkill -9 -f anvil 2>/dev/null || true
pkill -9 -f "node src/index.js" 2>/dev/null || true
pkill -9 -f "vite preview" 2>/dev/null || true
pkill -9 -f "http.server 4173" 2>/dev/null || true
sleep 1

cd $ROOT/contracts
anvil --port 8545 > /tmp/anvil.log 2>&1 &
sleep 3
PK=$(grep -oE '0x[0-9a-f]{64}' /tmp/anvil.log | sed -n 1p)
PK2=$(grep -oE '0x[0-9a-f]{64}' /tmp/anvil.log | sed -n 2p)
PK3=$(grep -oE '0x[0-9a-f]{64}' /tmp/anvil.log | sed -n 3p)
ADDR2=$(cast wallet address --private-key $PK2)
echo "chain up: $(cast block-number --rpc-url $RPC)"

PRIVATE_KEY=$PK forge script script/MockRouter.s.sol --tc DeployMockRouter --rpc-url $RPC --broadcast > /tmp/router.log 2>&1
ROUTER=$(grep "router:" /tmp/router.log | awk '{print $2}')
[ -z "$ROUTER" ] && { echo "ROUTER FAILED"; cat /tmp/router.log; exit 1; }

PRIVATE_KEY=$PK FEE_RECIPIENT=$ADDR2 DEX_ROUTER=$ROUTER \
  forge script script/Deploy.s.sol --rpc-url $RPC --broadcast > /tmp/factory.log 2>&1
FACTORY=$(grep "AscentFactory:" /tmp/factory.log | awk '{print $2}')
[ -z "$FACTORY" ] && { echo "FACTORY FAILED"; cat /tmp/factory.log; exit 1; }
echo "factory: $FACTORY"

# Seed three tokens in different states so the UI has real variety to render:
#  1. VLNC  — active, mid curve
#  2. SIGNL — freshly launched, no trades
#  3. GRAD  — pushed to graduation
launch() {
  cast send $FACTORY "launch(string,string,string)" "$1" "$2" "$3" \
    --value 0.0005ether --private-key $PK --rpc-url $RPC > /dev/null
  cast call $FACTORY "allCurves(uint256)(address)" $4 --rpc-url $RPC
}
CURVE1=$(launch "Valencia Signal" "VLNC" "data:application/json,%7B%22description%22%3A%22Community%20token%20for%20the%20Valencia%20creator%20scene%22%7D" 0)
CURVE2=$(launch "Fresh Launch" "SIGNL" "data:application/json,%7B%7D" 1)
CURVE3=$(launch "Summit Token" "GRAD" "data:application/json,%7B%7D" 2)

cast send $CURVE1 "buy(uint256)" 0 --value 0.6ether --private-key $PK --rpc-url $RPC > /dev/null
cast send $CURVE1 "buy(uint256)" 0 --value 0.4ether --private-key $PK2 --rpc-url $RPC > /dev/null
TOKEN1=$(cast call $CURVE1 "token()(address)" --rpc-url $RPC)
BAL=$(cast call $TOKEN1 "balanceOf(address)(uint256)" $ADDR2 --rpc-url $RPC | awk '{print $1}')
cast send $TOKEN1 "approve(address,uint256)" $CURVE1 $BAL --private-key $PK2 --rpc-url $RPC > /dev/null
HALF=$(python3 -c "print($BAL//3)")
cast send $CURVE1 "sell(uint256,uint256)" $HALF 0 --private-key $PK2 --rpc-url $RPC > /dev/null
cast send $CURVE1 "buy(uint256)" 0 --value 0.3ether --private-key $PK3 --rpc-url $RPC > /dev/null

cast send $CURVE3 "buy(uint256)" 0 --value 10ether --private-key $PK --rpc-url $RPC > /dev/null
echo "seeded: curve1=$CURVE1 curve2=$CURVE2 curve3=$CURVE3"

cd $ROOT/indexer
rm -f ascent.db*
RPC_URL=$RPC FACTORY_ADDRESS=$FACTORY PORT=3001 POLL_MS=800 nohup node src/index.js > /tmp/indexer.log 2>&1 &
sleep 5
curl -sf localhost:3001/health || { echo "INDEXER FAILED"; cat /tmp/indexer.log; exit 1; }
echo "indexer up"

cd $ROOT/web
VITE_FACTORY_ADDRESS=$FACTORY VITE_API_URL=http://localhost:3001 \
  VITE_CHAIN_ID=31337 VITE_CHAIN_NAME=Local VITE_RPC_URL=$RPC \
  VITE_NATIVE_SYMBOL=ETH VITE_CREATION_FEE=0.0005 \
  npm run build > /tmp/webbuild.log 2>&1 || { cat /tmp/webbuild.log; exit 1; }
nohup python3 -m http.server 4173 --directory dist > /tmp/webserve.log 2>&1 &
sleep 2
curl -sf localhost:4173 > /dev/null && echo "web up on :4173"

echo "FIRST_TOKEN_CURVE=$CURVE1" > /tmp/stack_env.sh
echo "STACK READY"
