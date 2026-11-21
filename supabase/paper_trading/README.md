# Paper Trading — Supabase

Implements `PAPER_TRADING_IMPLEMENTATION_SPEC.md`. All financial logic lives in
Supabase (PL/pgSQL); N8N only moves data and the dashboard only displays it.

## Execution order (Supabase → SQL Editor)

| Step | File | Part | Status |
|---|---|---|---|
| 0 | Back up / export `telegram_signals` | P-29 | user |
| 1 | `001_schema.sql` | P-02 | **ready** |
| 2 | `002_signal_ingest.sql` | P-04 | **ready** |
| 3 | `003_engine.sql` | P-08 … P-15 | **ready (Parts 3–4)** |
| 4 | `004_analytics.sql` | P-17 … P-21, P-28 | **ready** |
| 5 | `005_security.sql` | P-23 | planned (Part 6) |

Every file is idempotent — re-running is safe. After each step run the check below.
`001_schema.sql` stops with a clear error if `public.telegram_signals` does not
exist (run `supabase/telegram_signals.sql` first).

### Check after 001
```sql
select count(*) as config_rows from paper_config;                  -- expect 1
select count(*) as categories   from paper_symbol_categories;      -- expect 3
select table_name from information_schema.tables
 where table_schema='public' and table_name like 'paper\_%' order by 1;   -- 6 tables
```
Optionally run `tests/T00_schema_structure.sql` in a **test project/branch** (see `tests/README.md`).

## P-01 — Pipeline prerequisites (user verifies in N8N) **(U)**

Repo change done: `row1/Sort & Select Top 20` now has `LIMIT = 20`
(it was `5`, a test value). **Paste the updated node code into N8N manually.**

Confirm in the live N8N canvas and tell the agent the result:
- [ ] The **active trigger** is the Schedule trigger every 2 h, 08:00–22:00 (not a manual/test trigger).
- [ ] `Supabase Signal Insert` is **connected** on the canvas (the audit found it documented but possibly not wired).
- [ ] `Sort & Select Top 20` in N8N contains `const LIMIT = 20;`.

## P-03 — Leverage decision (blocker — pick one before the test starts) **(U)**

`RISK-REWARD FILTER` currently recommends **1x** leverage almost always, so without
a decision the test would silently measure 1x only. The agent does **not** change
that node. Choose:

| Option | What | How |
|---|---|---|
| **(a)** | Deploy a new leverage model before the test | A separate task outside this spec; the test starts after it ships |
| **(b)** | Fixed leverage for the whole test | `update paper_config set leverage_override = 3 where id = 1;` (example value; capped by `max_leverage`, default 10) |

Record the decision in `paper_config` (option b) or in the changelog (option a).
Remember: leverage changes the stop/liquidation geometry (P-10), so it must not be
changed mid-test (config is frozen, P-30).

## Part 2 — Signal integration: deployment (U)

Order matters; do it in this sequence:

1. **Supabase:** run `002_signal_ingest.sql` (SQL Editor). It adds 8 nullable columns and a
   unique index on `(scan_cycle_id, symbol)`. Old rows are not touched. If the live table
   already has duplicate `(scan_cycle_id, symbol)` pairs, the file **stops, lists them and
   deletes nothing** — send the list to the agent/decide manually, then re-run.
   Check: `select count(*) from pg_indexes where indexname='uq_telegram_signals_cycle_symbol';` → 1
2. **N8N — SIGNAL LOGGER (P-05):** replace the node code with `row4/SIGNAL LOGGER`.
   It now also sends `entry_min/max`, `tp1..3_allocation`, `sl_distance_pct`, `total_score`,
   `cycle_timestamp` and fixes `score_snapshot.weights` (reads `applied_weights`).
   *Do this only after step 1* — PostgREST rejects unknown columns.
3. **N8N — insert (P-06):** follow `row4/SUPABASE SIGNAL INSERT — N8N CONFIG`:
   Custom Auth credential with the **service_role** key, IF node `Has Signals?`,
   URL with `?on_conflict=scan_cycle_id,symbol`, `Prefer: resolution=ignore-duplicates,return=minimal`,
   On Error = Continue, branch placed above Telegram.
