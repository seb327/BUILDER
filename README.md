# ASCENT

A token launchpad on a transparent bonding curve. Fixed supply, no premine, no
admin keys, automatic graduation to a DEX with the LP burned. Built as a
complete, deployable stack: contracts, indexer, web app.

**The climb is public.**

## How it works

Every launch creates two contracts in one transaction:

- **AscentToken** — 1,000,000,000 fixed supply ERC20. No mint function, no
  owner, no tax hooks. Transfers are locked until graduation so early buyers
  cannot trade sideways around the curve.
- **AscentCurve** — a constant product curve (x·y=k with a virtual reserve)
  that sells 800M tokens. A 1% fee on each trade goes to the fee recipient.
  When the real reserve reaches the graduation target, the remaining 200M
  tokens plus all raised funds are deposited into a UniswapV2 style pool and
  the LP tokens are sent to the dead address. Nobody can pull liquidity —
  including the platform.

**Anti-snipe cap.** Every single buy transaction is capped at a configurable
percentage of the curve's sale supply (default 3%). A buy larger than the
cap automatically fills up to the limit and refunds the rest — it doesn't
revert, so it isn't a hard block on large buyers, just a hard block on
*instant* large buyers. At 3%, sniping the entire curve alone takes at least
~34 separate transactions instead of one, which is enough friction to give
other participants a real chance to see and react to a launch. This directly
targets the most consistently cited weakness of pump.fun in 2026 market
coverage: sniper bots (Photon, BullX) buying out fresh launches in the same
block they appear, before any human can react. Pump.fun itself has no such
cap. The UI surfaces this proactively — the trade panel warns before you
submit a buy that would come back partially refunded, rather than
surprising you after the fact.

Default economics (all configurable at factory deployment):

| Parameter | Default |
|---|---|
| Total supply | 1,000,000,000 |
| Curve tranche | 800,000,000 |
| LP tranche | 200,000,000 |
| Virtual reserve | 1.2 native |
| Graduation target | 4.8 native raised |
| Trade fee | 1% |
| Creation fee | 0.0005 native |
| Anti-snipe cap | 3% of curve supply per tx |

## Product features

- Explore grid with search (name/ticker), four sort modes, and a live
  "🔥 Trending" badge on the highest-volume token still on the curve.
- Token images: the create form accepts an image URL (including `ipfs://`,
  resolved through a public gateway); tokens without one get a deterministic
  on-brand monogram instead of a broken image icon.
- Comments per token — see the honesty note below on what this is and isn't.
- Mobile-responsive down to 375px, verified with real headless-browser
  screenshots at that width, not just CSS that looks plausible.
- Self-hosted OFL fonts, on-brand favicon, dynamic per-token page titles.

## What is verified

- **24 forge tests, all passing**, including 6 fuzz properties run at
  10,000–20,000 iterations each: round trips are never profitable, quotes
  always equal execution, the curve is always solvent, and — new in this
  round — the anti-snipe cap is never exceeded even by rounding dust and
  never creates insolvency. That last one is worth being honest about: my
  first attempt at the anti-snipe cap *did* introduce a real 2-wei
  insolvency bug, caught by the existing solvency fuzz test after the
  change. Fixed by making the fee calculation shrink to fit whatever was
  actually paid in in the rare case where rounding would otherwise let a
  clamped buy's `fee + refund` exceed `ethIn`. Then re-verified at 20,000
  fuzz runs specifically on that property before trusting it again.
- Reentrancy attack test, reserve drain test, transfer lock tests,
  graduation overshoot refund test, anti-snipe clamp/refund test, anti-snipe
  quote-accuracy test.
- **Full end to end integration test** (`./e2e.sh`) and **full stack visual
  verification** (`./qa_run.sh`) — the latter now also seeds real comments,
  exercises search, triggers the anti-snipe warning with an oversized buy,
  and captures a real 375px mobile viewport, not just the 1280px desktop
  pass from before.
- **Wallet-driven end to end test** (`./wallet_e2e.sh`) — clicks Connect,
  Buy, Sell, post a Comment, and Launch through the real UI with a mock
  EIP-1193 provider, verified against on-chain ground truth. This is the
  test that has caught every real bug so far, including the original
  indexer race condition and, this round, confirms comment posting works
  end to end through the actual form, not just via direct API calls.
