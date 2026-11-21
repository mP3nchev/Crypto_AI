# Technical & Functional Specification: Paper Trading System

**Version:** 1.0 · **Date:** 2026-11-21 · **Based on:** `PAPER_TRADING_FEASIBILITY_AUDIT_2026-11-21.md`
**Audience:** AI coding agent with access to `mp3nchev/crypto_ai`, branch `claude/system-audit-3gDsG`
**Language:** code, comments, and documentation in English. A Bulgarian copy of this spec is kept in `PAPER_TRADING_IMPLEMENTATION_SPEC_BG.md`.

---

## 0. Executive Overview

This system adds an automated 30-day virtual-money test to the existing signal pipeline. Every signal selected for Telegram opens a virtual position in Supabase. A separate small N8N workflow runs hourly, fetches closed 1h candles from Binance for the symbols with open positions, and a Supabase SQL function evaluates TP and SL using deterministic rules and records partial and full exits. A static web dashboard reads the precomputed aggregates from Supabase and shows daily statistics, trade details, a monthly calendar, and filters.

**Final architectural decisions:**
1. **Logic lives in Supabase** (PL/pgSQL). N8N only moves data, and the frontend only displays it. No financial calculation is done in N8N or in the browser.
2. **The signal logic in Rows 1–4 does not change.** The only modified node is `SIGNAL LOGGER`, which gets additional fields.
3. **A DB trigger on `telegram_signals` opens the position.** A failure in the paper logic must never block saving the signal or sending Telegram.
4. **Monitoring is a separate workflow**, not part of the heavy main one. Failures in one do not affect the other.
5. **Exits are evaluated on High/Low of closed candles**, with a per-position cursor. Results do not depend on how often or exactly when the monitor runs.
6. **The dashboard is a new minimal SPA** (Vite + React + TypeScript + supabase-js), because the repo has no frontend.

---

## 1. Mandatory Rules for the AI Agent

1. Read every file fully before changing it. Follow existing conventions: extensionless N8N Code-node files in `row*/`, SQL in `supabase/`, change tags in the form `[P-xx]` in comments (like `[T-09]` and `[B-03]`).
2. Execute the parts in the order given in Section 9. **Do not start a part until the acceptance criteria of the previous one are met.**
3. **Do not modify** anything in `row1/` to `row4/` except what is explicitly listed. In particular: scoring, TP-SL CALCULATOR, RISK-REWARD FILTER, and ranking.
4. You have no access to N8N or to the crypto Supabase project. Your deliverable is **files in the repo plus step-by-step deployment instructions**. The user applies them manually. Criteria marked **(U)** are verified by the user in the live system.
5. Every SQL file is idempotent (`IF NOT EXISTS`, `CREATE OR REPLACE`) and can be re-run safely.
6. Never bypass or delete a failing test. Stop, describe the cause, and propose the smallest fix.
7. **Stop rule:** if you find a discrepancy with this spec (missing field, different node name, different schema), stop that task, describe the discrepancy, and propose the smallest adjustment. Do not improvise.
8. Commits are small, per task, with the prefix `feat(paper):`, `test(paper):`, or `docs(paper):`.

---

## 2. Existing Architecture and Constraints

### 2.1 Components (verified in the code)

| Component | File | Role for paper trading |
|---|---|---|
| Universe selection | `row1/Sort & Select Top 20` | `LIMIT = 5` is a test value and must be 20 |
| Candles | `row1/Bulk Requests Generator Binance Candles` | 1h × 12, only for the current top N. Not suitable for monitoring |
| Binance host | `api.binance.com/api/v3/klines` (spot) | The monitor uses the **same** endpoint for consistency |
| TP/SL | `row4/TP-SL CALCULATOR` | `entry_price`, `stop_loss`, `take_profit_1..3`, `tp1..3_allocation`, `tp_strategy`, `sl_distance_pct`, fee 0.00055 per side |
| Leverage | `row4/RISK-REWARD FILTER` | `recommended_leverage` is practically always 1x. See P-03 |
| Entry zone | `row4/TECHNICAL LEVEL IDENTIFIER` | `entry_min`, `entry_max`, `entry_zone_type` |
| Selection | `row4/SIGNAL RANKING & TOP 5 SELECTION` | `selected_for_telegram = true`, `final_rank`, up to 5 signals |
| Logger | `row4/SIGNAL LOGGER` | Builds `_signal_logger_payload`. Reads `weight_*`, but Row 4 carries `applied_weights` (SCORE AGGREGATOR:322), so weights are `null` |
| Insert | `row4/SUPABASE SIGNAL INSERT — N8N CONFIG` | HTTP POST to `telegram_signals`, documented with the **anon** key |
| Table | `supabase/telegram_signals.sql` | DDL with no unique key and no status |

### 2.2 Constraints
- N8N Cloud free plan: no `$env`, node changes are applied manually, and the execution quota is unverified. An hourly monitor means about 720 executions per month. If the quota is insufficient, the interval becomes 2h; correctness is not affected.
- The crypto Supabase project was not accessible during the audit. The agent **must not assume** the schema of `raw_candles_data`, `scan_results`, etc., and must not depend on them.
- There are no break-even, trailing-stop, or maximum-holding rules. This spec defines them for the simulation only and does **not** change the strategy.

---

## 3. Target Architecture

