# Paper Trading Dashboard

Static SPA (Vite + React + TypeScript + supabase-js + react-router-dom) for the
30-day paper-trading test. Implements spec Part 6 (P-22 … P-24, P-26) using the
provided design (`automated_crypto_signal_virtual_portfolio_dashboard.html`).

**Read-only.** The browser does no financial calculation: every money / percent
value comes from SQL (`004_analytics.sql`, `006_dashboard.sql`). The dashboard only
formats it (USD and % with 2 decimals, times in Europe/Sofia).

## Screens

| Route | Tab | Content (spec) |
|---|---|---|
| `/positions` | Live Signals & Open Positions | account KPIs, execution rules (read-only), **Open** positions (TP ticks, remaining %, hours, indicative P&L), **History** (closed / skipped / rejected, status filter, sorting, 50 per page), signal stream — P-24 #3 |
| `/` | Daily Performance | date picker, 8 KPI tiles from `paper_stats`, closed trades, row → modal with all fields + event timeline — P-24 #1 |
| `/calendar` | Monthly Calendar | month grid (net $, trade count, cumulative Σ), green/red with intensity ∝ \|net\|, month banner, day drill-down → "Open day"; list by day on mobile — P-24 #2 |
| `/analytics` | Analytics & Segmentation | period, KPIs, LONG vs SHORT, categories, best/worst pairs, **Segment comparison** by symbol / category / direction / tier with "small sample" (< 20) — P-24 #4 |

A global filter bar (pairs multi-select, category, direction, tier) is kept in the URL
query and applies to every screen. A warning bar appears when `paper_health_v.warning`
is true (e.g. last successful monitor run older than 3 hours).

## Prerequisites (Supabase)
1. SQL `001` … `006` applied (see `supabase/paper_trading/README.md`). `006_dashboard.sql`
   adds the aggregates the design needs (header KPIs, month banner, symbol list).
2. Authentication → Providers → Email: enabled, **magic link**.
3. Authentication → Sign In / Providers: **"Allow new users to sign up" = OFF**.
4. Authentication → Users → **Add user / Invite** exactly one user (you).
5. Authentication → URL Configuration: **Site URL** = your dashboard URL
   (e.g. `https://paper-xyz.netlify.app`) and add it to **Redirect URLs**.

## Local development
```bash
cd dashboard
```
```bash
npm ci
```
```bash
cp .env.example .env.local   # then fill VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY
```
```bash
npm run dev
```
Never put the service_role key in `.env*` — the anon key is public by design and data
is protected by RLS (`005_security.sql`).

`VITE_DEV_ACCESS_TOKEN` (not in `.env.example`) is honoured **only by `npm run dev`**
against a local test database; production builds ignore it (verified: it is not in the
bundle), so it can never bypass the login.

## Tests
```bash
npm test          # vitest: formatting (USD, %, Sofia dates), URL filters -> RPC params, calendar colouring
```
```bash
npm run build     # type-check + production build
```

## Deploy (Netlify or Vercel)
Both configs are included (`netlify.toml`, `vercel.json`: SPA rewrite + security headers,
`noindex`).
1. New site from the GitHub repo, **base directory `dashboard`**.
2. Build command `npm run build`, publish directory `dist`.
3. Environment variables: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`.
4. Deploy, then set the site URL in Supabase Auth (Prerequisites, step 5).

## Manual E2E checklist (spec P-26) — run after deploy
- [ ] Open the site in a private window: only the login screen is shown.
- [ ] Without login, `curl` with the anon key returns `permission denied` (see
      `supabase/paper_trading/README.md`, Security).
- [ ] Request a magic link for the invited email → link signs you in. A different email gets no access.
- [ ] Navigate all four tabs; header shows Monitor status and the open-position badge.
- [ ] **Daily:** pick 3 days; KPIs and table equal a direct SQL query:
      `select count(*), sum(realized_net_usd) from paper_positions where status='CLOSED' and (closed_at at time zone 'Europe/Sofia')::date = '<day>';`
- [ ] Click a trade → modal with levels, TP ticks and event timeline; Esc / × closes it.
- [ ] **Calendar:** colours (green / red / neutral), month navigation, click a day → drill-down → "Open day" opens Daily for that date.
- [ ] Empty month shows "No trades" cells / "No trades in this month" on mobile.
- [ ] **Filters:** select a pair, SHORT, T1 → KPIs, calendar and tables change consistently; the URL contains the filters; reload keeps them; Reset clears them.
- [ ] **Positions → History:** status filter, sorting and pagination (50) work.
- [ ] **Analytics:** segments with < 20 trades are marked "small sample".
- [ ] Mobile (≤ 400 px): no horizontal page scroll; calendar becomes a list; filters collapse.
- [ ] Sign out (header button) → login screen. An expired session redirects to login with a notice.

## Differences from the design file (by intent)
The design is a static mock with simulated data. Mapped to the real system:
- **Webhook API / Simulate Signal / Hit TP / Hit SL / Telegram toggle / sizing editor /
  conflict-rule selector / category editor**: removed or shown **read-only**. The dashboard
  must not write (spec P-23), signals come from N8N, exits from the hourly monitor, and the
  configuration is frozen for the test (P-30). The same panels show the real values
  (config version, sizing, costs, "Stop Loss First" rule, category mapping, exit-alert flag).
- **Mark price ticking every 1.5 s** → "Last 1h close" from the monitor's candles, and the
  P&L column is labelled **indicative** (P-20).
- **Chart.js** → the two bar charts are plain HTML/CSS (spec P-22: no chart library).
  Tailwind is used **at build time only** as the styling layer of the design.
- Brand text "NexusQuant" → "Crypto AI · Paper Trading".
- Spec additions not in the design: global filter bar on every tab, Position History tab,
  Segment Comparison table, monitor health warning bar, login screen.