- Typefaces are self hosted under `web/public/fonts` (OFL licensed, license
  files included) rather than pulled from a third party font CDN at runtime,
  so the deployed site has no external dependency for its core visual
  identity.

## Honesty notes on the newer features

**Comments are not wallet-signed or moderated.** Anyone can POST a comment
as any author string — there's no signature verification tying a comment to
the wallet that supposedly posted it, and no profanity or spam filtering
beyond a length cap and a per-IP rate limit (5 posts/minute). The UI says
this plainly to users too. Real production use would want EIP-191 signature
verification on comment submission (proving the author field is who they
claim) and probably a moderation queue — both are natural follow-ups, not
done here to keep scope honest.

**Rate limiting is single-instance.** The indexer's rate limiter is an
in-memory sliding window. It works correctly for one indexer process, which
is what the deploy runbook here produces. If you ever scale the indexer
horizontally behind a load balancer, per-instance in-memory limits stop
being meaningful and you'd want a shared store (Redis) instead.

**The Content-Security-Policy in `nginx.conf` is intentionally loose** on
`img-src` and `connect-src` (allows any `https:` host) because token images
and the indexer/RPC URLs are runtime configuration, not fixed at build time
in this repo. Once you know your actual deployed domains, tightening those
two directives to your specific indexer and RPC hosts is a real, easy
hardening step — just not one that can be done generically here.

## Regulatory context, current as of writing

Pump.fun — the platform this project is most directly compared against —
is currently facing a US class-action lawsuit alleging its bonding curve
mechanism constitutes an unregistered securities offering under the Howey
test, and the UK Financial Conduct Authority has issued warnings about this
category of platform. Source:
https://www.dextools.io/tutorials/what-is-pump-fun-solana-memecoin-launchpad-2026
Neither of these establishes that bonding curve launchpads *are* illegal,
and the legal status of this category is actively being litigated, not
settled — but it means the earlier advice in this README to get a lawyer's
opinion before a public launch isn't a generic disclaimer, it's a live
question with real cases attached. Take it seriously.

## What "finished" means here, honestly

Everything above was built, tested, and visually confirmed working inside
this environment: contracts compiled and fuzzed, the indexer ingesting real
chain events, the web app fetching real API data and rendering correctly
against a real browser. That is the strongest proof obtainable without your
own infrastructure.

Two things only you can finish, because they need credentials and accounts
this environment doesn't have:

1. **A funded key and a real RPC** for the chain you're launching on, so
   `forge script script/Deploy.s.sol --broadcast` writes to a real network
   instead of a local anvil instance.
2. **Hosting accounts** (Railway or otherwise) for the indexer and the web
   app, so they get a public URL instead of running on localhost.

The runbook below is the exact two-step process for both. Neither step
involves writing new code — the Dockerfiles, env templates, and deploy
script are already the production artifacts.

## Repository layout

```
contracts/   Foundry project — AscentToken, AscentCurve, AscentFactory,
             tests, deploy script
indexer/     Node service — ingests chain events into SQLite, serves the
             REST API and a live SSE feed
web/         Vite + React + wagmi app — explore, token pages with candle
             charts and live trades, create flow
e2e.sh       full stack integration test against a local anvil chain
qa_run.sh    full stack boot + seeded data + real headless browser screenshots
             of every page (explore, active token, graduated token, create)
wallet_e2e.sh  the real test: clicks Connect/Buy/Sell/Launch/Comment through
               a mock wallet provider and checks on-chain ground truth
test_factory_switch.sh  verifies changing FACTORY_ADDRESS mid-flight resets
                         indexer state cleanly instead of mixing two factories
gen_web_config.sh  test-harness copy of web/docker-entrypoint.sh's config
                    generation, so qa_run.sh/wallet_e2e.sh exercise the exact
                    mechanism Railway uses without needing Docker in CI
spa_server.py  SPA-aware static server used by qa_run.sh, mirrors nginx.conf
```

## Deploy runbook

You need: a funded deployer key, the target chain RPC, the address of a
UniswapV2 compatible router on that chain (for graduation liquidity), and a
free Railway account.