```
MAIN WORKFLOW (logic unchanged)
 Row 4 → SIGNAL LOGGER (extended, P-05)
           ├─(output 1, first)→ Supabase Signal Insert (service key, idempotent)
           │                       └─ DB TRIGGER paper_on_signal_insert → paper_positions + OPENED event
           └─(output 2)→ Loop Over Items → Send to Telegram (unchanged)

PAPER MONITOR WORKFLOW (new, hourly at HH:05, Europe/Sofia)
 Schedule → RPC paper_get_monitor_targets → [no targets → end]
          → Binance klines 1h (per symbol, from startTime)
          → Code: PAPER CANDLE NORMALIZER (closed candles only)
          → RPC paper_ingest_candles → RPC paper_evaluate_positions
          → (optional) Telegram notification for exits

SUPABASE
 paper_config · paper_positions · paper_position_events · paper_candles
 · paper_symbol_categories · paper_monitor_runs · statistics views and RPCs · RLS

DASHBOARD (dashboard/, static SPA, Vercel/Netlify)
 Supabase Auth (single user) → SELECT and read-only RPCs
```

**New files:**
- `supabase/paper_trading/001_schema.sql` … `005_security.sql` and `README.md` with the execution order
- `supabase/paper_trading/tests/*.sql`
- `monitor/PAPER CANDLE NORMALIZER` (Code node) and `monitor/PAPER MONITOR — N8N CONFIG` (node descriptions)
- `dashboard/`

**Modified files:**
- `row4/SIGNAL LOGGER`
- `row4/SUPABASE SIGNAL INSERT — N8N CONFIG`
- `row1/Sort & Select Top 20` (`LIMIT` only)

---

## 4. Roadmap

| Part | Content | Depends on |
|---|---|---|
| 1 | Preparation: prerequisites, schema, configuration | — |
| 2 | Signal integration | 1 |
| 3 | Position engine (opening, sizing, statuses) | 1, 2 |
| 4 | Monitoring and exit simulation | 3 |
| 5 | History and analytics | 4 |
| 6 | Dashboard and calendar | 5 |
| 7 | Tests, validation, reliability (written in parallel with 3–6, finalized here) | 3–6 |
| 8 | Deployment and 30-day test | 7 |

---

## PART 1 — Preparation and Schema

### P-01 Pipeline prerequisites
- **Objective:** the test must measure the real production configuration.
- **Changes:**
  1. `row1/Sort & Select Top 20`: `LIMIT = 20`, remove the TODO comment.
  2. Document in `supabase/paper_trading/README.md` a check **(U)**: which trigger is active (expected: Schedule every 2h, 08:00–22:00) and whether `Supabase Signal Insert` is connected on the canvas.
- **Acceptance:** `LIMIT = 20` in the repo. The user has confirmed the trigger and the insert node **(U)**.

### P-02 Database schema (`001_schema.sql`)
- **Objective:** persistent structures for positions, events, candles, and configuration.

**`paper_config`** — a single row, `id = 1`, CHECK `id = 1`:

| Field | Type | Default | Meaning |
|---|---|---|---|
| enabled | bool | true | global switch |
| initial_capital_usd | numeric | 1000 | starting virtual capital |
| sizing_mode | text | 'FIXED_MARGIN' | `FIXED_MARGIN` \| `PERCENT_EQUITY` |
| fixed_margin_usd | numeric | 50 | margin per position in FIXED mode |
| equity_pct | numeric | 5 | % of equity in PERCENT mode |
| leverage_override | int | NULL | if set, replaces the signal's leverage |
| max_leverage | int | 10 | upper bound |
| fee_rate | numeric | 0.00055 | per side (taker), as in TP-SL CALCULATOR |
| entry_slippage_pct | jsonb | {"1":0.05,"2":0.10,"3":0.20} | per tier, in % |
| stop_slippage_pct | jsonb | {"1":0.05,"2":0.10,"3":0.20} | for SL, TIMEOUT, and DATA_UNAVAILABLE |
| tp_slippage_pct | numeric | 0 | TPs are limit orders |
| maintenance_margin_rate | numeric | 0.005 | for the liquidation price |
| max_holding_hours | int | 72 | time-based exit |
| max_open_positions | int | 10 | cap on concurrent positions |
| max_signal_age_minutes | int | 45 | staleness threshold |
| move_sl_to_breakeven_after_tp1 | bool | false | break-even rule |
| notify_telegram_on_exit | bool | false | monitor notifications |
| timezone | text | 'Europe/Sofia' | for daily aggregation |
| config_version | int | 1 | incremented on every change |
| updated_at | timestamptz | now() | |