4. Run one cycle and do the checks at the bottom of that file.

Optional: `tests/T00b_signal_ingest.sql` in a test project/branch.

## P-07 — Telegram as an optional channel

No new nodes in the main workflow. To stop Telegram messages, **deactivate the
`Send to Telegram` node** in the N8N UI (right-click → Deactivate). Signals are still
logged to `telegram_signals`, and (from Part 3) paper positions are still opened.
Re-activate the node to resume messages. Exit notifications from the monitor are
controlled separately by `paper_config.notify_telegram_on_exit` (Part 4).

## Part 3 — Position engine: deployment (U)

1. **Supabase:** run `003_engine.sql` (after 001 and 002). It creates
   `paper_open_position()` and the trigger `paper_on_signal_insert` on `telegram_signals`.
   From this moment **every new signal** gets exactly one row in `paper_positions`.
2. Nothing changes in N8N for this part.

### What happens to each signal (P-08)
| Check (in this order) | Result |
|---|---|
| `paper_config.enabled = false` | SKIPPED `PAPER_DISABLED` |
| direction not LONG/SHORT | REJECTED `INVALID_DIRECTION` |
| entry / SL / TP1 missing or ≤ 0 | REJECTED `INVALID_LEVELS` |
| wrong level order (missing TP2/TP3 = previous level) | REJECTED `INVALID_LEVEL_ORDER` |
| allocations ≠ 100 ± 0.5 (all missing → 40/40/20, reason `DEFAULT_ALLOCATION`) | REJECTED `INVALID_ALLOCATION` |
| tier has no slippage in `paper_config` | REJECTED `NO_SLIPPAGE_FOR_TIER` |
| `sent_at − cycle_timestamp > max_signal_age_minutes` | REJECTED `STALE_SIGNAL` |
| an OPEN position exists for the symbol (any direction) | SKIPPED `DUPLICATE_OPEN_POSITION` (+ `related_position_id`) |
| OPEN count ≥ `max_open_positions` | SKIPPED `MAX_OPEN_POSITIONS` |
| margin > free capital | SKIPPED `INSUFFICIENT_VIRTUAL_BALANCE` |
| otherwise | **OPEN** + `OPENED` event |
| any unexpected error | REJECTED `INTERNAL_ERROR: …` + `ERROR` event — **the signal is still saved** |

Reasons that carry numbers keep them after a colon, e.g.
`STALE_SIGNAL: 52.3 min old (max 45)`. Filter with `status_reason LIKE 'STALE_SIGNAL%'`.

### Checks after 003
```sql
-- trigger installed
select tgname from pg_trigger where tgname = 'paper_on_signal_insert';          -- 1 row
-- after the next N8N cycle: every NEW signal has exactly one position
select s.id, s.symbol, s.created_at
  from telegram_signals s left join paper_positions p on p.signal_id = s.id
 where p.id is null order by s.id desc;
-- expected: only signals created BEFORE 003 was applied (legacy rows, see below)
select status, status_reason, count(*) from paper_positions group by 1,2 order by 1,2;
```

**Legacy signals:** rows already in `telegram_signals` before 003 do **not** get a
position (the trigger fires only on new inserts, and opening them now would be
look-ahead). Daily 1:1 checks therefore count only signals after the deployment.

## Part 4 — Monitoring and exit simulation: deployment (U)

1. **Supabase:** re-run `003_engine.sql` (it is idempotent; the Part 4 section adds
   `paper_get_monitor_targets`, `paper_ingest_candles`, `paper_evaluate_positions`).
2. **N8N:** create the new workflow **PAPER MONITOR** exactly as described in
   `monitor/PAPER MONITOR — N8N CONFIG`; paste `monitor/PAPER CANDLE NORMALIZER`
   into its Code node. Run it manually once (checks in section 11 of that file), then activate.
3. Optional exit messages: `update paper_config set notify_telegram_on_exit = true where id = 1;`

