#!/bin/bash
# One-shot visual QA: boots the whole stack, seeds realistic data, screenshots
# every page with a real headless Chrome, checks for console/page errors,
# then tears everything down. Nothing is left running afterwards.
set -e
export PATH=/home/claude/tools:$PATH
ROOT=/home/claude/ascent
RPC=http://127.0.0.1:8545
CHROME=/home/claude/.cache/puppeteer/chrome-headless-shell/linux-131.0.6778.204/chrome-headless-shell-linux64/chrome-headless-shell

cleanup() {
  echo "-- tearing down --"
  kill $ANVIL_PID $INDEXER_PID $WEB_PID 2>/dev/null || true
}
trap cleanup EXIT

pkill -9 anvil 2>/dev/null || true
pkill -9 -f "node src/index.js" 2>/dev/null || true
pkill -9 -f spa_server 2>/dev/null || true
sleep 1

cd $ROOT/contracts
anvil --port 8545 > /tmp/anvil.log 2>&1 &
ANVIL_PID=$!
sleep 3
PK=$(grep -oE '0x[0-9a-f]{64}' /tmp/anvil.log | sed -n 1p)
PK2=$(grep -oE '0x[0-9a-f]{64}' /tmp/anvil.log | sed -n 2p)
PK3=$(grep -oE '0x[0-9a-f]{64}' /tmp/anvil.log | sed -n 3p)
ADDR2=$(cast wallet address --private-key $PK2)
echo "== chain up, block $(cast block-number --rpc-url $RPC)"

PRIVATE_KEY=$PK forge script script/MockRouter.s.sol --tc DeployMockRouter --rpc-url $RPC --broadcast > /tmp/router.log 2>&1
ROUTER=$(grep "router:" /tmp/router.log | awk '{print $2}')
[ -z "$ROUTER" ] && { echo "ROUTER FAILED"; cat /tmp/router.log; exit 1; }

PRIVATE_KEY=$PK FEE_RECIPIENT=$ADDR2 DEX_ROUTER=$ROUTER \
  forge script script/Deploy.s.sol --rpc-url $RPC --broadcast > /tmp/factory.log 2>&1
FACTORY=$(grep "AscentFactory:" /tmp/factory.log | awk '{print $2}')
[ -z "$FACTORY" ] && { echo "FACTORY FAILED"; cat /tmp/factory.log; exit 1; }
echo "== factory $FACTORY"

launch() {
  cast send $FACTORY "launch(string,string,string)" "$1" "$2" "$3" \
    --value 0.0005ether --private-key $PK --rpc-url $RPC > /dev/null
  cast call $FACTORY "allCurves(uint256)(address)" $4 --rpc-url $RPC
}
IMG_META='data:application/json,%7B%22description%22%3A%20%22Community%20token%20for%20the%20Valencia%20creator%20scene%22%2C%20%22image%22%3A%20%22data%3Aimage/svg%2Bxml%2C%3Csvg%20xmlns%3D%5C%22http%3A//www.w3.org/2000/svg%5C%22%20viewBox%3D%5C%220%200%2064%2064%5C%22%3E%3Crect%20width%3D%5C%2264%5C%22%20height%3D%5C%2264%5C%22%20fill%3D%5C%22%2523c4522a%5C%22/%3E%3Ctext%20x%3D%5C%2232%5C%22%20y%3D%5C%2242%5C%22%20font-size%3D%5C%2228%5C%22%20text-anchor%3D%5C%22middle%5C%22%20fill%3D%5C%22%25230a0a0a%5C%22%3EV%3C/text%3E%3C/svg%3E%22%7D'
CURVE1=$(launch "Valencia Signal" "VLNC" "$IMG_META" 0)
CURVE2=$(launch "Fresh Launch" "SIGNL" "data:application/json,%7B%7D" 1)
CURVE3=$(launch "Summit Token" "GRAD" "data:application/json,%7B%7D" 2)

cast send $CURVE1 "buy(uint256)" 0 --value 0.6ether --private-key $PK --rpc-url $RPC > /dev/null
cast send $CURVE1 "buy(uint256)" 0 --value 0.4ether --private-key $PK2 --rpc-url $RPC > /dev/null
TOKEN1=$(cast call $CURVE1 "token()(address)" --rpc-url $RPC)
BAL=$(cast call $TOKEN1 "balanceOf(address)(uint256)" $ADDR2 --rpc-url $RPC | awk '{print $1}')
cast send $TOKEN1 "approve(address,uint256)" $CURVE1 $BAL --private-key $PK2 --rpc-url $RPC > /dev/null
THIRD=$(python3 -c "print($BAL//3)")
cast send $CURVE1 "sell(uint256,uint256)" $THIRD 0 --private-key $PK2 --rpc-url $RPC > /dev/null
cast send $CURVE1 "buy(uint256)" 0 --value 0.3ether --private-key $PK3 --rpc-url $RPC > /dev/null
cast send $CURVE3 "buy(uint256)" 0 --value 10ether --private-key $PK --rpc-url $RPC > /dev/null
echo "== seeded: active=$CURVE1 fresh=$CURVE2 graduated=$CURVE3"