**`paper_positions`** — one row for **every** signal (1:1):
- **Identity:** `id` bigserial, `signal_id` int UNIQUE with FK to `telegram_signals.id`, `scan_cycle_id`, `symbol`, `tier`, `category` (snapshot from categories), `direction` ('LONG'|'SHORT').
- **Status:** `status` ('OPEN'|'CLOSED'|'SKIPPED'|'REJECTED'), `status_reason` text, `related_position_id` (on duplicate).
- **Input levels (snapshot of the signal):** `signal_entry_price`, `entry_min`, `entry_max`, `stop_loss`, `tp1`, `tp2`, `tp3`, `alloc1`, `alloc2`, `alloc3` (in %), `signal_leverage`, `total_score`, `market_condition`, `tp_strategy`, `fee_adjusted_rr`.
- **Simulation:** `entry_fill_price`, `leverage`, `margin_usd`, `notional_usd`, `quantity`, `liquidation_price`, `effective_stop` (SL after the liquidation check), `stop_capped_by_liquidation` bool, `be_active` bool, `config_snapshot` jsonb (the whole `paper_config` at open time).
- **Time:** `opened_at` (= `telegram_signals.sent_at`), `eval_start_open_time` (= start of the next full hour), `last_evaluated_open_time` (cursor, NULL initially), `closed_at`.
- **Result (maintained by the evaluator):** `remaining_pct` (100 → 0), `tp_hits` (0–3), `realized_gross_usd`, `fees_usd`, `funding_usd` (default 0, reserved), `realized_net_usd`, `return_on_margin_pct`, `exit_reason`, `exit_summary` (e.g. `TP1+SL`), `duration_hours`, `has_data_gap` bool.
- **Indexes:** a unique partial index on `symbol` WHERE `status = 'OPEN'` (at most one open position per symbol); indexes on `closed_at`, `status`, `(symbol, closed_at)`.

**`paper_position_events`** — one event per fill or state change:
- Fields: `id`, `position_id` FK, `event_type` ('OPENED'|'TP1'|'TP2'|'TP3'|'SL'|'BREAKEVEN_SL'|'TIMEOUT'|'LIQUIDATION'|'DATA_UNAVAILABLE'|'BE_ACTIVATED'|'DATA_GAP'|'ERROR'), `tranche` (1–3 or NULL), `candle_open_time`, `level_price`, `fill_price`, `qty`, `pct_of_position`, `gross_usd`, `fees_usd`, `net_usd`, `details` jsonb, `created_at`.
- **UNIQUE(position_id, event_type, tranche):** guarantees nothing is executed twice.

**`paper_candles`:** `symbol`, `open_time` timestamptz, `close_time`, `open`, `high`, `low`, `close`, `volume`, `ingested_at`, PK(symbol, open_time). 1h only.

**`paper_symbol_categories`:** `symbol` PK, `category` text. Seed: BTCUSDT → BTC, ETHUSDT → ETH, SOLUSDT → SOL. A symbol with no entry gets `OTHER`.

**`paper_monitor_runs`:** `id`, `started_at`, `finished_at`, `status` ('OK'|'PARTIAL'|'ERROR'|'SKIPPED_LOCKED'), `positions_evaluated`, `candles_used`, `events_created`, `positions_closed`, `error` text.

- **Edge cases:**
  - The `telegram_signals` table may not exist in the live database. The migration checks this and stops with a clear error.
  - Prices are stored as `numeric` with no precision loss. Rounding happens only for display.
- **Acceptance:** the migration runs twice in a row without errors; all tables, indexes, and seeds exist; `paper_config` has exactly one row.
- **Test:** a script that checks the structure (column count, unique indexes, the single config row).

### P-03 Leverage decision (a blocker, not code)
- **Objective:** the test must not start with always-1x unless that is a conscious choice.
- **Changes:** the agent does **not** change `RISK-REWARD FILTER`. The README describes two options for the user:
  - **(a)** deploy a new leverage model before the test (a separate task outside this spec);
  - **(b)** set `paper_config.leverage_override` (e.g. 3) for the whole test.
- **Acceptance:** **(U)** the user has chosen an option and the value is stored in `paper_config`.

---

## PART 2 — Signal Integration

### P-04 Extending `telegram_signals` (`002_signal_ingest.sql`)
- **New columns (nullable):** `entry_min`, `entry_max`, `tp1_allocation`, `tp2_allocation`, `tp3_allocation`, `sl_distance_pct`, `total_score`, `cycle_timestamp` timestamptz.
- **Unique index `(scan_cycle_id, symbol)`:** re-running a cycle does not create a duplicate. If the live data already contains duplicates, the migration does **not** delete them: it stops and lists them (rule 7).
- **Acceptance:** the migration is idempotent; existing rows remain untouched.

### P-05 Changes to `row4/SIGNAL LOGGER`
- **Added to the payload:** `entry_min`, `entry_max`, `tp1_allocation` to `tp3_allocation`, `sl_distance_pct`, `total_score`, `cycle_timestamp` (`null` if missing).
- **Weights fix:** the source is `data.applied_weights.<key>`, falling back to `data.weight_<key>`. First verify in the Row 4 code that `applied_weights` reaches the logger unchanged (SCORE AGGREGATOR:322 → VOLUME PENALTY APPLICATOR → Row 4 pass-through).
- **Do not change:** the guards, the `selected_for_telegram` filter, and the ordering of output items.
- **Acceptance:** when run **(U)**, the payload contains the new fields and `score_snapshot.weights` has numeric values. Telegram messages are unchanged.

### P-06 Insert node (`SUPABASE SIGNAL INSERT — N8N CONFIG`)
- **Documentation changes:**
  1. The key becomes **service_role**, stored as an N8N Credential (Header Auth), not as plain text in the node.
  2. URL: `…/rest/v1/telegram_signals?on_conflict=scan_cycle_id,symbol`, header `Prefer: resolution=ignore-duplicates,return=minimal`.
  3. The insert is the **first** output of SIGNAL LOGGER. Telegram is the second (N8N runs outputs in order).
  4. `Continue on Fail: ON` for the insert, so a Supabase failure does not stop Telegram. The error is visible in the execution log.
