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
| `T01`–`T20` | P-08 … P-21 | added together with the functions they test (see spec P-25) |