### 1. Contracts (always manual — Railway doesn't do this part)

```bash
cd contracts
cp .env.example .env   # fill in PRIVATE_KEY, FEE_RECIPIENT, DEX_ROUTER
source .env
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

Note the printed `AscentFactory` address — both services below need it.

### 2. Push this repo to GitHub

This directory is already a git repository with one commit. Point it at your
own remote and push:

```bash
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

### 3. Connect Railway to that repo (the normal way, via the dashboard)

**Important, learned the hard way:** Railway does *not* auto-discover
`railway.json` inside a subdirectory just because you set Root Directory to
that subdirectory. Per Railway's own docs, config-as-code file discovery
does not follow the Root Directory setting — by default Railway only looks
for `railway.json`/`railway.toml` at the actual repo root. A `railway.json`
sitting in `indexer/` or `web/` is invisible to Railway unless you either
point at it explicitly (Settings → Custom Config File → `indexer/railway.json`
or `web/railway.json`, repo-root-relative) or skip config-as-code for the
builder choice entirely and set it directly in the dashboard, which is the
more reliable option and what's below. `railway.json` files are still
committed in both folders — set the Custom Config File path if you want
Railway to pick up the health check settings from them too, but the Builder
dropdown alone is enough to fix a build that's running Railpack/Nixpacks
instead of your Dockerfile.

**Indexer service:**
1. Railway dashboard → New Project → Deploy from GitHub repo → select this repo.
2. Settings → Source → Root Directory → `indexer`.
3. Settings → Build → Builder → **Dockerfile** (don't leave this on the
   default — that's what silently produces a generic Railpack build
   failure with no useful error, regardless of any railway.json present).
4. Variables: set `RPC_URL`, `FACTORY_ADDRESS` (from step 1), `VIRTUAL_ETH`,
   `GRADUATION_ETH`, `DB_PATH=/data/ascent.db` — see `indexer/.env.example`.
5. Settings → Volumes → add a volume mounted at `/data` (SQLite needs a
   persistent disk, or the token history resets on every redeploy).
6. Deploy, then Settings → Networking → Generate Domain. Note the URL.
7. Settings → Deploy → Healthcheck Path → `/health` (same caveat as the
   Builder setting — don't assume `railway.json` is supplying this
   automatically; set it directly).
8. All of these are genuinely live-adjustable afterwards: change a Variable,
   Railway restarts the service, the new value takes effect immediately —
   including `FACTORY_ADDRESS`. Pointing the indexer at a different,
   redeployed factory is explicitly handled: the indexer detects the change
   on startup and resets its indexed state instead of silently mixing data
   from two different contracts. See `test_factory_switch.sh` for the
   verification of this.

**Web service:**
1. Same repo, new service → Root Directory → `web`.
2. Settings → Build → Builder → **Dockerfile** (same note as above — this
   is a separate setting from Root Directory and from `railway.json`).
3. Variables: `VITE_FACTORY_ADDRESS`, `VITE_API_URL` (the indexer domain
   from above), `VITE_CHAIN_ID`, `VITE_CHAIN_NAME`, `VITE_RPC_URL`,
   `VITE_NATIVE_SYMBOL`, `VITE_CREATION_FEE` — see `web/.env.example`.
4. Deploy, then generate a domain the same way.

**These web variables are true runtime configuration, not Docker build
args.** A small entrypoint script (`web/docker-entrypoint.sh`) regenerates
`config.js` from the container's live environment variables every time it
starts, before nginx serves anything — the app reads `window.__ASCENT_CONFIG__`
from that file in preference to anything baked in at build time. Practically:
change any `VITE_*` variable in the Railway dashboard afterwards and hit
**Restart** (not redeploy) — it takes effect in seconds, no rebuild needed.
This was a real gap in an earlier version of this repo (variables were
Docker build args, meaning a "quick" config change silently required a full
rebuild) and is now fixed and verified: built once, then proved that
changing the variables and only restarting — never rebuilding — changes
what the running app actually uses, checked in a real browser reading
`window.__ASCENT_CONFIG__` directly.

That's the whole path: push, connect, fill in variables, deploy. Both
Dockerfiles were verified in this environment by running their exact build
steps (`npm ci`, then the production build) against a clean clone of this
same repository, so what Railway runs is what was tested.

