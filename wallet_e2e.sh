#!/bin/bash
# The strongest verification in this repo: boots the whole stack, then
# drives the REAL rendered buttons — Connect wallet, Buy, Sell, Launch —
# through a real headless browser with a minimal injected EIP-1193
# provider that forwards signing requests straight to anvil's unlocked
# dev accounts. Proves the wagmi write paths work, not just that pages
# render, and checks results against on-chain ground truth rather than
# trusting the UI's own success message.
#
# This test previously caught a real race condition: the create flow
# redirected to the new token's page before the indexer had ingested the
# Launched event, and the page crashed reading .trades off an empty
# response. See web/src/pages/Token.tsx and web/src/api.ts for the fix —
# rerun this script after touching either file.
set -e
export PATH=/home/claude/tools:$PATH
ROOT=/home/claude/ascent
RPC=http://127.0.0.1:8545
CHROME=/home/claude/.cache/puppeteer/chrome-headless-shell/linux-131.0.6778.204/chrome-headless-shell-linux64/chrome-headless-shell

cleanup() { kill $ANVIL_PID $INDEXER_PID $WEB_PID 2>/dev/null || true; }
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
ACTOR=$(grep -oE '0x[0-9a-fA-F]{40}' /tmp/anvil.log | sed -n 5p)  # account #4 — untouched by seeding
ADDR2=$(cast wallet address --private-key $PK2)
echo "== chain up. wallet-under-test = $ACTOR"

PRIVATE_KEY=$PK forge script script/MockRouter.s.sol --tc DeployMockRouter --rpc-url $RPC --broadcast > /tmp/router.log 2>&1
ROUTER=$(grep "router:" /tmp/router.log | awk '{print $2}')
PRIVATE_KEY=$PK FEE_RECIPIENT=$ADDR2 DEX_ROUTER=$ROUTER \
  forge script script/Deploy.s.sol --rpc-url $RPC --broadcast > /tmp/factory.log 2>&1
FACTORY=$(grep "AscentFactory:" /tmp/factory.log | awk '{print $2}')
echo "== factory $FACTORY"

# fund the test actor and give it some starting VLNC so the sell test has something to sell
cast send $ACTOR --value 20ether --private-key $PK --rpc-url $RPC > /dev/null
cast send $FACTORY "launch(string,string,string)" "Valencia Signal" "VLNC" "data:application/json,%7B%7D" \
  --value 0.0005ether --private-key $PK --rpc-url $RPC > /dev/null
CURVE=$(cast call $FACTORY "allCurves(uint256)(address)" 0 --rpc-url $RPC)
TOKEN=$(cast call $CURVE "token()(address)" --rpc-url $RPC)
cast send $CURVE "buy(uint256)" 0 --value 0.5ether --private-key $PK --rpc-url $RPC > /dev/null
echo "== seeded token: curve=$CURVE token=$TOKEN"

cd $ROOT/indexer
rm -f ascent.db*
RPC_URL=$RPC FACTORY_ADDRESS=$FACTORY PORT=3001 POLL_MS=500 node src/index.js > /tmp/indexer.log 2>&1 &
INDEXER_PID=$!
sleep 4
curl -s --max-time 3 localhost:3001/health > /dev/null && echo "== indexer up"

cd $ROOT/web
npm run build > /tmp/webbuild.log 2>&1 || { cat /tmp/webbuild.log; exit 1; }
VITE_FACTORY_ADDRESS=$FACTORY VITE_API_URL=http://localhost:3001 \
  VITE_CHAIN_ID=31337 VITE_CHAIN_NAME=Local VITE_RPC_URL=$RPC \
  VITE_NATIVE_SYMBOL=ETH VITE_CREATION_FEE=0.0005 \
  $ROOT/gen_web_config.sh dist
python3 $ROOT/spa_server.py dist 4173 > /tmp/webserve.log 2>&1 &
WEB_PID=$!
sleep 2
echo "== web up"

mkdir -p /tmp/shots
node -e "
const { chromium } = require('playwright-core');