- **Edge cases:**
  - A cycle with no signals: the logger attaches no payload, so the insert node needs the condition `_signal_logger_count > 0`. An IF node is added and documented.
- **Acceptance (U):**
  - A new cycle creates N rows, and re-running it adds nothing.
  - Telegram works.
  - The anon key can no longer write to the table (see P-23).

### P-07 Telegram as an optional channel
- **Decision:** no new nodes in the main workflow. Telegram is turned off by deactivating the `Send to Telegram` node in the N8N UI. The README describes this.
- **Monitor notifications:** controlled by `notify_telegram_on_exit` (P-15).
- **Acceptance:** documented; positions are created even when Telegram is deactivated.

---

## PART 3 — Position Engine

### P-08 Trigger `paper_on_signal_insert` (AFTER INSERT ON `telegram_signals`, per row)
Sequence (fixed):

1. Read `paper_config`. If `enabled = false`, record a SKIPPED position with reason `PAPER_DISABLED`.
2. **Validation** (failure → REJECTED with a reason):
   - `signal_direction` is LONG or SHORT;
   - `entry_price`, `stop_loss`, and `tp1` are > 0;
   - for LONG: SL < entry < TP1 ≤ TP2 ≤ TP3;
   - for SHORT: SL > entry > TP1 ≥ TP2 ≥ TP3;
   - a missing TP2 or TP3 is replaced by the previous level;
   - allocations sum to 100 ± 0.5. If allocations are missing, use 40/40/20 and set `status_reason` to `DEFAULT_ALLOCATION`. If they are present but do not sum to 100, the signal is REJECTED.
3. **Stale:** if `cycle_timestamp` is not NULL and `sent_at − cycle_timestamp > max_signal_age_minutes`, the signal is REJECTED with reason `STALE_SIGNAL`.
4. **Duplicate:** if an OPEN position exists for the same symbol, regardless of direction, record SKIPPED with reason `DUPLICATE_OPEN_POSITION` and `related_position_id`.
5. **Cap:** if the number of OPEN positions ≥ `max_open_positions`, record SKIPPED with reason `MAX_OPEN_POSITIONS`.
6. **Sizing** (P-09). If free capital is insufficient, record SKIPPED with reason `INSUFFICIENT_VIRTUAL_BALANCE`.
7. **Calculations** (P-10). Record an OPEN position and an `OPENED` event.
8. The whole body is wrapped in exception handling. On error, record a `paper_positions` row with status REJECTED, reason `INTERNAL_ERROR: <message>`, and an ERROR event. **The trigger must never fail the signal insert.**

- **Concurrency:** the unique partial index is the last line of defense. On a conflict, e.g. two signals for the same symbol in one insert, the second row becomes SKIPPED `DUPLICATE_OPEN_POSITION`.
- **Acceptance:** every row in `telegram_signals` has exactly one row in `paper_positions` (tests T09, T10, T16).

### P-09 Sizing
- `equity = initial_capital_usd + Σ realized_net_usd` (over CLOSED positions).
- `used_margin = Σ margin_usd` (over OPEN positions).
- `free = equity − used_margin`.
- **FIXED_MARGIN:** `margin = fixed_margin_usd`.
- **PERCENT_EQUITY:** `margin = equity × equity_pct / 100`.
- If `margin > free` or `margin ≤ 0`, the position is SKIPPED (see P-08, step 6).
- **Leverage** = `clamp(coalesce(leverage_override, signal.suggested_leverage, 1), 1, max_leverage)`.

### P-10 Formulas at open
Notation: `s_e = entry_slippage_pct[tier] / 100`, `L` = leverage, `mmr = maintenance_margin_rate`.

| Quantity | LONG | SHORT |
|---|---|---|
| entry_fill | entry × (1 + s_e) | entry × (1 − s_e) |
| notional | margin × L | same |
| quantity | notional / entry_fill | same |
| liquidation_price | entry_fill × (1 − 1/L + mmr) | entry_fill × (1 + 1/L − mmr) |
| effective_stop | max(stop_loss, liq) — the higher | min(stop_loss, liq) — the lower |

- `stop_capped_by_liquidation = true` if liquidation is closer to entry than the SL.
- `eval_start_open_time = date_trunc('hour', opened_at) + 1 hour`. The partial first hour is **not evaluated**: protection against look-ahead and a known, documented inaccuracy.
- `tranche_qty_k = quantity × alloc_k / 100`.

### P-11 Lifecycle
```
(signal) → REJECTED | SKIPPED          (terminal, no events except ERROR)
(signal) → OPEN [remaining 100%] → OPEN [remaining < 100%, tp_hits ≥ 1] → CLOSED
```
CLOSED is terminal. A position can never be reopened.

---

## PART 4 — Monitoring and Exit Simulation

### P-12 `paper_get_monitor_targets()` → list of `{symbol, start_time_ms}`
- Returns one row per symbol with an OPEN position.
- `start` is the earliest value among the symbol's positions of `greatest(eval_start_open_time, last_evaluated_open_time + 1 hour)`.
- **Acceptance:** with no OPEN positions it returns an empty array.

