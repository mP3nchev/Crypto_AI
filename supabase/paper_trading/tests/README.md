# Paper trading — SQL tests

Each file is self-contained, runs inside `BEGIN … ROLLBACK`, and aborts with
`RAISE EXCEPTION '<description>'` on any mismatch. A passing test ends with a
`NOTICE: Txx PASSED`.

**Run them only in a Supabase branch or a separate test project — never in production.**
(They insert temporary rows; the final `ROLLBACK` removes them, but T00 also
touches `paper_config` inside the transaction.)

## How to run
1. Apply `../001_schema.sql` (and later `002…005` as they are added) to the test project.
2. Supabase → SQL Editor → paste one test file → Run.
3. Expect `NOTICE: Txx PASSED`. Any `ERROR: Txx: …` is a failure — do not skip it; report it.

## Index
| File | Part | Checks |
|---|---|---|
| `T00_schema_structure.sql` | P-02 | tables, column counts, single config row, indexes, seeds, config_version trigger, event/open-symbol uniqueness |
| `T00b_signal_ingest.sql` | P-04 | new columns, unique `(scan_cycle_id, symbol)`, idempotent re-insert, payload types |
| `T00c_open_formulas.sql` | P-09, P-10 | Examples 1–2 at open (fill, notional, qty, liquidation 132.57), L=20 capped stop (T08 open part), leverage clamp, category, next-full-hour eval start (T13 open part) |
| `T09_duplicate_open.sql` | P-08 | duplicate per symbol (any direction), duplicate inside one insert, reopen after close, 1:1 |
| `T10_validation.sql` | P-08 | direction, levels, order, allocations (default / tolerance / partial), missing TP2/TP3, stale 46 vs 44 min, unknown tier |
| `T16_trigger_error.sql` | P-08 | forced engine error: signal saved, REJECTED `INTERNAL_ERROR`, ERROR event |
| `T18_sizing.sql` | P-09 | PERCENT_EQUITY on 1000 and 1200 equity, INSUFFICIENT_VIRTUAL_BALANCE |
| `T19_max_open.sql` | P-08 | MAX_OPEN_POSITIONS, PAPER_DISABLED |
| `T01`–`T08`, `T11`–`T15`, `T17`, `T20` | P-12 … P-21 | added with Parts 4–5 |

Every `Txx` file starts with the same prelude: it empties the paper tables and
resets `paper_config` to defaults **inside the transaction**, so results do not
depend on existing data. The final `ROLLBACK` restores everything.