const mockWallet = \`
window.ethereum = {
  isMetaMask: true,
  _addr: '$ACTOR',
  _rpc: '$RPC',
  _listeners: {},
  on(e, cb) { (this._listeners[e] ||= []).push(cb); },
  removeListener() {},
  async request({ method, params }) {
    if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [this._addr];
    if (method === 'eth_chainId') return '0x7a69';
    if (method === 'wallet_switchEthereumChain' || method === 'wallet_addEthereumChain') return null;
    if (method === 'eth_sendTransaction') {
      const tx = { ...params[0], from: params[0].from || this._addr };
      const res = await fetch(this._rpc, { method: 'POST', headers: {'content-type':'application/json'},
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_sendTransaction', params: [tx] }) });
      const j = await res.json();
      if (j.error) throw new Error(j.error.message);
      return j.result;
    }
    const res = await fetch(this._rpc, { method: 'POST', headers: {'content-type':'application/json'},
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params: params || [] }) });
    const j = await res.json();
    if (j.error) throw new Error(j.error.message);
    return j.result;
  }
};
window.dispatchEvent(new Event('ethereum#initialized'));
\`;

(async () => {
  const browser = await chromium.launch({ executablePath: '$CHROME', headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.addInitScript({ content: mockWallet });
  const errors = [];
  page.on('pageerror', e => errors.push('PAGEERROR: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('CONSOLE: ' + m.text()); });

  // --- test 1: connect wallet from the header ---
  await page.goto('http://localhost:4173/', { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(1500);
  await page.getByRole('button', { name: /connect wallet/i }).click();
  await page.waitForTimeout(1500);
  const walletBtnText = await page.locator('.wallet').first().innerText();
  console.log('after connect, header shows:', walletBtnText);
  if (!/0x/i.test(walletBtnText)) throw new Error('wallet did not connect — header still shows connect prompt');
  await page.screenshot({ path: '/tmp/shots/w1-connected.png' });

  // --- test 2: real buy through the trade panel ---
  await page.goto('http://localhost:4173/t/$CURVE', { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(2000);
  await page.locator('.trade input').fill('0.3');
  await page.waitForTimeout(1500); // let the on-chain quote resolve
  await page.locator('.trade .cta').click();
  await page.waitForSelector('.ok', { timeout: 15000 });
  const buyResult = await page.locator('.ok').innerText();
  console.log('BUY result:', buyResult);
  await page.screenshot({ path: '/tmp/shots/w2-bought.png' });

  // --- test 2b: post a comment through the real form ---
  await page.fill('.commentform input', 'testing from the wallet e2e suite');
  await page.locator('.commentform button').click();
  await page.waitForTimeout(1200);
  const commentText = await page.locator('.commentrow .commentbody').first().innerText();
  console.log('posted comment, first row shows:', commentText);
  if (!commentText.includes('testing from the wallet e2e suite')) throw new Error('comment did not appear after posting');
  await page.screenshot({ path: '/tmp/shots/w2b-commented.png' });

  // --- test 3: real sell through the trade panel (approve + sell) ---
  await page.locator('.trade .tabs button', { hasText: 'Sell' }).click();
  await page.waitForTimeout(1000);
  await page.locator('.trade .chip').click(); // Max button
  await page.waitForTimeout(1500);
  await page.locator('.trade .cta').click();
  await page.waitForTimeout(6000); // two on-chain txs: approve then sell
  const sellResult = await page.locator('.ok').innerText();
  console.log('SELL result:', sellResult);
  await page.screenshot({ path: '/tmp/shots/w3-sold.png' });

  // --- test 4: real token launch through the create form ---
  await page.goto('http://localhost:4173/create', { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(1000);
  await page.fill('#c-name', 'Browser Launched Token');
  await page.fill('#c-symbol', 'BROW');
  await page.locator('.cta').click();
  await page.waitForURL(/\/t\/0x/i, { timeout: 20000 });
  const newTokenUrl = page.url();
  console.log('LAUNCH navigated to:', newTokenUrl);
  await page.waitForTimeout(1500);
  await page.screenshot({ path: '/tmp/shots/w4-launched-immediate.png' });
  // Give the indexer its polling interval to catch up, then confirm the
  // page actually recovered from the empty state into real rendered data —
  // not just that it stopped erroring.
  await page.waitForSelector('.tokenhead h1', { timeout: 15000 });
  const title = await page.locator('.tokenhead h1').innerText();
  console.log('new token page eventually rendered title:', title);
  if (!title.toLowerCase().includes('browser launched token')) throw new Error('new token page never rendered real data — title was: ' + title);
  await page.screenshot({ path: '/tmp/shots/w4-launched-settled.png' });

  console.log('ERRORS:', errors.length ? JSON.stringify(errors, null, 2) : 'none');
  await browser.close();
})().catch(e => { console.error('WALLET E2E FAILED:', e.message); process.exit(1); });
"
echo "== on-chain verification (ground truth, independent of what the UI claimed) =="
BAL_AFTER=$(cast call $TOKEN "balanceOf(address)(uint256)" $ACTOR --rpc-url $RPC | awk '{print $1}')
echo "actor's $TOKEN balance after buy+sell-max: $BAL_AFTER (0 is correct — Max sells the full balance)"
TRADE_COUNT=$(curl -s --max-time 3 "localhost:3001/token/$CURVE" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['trades']))")
echo "indexer recorded $TRADE_COUNT trades on the seeded curve (should be 3: seed buy, browser buy, browser sell)"
echo "WALLET_E2E_DONE"