### P-13 N8N workflow `PAPER MONITOR` (`monitor/PAPER MONITOR — N8N CONFIG`)
1. **Schedule Trigger:** every hour at minute 5; the workflow timezone is Europe/Sofia.
2. **HTTP POST** `rpc/paper_get_monitor_targets` (service credential).
3. **IF:** on an empty result the execution ends.
4. **HTTP GET** `https://api.binance.com/api/v3/klines?symbol={symbol}&interval=1h&startTime={start_time_ms}&limit=1000`.
   - Batching: 5 requests per second.
   - Retry: 3 attempts, 2 seconds apart.
   - `Continue on Fail: ON`, so one symbol does not stop the whole run.
5. **Code `PAPER CANDLE NORMALIZER`** (new file in `monitor/`):
   - converts Binance arrays into objects `{symbol, open_time, close_time, open, high, low, close, volume}`;
   - **discards** candles with `close_time ≥ now` (not closed);
   - discards error responses, recording the symbol in `failed_symbols`;
   - the output is **one** item: `{candles: [...], failed_symbols: [...]}`.
6. **HTTP POST** `rpc/paper_ingest_candles` with `p_candles` → upsert by (symbol, open_time); returns the count.
7. **HTTP POST** `rpc/paper_evaluate_positions` → a summary plus the list of new exit events.
8. **Optional:** if `notify_telegram_on_exit` is true and there are events, send a short Telegram message for each (symbol, event, price, net $).

- **Acceptance (U):** a manual run with one test OPEN position stores candles and a row in `paper_monitor_runs`.

### P-14 `paper_evaluate_positions()` — algorithm (mandatory, no deviations)

**Locking:** the function takes `pg_try_advisory_xact_lock(<constant>)`. If the lock fails, it records a run with status `SKIPPED_LOCKED` and ends.

**For each OPEN position** (ordered by `opened_at`; the row is locked `FOR UPDATE`) take the candles from `paper_candles` for the symbol where:
- `open_time ≥ eval_start_open_time`;
- `open_time > coalesce(last_evaluated_open_time, −∞)`;
- `close_time < now()`.

Candles are processed **in `open_time` order**. For each candle `c`:

1. **Data gap:** if there is a previous candle and `c.open_time − prev.open_time > 1 hour`, record a DATA_GAP event (once per position) and set `has_data_gap = true`. Processing continues.
2. **Active stop:**
   - If `be_active = false`, the active stop is `effective_stop`.
   - If `be_active = true`: for LONG it is `max(effective_stop, entry_fill)`, for SHORT it is `min(effective_stop, entry_fill)`.
3. **Stop touched:** for LONG `c.low ≤ stop`, for SHORT `c.high ≥ stop`.
4. **If the stop is touched, it takes priority over any TP in the same candle** (conservative rule):
   - **Fill price:**
     - gap-through (LONG `c.open ≤ stop`, SHORT `c.open ≥ stop`): fill at `c.open`;
     - otherwise: fill at the stop.
     - Then apply adverse slippage `s_x = stop_slippage_pct[tier]`: LONG × (1 − s_x), SHORT × (1 + s_x).
   - **Reason:**
     - `LIQUIDATION` if `stop_capped_by_liquidation` and the stop is `liquidation_price`;
     - `BREAKEVEN_SL` if the break-even stop is active;
     - otherwise `SL`.
   - **All** remaining tranches are closed; the position becomes CLOSED; candle processing stops.
5. **Otherwise — TP levels in order** k = 1, 2, 3 (only unfilled ones):
   - LONG: `c.high ≥ tp_k`; SHORT: `c.low ≤ tp_k`.
   - On a fill, tranche k closes at `tp_k × (1 ∓ tp_slippage)`. Even on a gap beyond the level the price is `tp_k`, never better.
   - Several TPs in one candle are allowed.
   - Stop at the first unfilled level.
6. **Break-even:** if `move_sl_to_breakeven_after_tp1` is on and TP1 was filled in this candle, record `BE_ACTIVATED` and set `be_active = true`. **It takes effect from the next candle**, with no look-ahead.
7. **Full close:** if `remaining_pct = 0`, the position becomes CLOSED with `exit_reason = TP3`.
8. **Time exit:** if an open share remains and `c.close_time ≥ opened_at + max_holding_hours`:
   - the remainder closes at `c.close` with adverse stop slippage;
   - the reason is `TIMEOUT`; the position becomes CLOSED.
9. `last_evaluated_open_time = c.open_time`.

**After the candles:** if the position is OPEN, `now() − opened_at > max_holding_hours + 24 hours`, and there is no candle at all after `eval_start_open_time`:
- the position closes at the last known close in `paper_candles`, or at `entry_fill` if there is none;
- the reason is `DATA_UNAVAILABLE`.

**Updating the position aggregates** after every event: `remaining_pct`, `tp_hits`, `realized_gross_usd`, `fees_usd`, `realized_net_usd`, `return_on_margin_pct`, `exit_summary`, and on CLOSED also `closed_at = c.close_time` and `duration_hours`.

**Returns:** a jsonb with the fields `evaluated`, `candles_used`, `events` (an array of new exit events), `closed`, and `status`. It records a row in `paper_monitor_runs`.

### P-15 Exit formulas (per tranche or remainder)
Notation: `q` = quantity in the exit, `F` = `fee_rate`.

