# Paper Trading — Supabase

Implements `PAPER_TRADING_IMPLEMENTATION_SPEC.md`. All financial logic lives in
Supabase (PL/pgSQL); N8N only moves data and the dashboard only displays it.

## Execution order (Supabase → SQL Editor)

| Step | File | Part | Status |
|---|---|---|---|
| 0 | Back up / export `telegram_signals` | P-29 | user |
| 1 | `001_schema.sql` | P-02 | **ready** |
| 2 | `002_signal_ingest.sql` | P-04 | planned (Part 2) |
| 3 | `003_engine.sql` | P-08 … P-15, P-21 | planned (Parts 3–4) |
| 4 | `004_analytics.sql` | P-17 … P-20, P-28 | planned (Part 5) |
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

## Configuration

Single row `paper_config` (id = 1). Every real change increments `config_version`
automatically (no-op updates do not). Defaults follow the spec (1000 $ capital,
50 $ fixed margin, fee 0.055 %/side, slippage 0.05/0.10/0.20 % by tier, 72 h max hold,
10 max open, 45 min stale threshold, timezone Europe/Sofia).