### Exit rules (P-14), in short
- Only **closed** 1h candles, from the first full hour after the signal, in time order.
  A per-position cursor (`last_evaluated_open_time`) makes every run idempotent and lets
  one run catch up any number of missed hours.
- **Stop first:** if a candle touches the stop, it wins over any TP in the same candle.
  Gap through the stop → fill at the candle open. Adverse slippage by tier.
- **TPs** fill at the level (never better), several per candle allowed, in order.
  TP3 closes the whole remainder.
- **Break-even** (if enabled) is armed in the TP1 candle and active from the next one.
- **TIMEOUT** at the close of the candle in which `max_holding_hours` elapse.
- **LIQUIDATION** when the stop was capped by the liquidation price: that share's margin is lost.
- **DATA_UNAVAILABLE** after `max_holding_hours + 24h` with no candle at all.
- Costs/rules are taken from the position's `config_snapshot` (config at open time).

### Daily checks
```sql
select status, count(*), max(started_at) from paper_monitor_runs
 where started_at > now() - interval '24 hours' group by 1;            -- mostly OK
select * from paper_monitor_runs where status <> 'OK' order by id desc limit 10;
select id, symbol, last_evaluated_open_time from paper_positions
 where status = 'OPEN' and coalesce(last_evaluated_open_time, eval_start_open_time)
       < now() - interval '3 hours';                                   -- should be empty
```

## Part 5 — History and analytics: deployment (U)

Run `004_analytics.sql` (after 001–003). Nothing changes in N8N.

| Object | What it is | Who may use it |
|---|---|---|
| `paper_positions_v` | positions + `closed_date_local`, `outcome` (WIN/LOSS/BREAKEVEN), `avg_exit_price`, `price_move_pct`, `partially_realized_net_usd`, `indicative_unrealized_usd`, `last_price`, `hours_open` | authenticated (read) |
| `paper_stats(p_from, p_to, p_symbols, p_categories, p_direction, p_tiers)` | one JSON with the P-18 metrics (+ extras: partially realised, indicative unrealised, max drawdown) | authenticated |
| `paper_daily_pnl(p_month, …filters)` | one row per day of the month, cumulative from 0 | authenticated |
| `paper_stats_breakdown(p_dimension, p_from, p_to, …filters)` | `paper_stats` per symbol / category / direction / tier, `small_sample` < 20 trades | authenticated |
| `paper_health_v` | last OK monitor run, stale OPEN positions, data gaps, INTERNAL_ERRORs, signals without a position, `warning` | authenticated (read) |
| `paper_recompute_position(p_id, p_reason)` | reset a position to OPEN; the next monitor run re-evaluates it | **service_role only** |

Rules (P-20): a trade counts on the day it was **fully closed** in Europe/Sofia.
Profit already taken on an OPEN position and the indicative unrealised P&L are
shown separately and never enter any metric. Filters: `NULL` or an empty array = all.

### Quick checks
```sql
select public.paper_stats(current_date - 7, current_date);
select * from public.paper_daily_pnl(current_date);
select * from public.paper_health_v;
```

### Recompute (validation / proven rule error only)
```sql
select public.paper_recompute_position(<id>, 'why');   -- SQL Editor runs as postgres = allowed
```
The previous result is kept in the `OPENED` event under `details -> 'recompute_log'`.
It refuses SKIPPED/REJECTED positions, and positions whose symbol already has another
OPEN position (reopening would break the one-open-per-symbol rule).

> **Security note:** until `005_security.sql` (RLS) is applied, the `paper_*` tables are
> reachable with the anon key through the REST API (Supabase grants table access by
> default). Apply 005 before sharing the anon key anywhere (e.g. the dashboard).

## Configuration

Single row `paper_config` (id = 1). Every real change increments `config_version`
automatically (no-op updates do not). Defaults follow the spec (1000 $ capital,
50 $ fixed margin, fee 0.055 %/side, slippage 0.05/0.10/0.20 % by tier, 72 h max hold,
10 max open, 45 min stale threshold, timezone Europe/Sofia).