- **gross:** LONG `q × (exit_fill − entry_fill)`; SHORT `q × (entry_fill − exit_fill)`.
- **fees:** `q × entry_fill × F + q × exit_fill × F`. The entry fee is charged proportionally to each exit.
- **net:** `gross − fees`.
- **LIQUIDATION:** `net = −(margin_usd × pct_of_position / 100)`. The whole margin of that share is lost, and fees are already included in the loss.
- **At position level:**
  - `realized_net_usd = Σ net`;
  - `return_on_margin_pct = realized_net_usd / margin_usd × 100`;
  - unleveraged price move: `(weighted-average exit_fill / entry_fill − 1) × 100`, with sign −1 for SHORT.
- **Classification:**
  - winning if `realized_net_usd > 0.01`;
  - losing if `< −0.01`;
  - otherwise BREAKEVEN.

### P-16 Reference examples (become automated tests with tolerance ±0.01 $)

**Example 1 — LONG, Tier 1** (`s_e = s_x = 0.05%`, margin 50, L = 5, allocation 40/40/20):
- Entry 80,000 → entry_fill 80,040; notional 250.
- Levels: SL 78,800, TP1 81,200, TP2 81,600, TP3 82,000.
- **(1a) TP1 then SL:**
  - the TP1 tranche yields net +1.34;
  - the remaining 60% exits at SL at 78,760.6 with net −2.56;
  - **the position yields −1.22 $, −2.45%**; `exit_summary` = `TP1+SL`.
- **(1b) Ambiguous first candle** (Low 78,700, High 81,300):
  - SL applies to 100%;
  - **the result is −4.27 $**; TP1 is **not** counted.

**Example 2 — SHORT, Tier 3** (`s_e = 0.20%`, margin 50, L = 3, allocation 50/35/15):
- Entry 100 → entry_fill 99.8; notional 150.
- Levels: SL 104, TP1 97, TP2 95, TP3 92. All three TPs are hit in separate candles.
- Net per tranche: +2.02, +2.47, and +1.73.
- **The position yields +6.23 $, +12.45%**, reason `TP3`.
- The liquidation price is 132.57, so the SL is not capped by liquidation.

---

## PART 5 — History and Analytics (`004_analytics.sql`)

### P-17 View `paper_positions_v`
- Positions plus category, `closed_date_local = (closed_at AT TIME ZONE config.timezone)::date`, and `outcome` (WIN, LOSS, or BREAKEVEN).
- The **single** source for lists and details in the frontend.

### P-18 RPC `paper_stats(p_from date, p_to date, p_symbols text[], p_categories text[], p_direction text, p_tiers int[])`

Only CLOSED positions whose `closed_date_local` falls in the range are counted. Filters are NULL = all.

| Metric | Formula |
|---|---|
| trades | count of CLOSED positions |
| wins / losses / breakeven | per the classification in P-15 |
| win_rate_pct | wins / trades × 100 (0 when trades = 0) |
| total_net_usd | Σ realized_net_usd |
| total_return_pct | total_net_usd / initial_capital_usd × 100 |
| avg_win_usd / avg_loss_usd | average of winners / of losers (NULL if none) |
| profit_factor | Σ gains / \|Σ losses\| (NULL if there are no losses) |
| expectancy_usd | total_net_usd / trades |
| avg_duration_hours | average |
| open_positions | count of OPEN positions under the same filters, ignoring the date filter |
| skipped / rejected | counts in the range by `opened_at` |

### P-19 RPC `paper_daily_pnl(p_month date, filters)`
- Returns a row for **every** day of the month, including days with no trades: `day`, `trades`, `wins`, `losses`, `net_usd`, `cumulative_net_usd`.
- The cumulative starts from 0 at the beginning of the month.
- The monthly summary is taken with `paper_stats` for the whole month.

### P-20 Aggregation rules
- **A trade's day is the day it was fully closed** in Europe/Sofia. Partially realized profit on an OPEN position does not enter the daily P&L. It is shown separately as "partially realized".
- **Indicative unrealized P&L** for OPEN positions: based on the latest close in `paper_candles`, clearly labeled as indicative. It does not enter any metric.
- All calculations are in SQL. Calling again with the same data gives the same result.

### P-21 Recompute `paper_recompute_position(p_id)` (service role only)
- Deletes the position's events except `OPENED`, resets the aggregates and the cursor, and returns the status to OPEN.
- The position is then re-evaluated on the next `paper_evaluate_positions`.
- Used during validation and when a rule error is proven. Every use is recorded in the `details` of a new event.

---

## PART 6 — Dashboard and Monthly Calendar (`dashboard/`)

### P-22 Foundation
- **Stack:** Vite, React, TypeScript, `@supabase/supabase-js`, `react-router-dom`.
- No UI framework, chart libraries, or state-management libraries.
- The calendar is a custom CSS grid.
- **Design:** the user has a ready design. **Before UI work the agent stops and asks for the design files.** If they are not provided, use a neutral minimal layout with CSS variables so the design can be applied later without a rewrite.
- **Configuration:** `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` (the anon key is public by design; protection is in RLS). A `.env.example` file, with no real values in the repo.
- **Access:** Supabase Auth with email magic link. Without login, only the login screen is shown.
- **Rule:** the frontend does **no financial calculations**. It only formats values: USD with 2 decimals, percentages with 2 decimals, dates in Europe/Sofia.