cd $ROOT/indexer
rm -f ascent.db*
RPC_URL=$RPC FACTORY_ADDRESS=$FACTORY PORT=3001 POLL_MS=800 node src/index.js > /tmp/indexer.log 2>&1 &
INDEXER_PID=$!
sleep 5
curl -s --max-time 3 localhost:3001/health || { echo "INDEXER FAILED"; cat /tmp/indexer.log; exit 1; }
echo ""
echo "== indexer up"

curl -s --max-time 3 -X POST localhost:3001/comments -H "Content-Type: application/json" \
  -d "{\"curve\":\"$CURVE1\",\"author\":\"0x70997970C51812dc3A010C7d01b50e0d17dc79C8\",\"body\":\"climbing early on this one\"}" > /dev/null
curl -s --max-time 3 -X POST localhost:3001/comments -H "Content-Type: application/json" \
  -d "{\"curve\":\"$CURVE1\",\"author\":\"anon\",\"body\":\"chart looks good so far\"}" > /dev/null
echo "== seeded 2 comments on $CURVE1"

cd $ROOT/web
VITE_FACTORY_ADDRESS=$FACTORY VITE_API_URL=http://localhost:3001 \
  VITE_CHAIN_ID=31337 VITE_CHAIN_NAME=Local VITE_RPC_URL=$RPC \
  VITE_NATIVE_SYMBOL=ETH VITE_CREATION_FEE=0.0005 \
  npm run build > /tmp/webbuild.log 2>&1 || { cat /tmp/webbuild.log; exit 1; }
python3 $ROOT/spa_server.py dist 4173 > /tmp/webserve.log 2>&1 &
WEB_PID=$!
sleep 2
curl -s --max-time 3 -o /dev/null -w "root=%{http_code}\n" localhost:4173/
echo "== web up"

mkdir -p /tmp/shots
node -e "
const { chromium } = require('playwright-core');
(async () => {
  const browser = await chromium.launch({ executablePath: '$CHROME', headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on('pageerror', e => errors.push('PAGEERROR: ' + e.message));
  page.on('console', m => { if (m.type() === 'error' && !m.text().includes('fonts.googleapis')) errors.push('CONSOLE: ' + m.text()); });

  await page.goto('http://localhost:4173/', { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(2500);
  await page.screenshot({ path: '/tmp/shots/1-explore.png', fullPage: true });
  console.log('explore captured');

  // search: filter down to the one token, confirm the others disappear
  await page.fill('.search', 'valencia');
  await page.waitForTimeout(400);
  const cardCount = await page.locator('.card').count();
  console.log('search for valencia ->', cardCount, 'card(s) (expect 1)');
  await page.screenshot({ path: '/tmp/shots/1b-search.png', fullPage: true });
  await page.fill('.search', '');
  await page.waitForTimeout(300);

  await page.goto('http://localhost:4173/t/$CURVE1', { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(3000);
  await page.screenshot({ path: '/tmp/shots/2-token-active.png', fullPage: true });
  console.log('active token captured (image + comments should be visible)');

  // anti-snipe: a deliberately oversized buy should show the cap warning
  await page.locator('.trade input').fill('3');
  await page.waitForTimeout(1500);
  const hasWarning = await page.locator('.antisnipe').count();
  console.log('anti-snipe warning visible on oversized buy:', hasWarning > 0);
  await page.screenshot({ path: '/tmp/shots/2b-antisnipe-warning.png' });
  await page.locator('.trade input').fill('');

  await page.goto('http://localhost:4173/t/$CURVE3', { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(3000);
  await page.screenshot({ path: '/tmp/shots/3-token-graduated.png', fullPage: true });
  console.log('graduated token captured');

  await page.goto('http://localhost:4173/create', { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(1500);
  await page.screenshot({ path: '/tmp/shots/4-create.png', fullPage: true });
  console.log('create captured');

  // mobile viewport pass — never verified before this round
  await page.setViewportSize({ width: 375, height: 812 });
  await page.goto('http://localhost:4173/', { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(2000);
  await page.screenshot({ path: '/tmp/shots/5-mobile-explore.png', fullPage: true });
  await page.goto('http://localhost:4173/t/$CURVE1', { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(2500);
  await page.screenshot({ path: '/tmp/shots/6-mobile-token.png', fullPage: true });
  console.log('mobile viewport captured');

  console.log('ERRORS:', errors.length ? JSON.stringify(errors, null, 2) : 'none');
  await browser.close();
})().catch(e => { console.error('SCRIPT FAIL', e.message); process.exit(1); });
"
echo "STACK_QA_DONE"