### Troubleshooting: "railpack process exited with an error"

If you see this — especially if it mentions **"railpack"** by name, and
especially if it persists across multiple deploy attempts — it almost
certainly means Railway isn't using this repo's Dockerfile at all, despite
`railway.json` being present. Root Directory does not make Railway
auto-discover a `railway.json` inside that subdirectory (confirmed in
Railway's own monorepo docs: "The Railway Config File does not follow the
Root Directory path"). With no config file found at the actual repo root,
Railway silently falls back to Railpack auto-detection on whatever
directory it *is* looking at, which fails with exactly this generic message
since a subdirectory with a Dockerfile doesn't look like anything Railpack
knows how to build on its own.

**Fix:** Settings → Build → Builder → set it to **Dockerfile** directly in
the dashboard for that service. This bypasses config-file discovery
entirely and was enough to resolve this in testing. If you'd rather rely on
`railway.json` (it also sets the indexer's health check path), use Settings
→ Custom Config File and give the repo-root-relative path explicitly —
`indexer/railway.json` or `web/railway.json` — rather than assuming it's
picked up automatically.

Separately, and worth ruling out if the above doesn't fix it: Railway's
newer "Metal builder" infrastructure has its own independent history of
generic build failures unrelated to what's being built — Settings → Build →
turn it off and redeploy if switching the Builder to Dockerfile doesn't
resolve things on its own.

### The alternative: one script, no dashboard clicking

If you'd rather not click through the dashboard, `deploy_live.sh` does all
of the above from your terminal using the Railway CLI (`login`, `init`,
`variable set`, `up`, `domain`, in the right order with the right
dependencies resolved automatically). Fill in the six values at the top and
run it. Its contract-deploy step was run against a live local chain during
development and confirmed working; the Railway CLI steps use verified
command syntax but need your own account to authenticate, so they could not
be executed inside this build environment.

Worth knowing given the Railpack troubleshooting note above: `railway up`
runs from inside `indexer/` or `web/` and uploads that directory directly as
the build context, with the Dockerfile sitting right at its root — there's
no Root Directory subdirectory-selection step involved at all, so this path
isn't exposed to the same config-discovery gap the dashboard GitHub-connect
flow hit. If the dashboard route keeps fighting you, this script sidesteps
the whole problem.

### Local development

```bash
# terminal 1 — chain
anvil

# terminal 2 — everything else, fully automated
./e2e.sh          # deploys, launches a demo token, trades it, starts nothing
                  # persistent; or run the pieces by hand:
cd indexer && RPC_URL=http://127.0.0.1:8545 FACTORY_ADDRESS=0x... npm start
cd web && npm run dev
```

## API

| Endpoint | Returns |
|---|---|
| `GET /tokens?sort=newest\|mcap\|active\|volume` | token list with price, market cap, volume, graduation progress, comment count |
| `GET /token/:curve` | token detail plus last 100 trades |
| `GET /candles/:curve` | 5 minute OHLC candles |
| `GET /comments/:curve` | up to 200 most recent comments |
| `POST /comments` | `{curve, author, body}` — 280 char cap, 5/minute per IP, unsigned (see honesty note above) |
| `GET /feed` | SSE stream: `launch`, `trade`, `graduated` events |
| `GET /health` | indexer cursor |

## Security posture, honestly stated

The economic invariants are fuzz tested and the attack surface is small by
design: no upgradability, no owner functions, no oracle, no external calls
except the router at graduation. That said, **this code has not had a third
party audit**. If real funds will flow through it at scale, commission one
before mainnet — this is doubly true now that the contracts have real
economic logic (the anti-snipe clamp) beyond a textbook bonding curve, which
is exactly the kind of custom logic where audits earn their cost. Token
launch platforms also carry regulatory obligations that vary by
jurisdiction — take legal advice before a public launch, and see the
regulatory context note above.

The one new server-side attack surface in this round is the comments POST
endpoint — rate limited and length capped, but unsigned and unmoderated, as
noted above. It's a spam and abuse surface, not a funds-at-risk surface: it
can't touch the contracts, the indexer's own database, or anyone's assets.
Worth knowing about before a public launch regardless.

## Licence

MIT.