### P-23 Security (`005_security.sql`)
- RLS is enabled on all `paper_*` tables and on `telegram_signals`.
- Policies are **SELECT** only, for `authenticated`.
- There are no INSERT, UPDATE, or DELETE policies: only the service role (N8N) writes.
- The old anon insert policy on `telegram_signals` is dropped if it exists.
- The statistics RPC functions are `SECURITY INVOKER`, with EXECUTE for `authenticated`.
- `paper_evaluate_positions`, `paper_ingest_candles`, and `paper_recompute_position` have EXECUTE for `service_role` only.
- **(U)** In Supabase Auth, signups are disabled and exactly one user exists.

### P-24 Screens
A global filter bar: symbols (multi-select), category, direction, tier. Filters are kept in URL query parameters and apply to all screens.

1. **"Day" (`/`, default today):**
   - Date picker.
   - KPI tiles from `paper_stats` for the day: trades, wins, losses, win rate, net $, return %, average win, average loss.
   - A table of closed trades with columns: symbol, direction, entry, exit, result %, net $, duration, reason.
   - Clicking a row opens a modal with all position fields and a timeline of events (time, type, price, net).
2. **"Calendar" (`/calendar`):**
   - A monthly grid. Each day shows net $ and trade count.
   - Green background when net > 0, red when < 0, neutral when 0 or no trades.
   - Intensity is proportional to |net| relative to the month's maximum.
   - Above the grid: monthly net, return %, trade count, win rate. In each cell in a small font: cumulative net.
   - Clicking a day opens "Day" for that date. Month navigation back and forward.
3. **"Positions" (`/positions`):**
   - "Open" tab: symbol, direction, entry, SL and TPs with ticks for filled ones, remaining %, hours, indicative P&L.
   - "History" tab: all CLOSED, SKIPPED, and REJECTED positions with a status filter and sorting.
   - Pagination of 50.
4. **"Comparison"** (a panel above the Positions table):
   - `paper_stats` broken down by symbol, category, direction, and tier for a chosen period.
   - A table with trades, win rate, net, and profit factor.
   - A segment with fewer than 20 trades is marked "small sample".

- **States:** loading, empty data ("No trades for this period"), query error (message and a "Try again" button), expired session (redirect to login).
- **Responsive:** works from 360 px width up. On mobile the calendar becomes a list by day.
- **Acceptance:**
  - values on screen match a direct SQL query for 3 arbitrary days **(U)**;
  - filters change KPIs, the calendar, and tables consistently;
  - without login the data is inaccessible (verified with an anon request with no session).

---

## PART 7 — Tests, Validation, and Reliability

### P-25 SQL scenarios (`supabase/paper_trading/tests/`)
- Each file is self-contained and runs in a transaction with ROLLBACK.
- Each one sets up its own config, signal, and candles, calls the functions, and on any mismatch aborts with `RAISE EXCEPTION` with a description.
- `tests/README.md` describes how to run them in the SQL Editor of a test project or branch, **not** in production.

| ID | Scenario | Expected |
|---|---|---|
| T01 | Example 1a | −1.22 $, `TP1+SL`, 2 exit events |
| T02 | Example 1b, ambiguous candle | −4.27 $, only the SL event |
| T03 | Example 2, SHORT with all TPs | +6.23 $, TP3 |
| T04 | TP1 and TP2 in one candle | two events, remaining 20% |
| T05 | Gap below SL (open < SL) | fill at open with slippage |
| T06 | Nothing hit for 72 hours | TIMEOUT at the close of the candle in which 72 hours elapse |
| T07 | BE on: TP1, then a return to entry | BE does not apply in the TP1 candle; in the next one it is BREAKEVEN_SL |
| T08 | L = 20, SL beyond liquidation | `stop_capped_by_liquidation`, LIQUIDATION, net = −margin of that share |
| T09 | A second signal for a symbol with an OPEN position; a new signal after it closes | SKIPPED `DUPLICATE_OPEN_POSITION`; the new one opens |
| T10 | Invalid levels, bad allocation, stale | REJECTED with the correct reason |
| T11 | `evaluate` twice; `ingest` of the same candles twice | unchanged events, P&L, and candle count |
| T12 | A candle with close_time in the future | ignored |
| T13 | Position at 10:14; TP hit in the 10:00 candle | not counted; evaluation starts from 11:00 |
| T14 | Cursor 10 hours old | one run catches up 10 candles correctly |
| T15 | Advisory lock is held | `SKIPPED_LOCKED`, no changes |
| T16 | Forced error in the trigger | the signal is saved; the position is REJECTED `INTERNAL_ERROR` |
| T17 | Statistics over a defined set; a trade closed at 23:30 UTC | exact expected values; the trade falls on the **next** day in Sofia |
| T18 | PERCENT_EQUITY; insufficient balance | correct margin; SKIPPED `INSUFFICIENT_VIRTUAL_BALANCE` |
| T19 | Max open positions | SKIPPED `MAX_OPEN_POSITIONS` |
| T20 | `paper_recompute_position` | result identical to the original |

### P-26 Frontend tests
- **Unit (vitest):** currency, percent, and date formatting in Europe/Sofia; mapping of URL filters to RPC parameters; calendar coloring.
- **E2E (manual checklist in `dashboard/README.md`):** login, navigation across the three screens, filters, modal, empty month, mobile width.

### P-27 Main pipeline regression
- `git diff` against the starting commit touches in `row*/` **only** `row4/SIGNAL LOGGER` and `row1/Sort & Select Top 20`.
- **(U)** One run of the main workflow after deployment: Telegram messages have an identical format; the number of signals in `telegram_signals` equals the number sent; each has a position.

### P-28 Reliability and observability
- **Restart:** all state is in Supabase. The cursor and unique keys make every re-run safe (T11, T14).
- **View `paper_health_v`:**
  - the last successful monitor run and its age in hours;
  - OPEN positions not evaluated for more than 3 hours;
  - positions with DATA_GAP;
  - REJECTED with `INTERNAL_ERROR` in the last 24 hours.
- The dashboard shows a warning bar if the last successful run is older than 3 hours.

---

## PART 8 — Deployment and 30-Day Test

### P-29 Deployment order (U, per `supabase/paper_trading/README.md`)
1. Back up or export `telegram_signals`.
2. SQL files 001 → 005 in the SQL Editor; after each, the check from the README.
3. The P-25 scenarios in a Supabase **branch** or test project, if available; otherwise skip this step and note the risk.
4. N8N: service credential, changes to `SIGNAL LOGGER` and the insert node (P-05, P-06), `LIMIT = 20`.
5. N8N: import and activate `PAPER MONITOR`.
6. Deploy the dashboard (Vercel or Netlify, env variables), create the user.
7. Set `paper_config` per P-30.

### P-30 Initial test configuration
- **Capital and size:** initial 1000 $, FIXED_MARGIN 50 $.
- **Leverage:** per the decision in P-03.
- **Costs:**
  - fee 0.055% per side;
  - slippage 0.05%, 0.10%, and 0.20% by tier, for entry and for stops;
  - TP slippage 0.
- **Limits:** max holding 72 hours; max open 10; BE off; stale threshold 45 minutes. If the measured cycle duration in N8N is longer, adjust the threshold **before** the start.
- **Freezing:** the configuration and strategy are **frozen** for the 30 days. Any forced change increments `config_version` and is described in the `CHANGELOG`.

### P-31 Test procedure
- **Day −2 to 0 (shadow run):** the system runs but results are not counted. Manually check 10–15 trades against the chart (TradingView, 1h): entry, every level touch, exit reason. The requirement is **100% agreement** with the P-14 rules. On any mismatch, stop, fix, run `paper_recompute_position`, and repeat the check.
- **Day 1:** the user deletes or archives the shadow positions and the official test begins.
- **Every day (5 minutes):** `paper_health_v` shows no warnings; the number of signals equals the number of positions; there is no `INTERNAL_ERROR`.
- **Every week:** review `paper_stats` by segment, with no strategy changes.

### P-32 Success criteria

**Technical (the system is reliable):**
- 100% of signals have a position;
- 0 missed exits in the weekly random check of 5 trades;
- no monitoring gap over 3 hours that was not automatically caught up;
- all tests T01–T20 pass.

**Trading (the strategy deserves real capital)** — thresholds to be confirmed by the user before the start:
- at least 100 closed trades;
- positive expectancy after fees and slippage;
- profit factor ≥ 1.3;
- maximum virtual-capital drawdown ≤ 20%;
- positive result in at least 3 of 4 weeks.

**Post-test optimization:**
- Conclusions are drawn only for segments with at least 20 trades.
- The last 10 days are treated as a holdout period: rules "tuned" on the first 20 days must be confirmed there.
- One change is made per new test period, so it is clear what caused any difference.

---

## 9. Dependencies and Sequence

```
P-01 → P-02 → P-03(decision)
          └→ P-04 → P-05 → P-06 → P-07
                    └→ P-08 → P-09 → P-10 → P-11
                                         └→ P-12 → P-13 → P-14 → P-15 → P-16
                                                                     └→ P-17 → P-18 → P-19 → P-20 → P-21
                                                                                                  └→ P-22 → P-23 → P-24
P-25 is written alongside P-08…P-21 (test before the next task); P-26 with P-24; P-27…P-28 → P-29 → P-30 → P-31 → P-32
```

Tasks P-05 and P-06 can be deployed in N8N after P-04. Positions open only once P-08 is in the database.

---

## 10. Definition of Done

The system is ready for the 30-day test when:

1. All SQL files are idempotent and in the repo, with a README for the execution order.
2. Tests T01–T20 pass. The reference examples match to ±0.01 $.
3. Every signal in `telegram_signals` has exactly one row in `paper_positions` with a status and reason.
4. Monitoring catches up on missed hours. Re-running changes nothing. Concurrent execution backs off safely.
5. TP, SL, BE, TIMEOUT, LIQUIDATION, and ambiguous candles are handled exactly per P-14. There is no look-ahead.
6. Daily and monthly values in the dashboard match direct SQL queries. Filters work consistently.
7. Data is accessible only after login. Only the service role writes.
8. The main pipeline and Telegram work without regression. Changes in `row*/` are only the ones listed.
9. The shadow run passed with 100% agreement in the manual check.
10. The leverage decision and the initial configuration are recorded, and the configuration is frozen.
