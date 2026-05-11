# CRYPTO_SIGNAL_SYSTEM — CHANGELOG

## Release: Data Integrity Patch v1.0
**Date:** 2026-05-11
**Scope:** Execution Plan v2 — Issues A-02 through A-06
**Status:** All items resolved and verified in production test run

---

## Overview

This release addresses five critical data integrity issues identified during audit of the
multi-stage candle processing pipeline. Issues ranged from silent scan cycle ID drift at
minute boundaries, to incorrect candle interval mixing that produced mathematically
invalid SMA calculations. All fixes are production-grade with explicit error propagation
replacing silent fallbacks.

---

## A-02 — scan_cycle_id: Single Source of Truth

**Severity:** Critical
**Root Cause:** Race condition at minute boundaries — three independent nodes were calling
`new Date()` at different moments, generating mismatched scan_cycle_id values within the
same pipeline execution. Any run that crossed a minute boundary would produce records
tagged with two different cycle IDs, corrupting scan result attribution and making
cross-interval joins unreliable.

**Files Changed:**
- `row1/Bulk Requests Generator Binance Candles`
- `row2/Separation of Requests`
- `row2/SMA 20 Calculation`

**Changes Applied:**

`row1/Bulk Requests Generator Binance Candles`
- Removed 8-line `new Date()` block that was independently generating scan_cycle_id.
- Node now reads scan_cycle_id and cycle_timestamp from the incoming item chain first.
- Falls back to cross-node reference `$('Crypto Symbols Metadata').all()` if fields are
  absent (e.g. stripped by an intermediate PATCH HTTP node).
- Throws a hard `CRITICAL [A-02]` error if scan_cycle_id cannot be resolved from either
  source — no silent fallback.

`row2/Separation of Requests`
- Removed second independent `new Date()` regeneration block.
- Now reads `scan_cycle_id` directly from `inputItems[0].json.scan_cycle_id`.
- Throws hard error if the field is missing, preventing downstream records from being
  written with a null or stale cycle ID.

`row2/SMA 20 Calculation`
- Replaced `scan_cycle_id || 1` fallback — the numeric `1` was being silently stored in
  the database as a valid-looking cycle ID.
- Changed to `|| null` combined with an explicit throw:
  `throw new Error('CRITICAL [A-02]: scan_cycle_id missing from candle items reaching SMA 20 Calculation.')`
- Replaced `cycle_timestamp: new Date().toISOString()` with `cycle_timestamp: currentCycleTimestamp`,
  sourced from the same upstream item that provides scan_cycle_id.

**Single Source of Truth:** scan_cycle_id and cycle_timestamp now originate exclusively
from `row1/Crypto Symbols Metadata` and propagate unchanged through the entire item chain.
No node downstream of that point is permitted to regenerate these values.

---

## A-03 — GROUP CANDLE RESPONSES: Option A Architecture (v4.1)

**Severity:** Critical
**Root Cause:** The previous grouping node attempted to disambiguate candle intervals from
a single merged HTTP response stream using timestamp-gap heuristics. Under HTTP retry or
reorder conditions, this approach produced silent symbol-to-interval mismatches: candles
for symbol X could be attributed to symbol Y without any error being raised.

**File Changed:** `row1/GROUP CANDLE RESPONSES`

**Architectural Decision — Option A:**
Instead of disambiguating a single mixed stream, the pipeline was restructured around four
dedicated HTTP nodes — one per interval: `Binance 2h`, `Binance 1h`, `Binance 15m`,
`Binance 1m`. Interval identity is now guaranteed structurally (which node produced the
response), not inferred from data content. Symbol ordering within each interval batch is
guaranteed by N8N's sequential item processing, which preserves the order of the upstream
Filter nodes.

**v4.1 Changes:**

- Node reads from four cross-node references simultaneously:
  `$('Filter 2h Requests').all()`, `$('Binance 2h').all()`, and equivalents for
  1h, 15m, 1m.
- Auto-detects N8N HTTP output mode per interval:
  - **Split ON**: `resp.length === meta.length × limit` — each item is one candle;
    symbol i's candles are collected by `resp.slice(i * limit, (i+1) * limit)`.
  - **Split OFF**: `resp.length === meta.length` — each item is a full candles array;
    symbol i's candles are `resp[i].json`.
  - Logs detected mode: `Split=ON` or `Split=OFF` per interval for operator visibility.
- Candle count validation: hard error if `candles.length !== limit`.
- Interval timestamp-gap validation (15% tolerance): secondary safety check confirming
  candle timestamps match the expected interval cadence.
- Completeness check: every symbol must have all four intervals present; symbols missing
  any interval are flagged `data_status: INCOMPLETE` and `exclude_from_taapi: true`.
- Summary log: total grouped pairs, incomplete symbol count, error count, per-interval
  breakdown.

**Verified Output (2-symbol test run):**
```
📊 2h:  2 symbols, 40 resp items,  Split=ON
📊 1h:  2 symbols, 24 resp items,  Split=ON
📊 15m: 2 symbols,  2 resp items,  Split=ON
📊 1m:  2 symbols,  2 resp items,  Split=ON
✅ Grouped 8 symbol|interval pairs
⚠️  Incomplete : 0 symbols
❌  Errors     : 0
```
Item counts match expected: 2×20=40 (2h), 2×12=24 (1h), 2×1=2 (15m), 2×1=2 (1m).

---

## A-04 — DEBUG + DE-DUPLICATION: Median Volume Field Pass-Through

**Severity:** High
**Root Cause:** The de-duplication node's `validCandles.push()` block omitted the three
extended volume fields — `median_volume_1h`, `median_volume_2h`, and `latest_1m_price`.
All three were silently dropped. The VOLUME SCORE CALCULATOR node downstream had no
median volume data available and was falling back to a `cs_volume / 24` estimation,
producing lower-accuracy volume scores on every cycle.

**File Changed:** `row2/DEBUG + DE-DUPLICATION`

**Changes Applied:**
- Added three fields to the `validCandles.push()` block:
  ```
  median_volume_1h:  candle.median_volume_1h  || 0
  median_volume_2h:  candle.median_volume_2h  || 0
  latest_1m_price:   candle.latest_1m_price   || null
  ```
- Zero fallback (not null) for median fields — VOLUME SCORE CALCULATOR receives a
  numeric zero for absent values rather than undefined, preventing NaN propagation.
- `latest_1m_price` retains null fallback: a null price is semantically distinct from a
  zero price and must remain distinguishable.
- Added diagnostic log line: `Records with median_volume_2h: [N]` to surface any upstream
  gaps in median calculation at runtime.

---

## A-05 — Candles Grouping & Latest 20 per Symbol: 2h Interval Filter

**Severity:** High
**Root Cause:** The grouping node received the full multi-interval candle stream (2h, 1h,
15m, 1m) and sorted all candles together by `open_time DESC`. Because 15m and 1m candles
have more recent open_time values than 2h candles covering the same period, the top-20
slice was dominated by short-interval candles. The node was passing mixed-interval data
to SMA 20 Calculation, making the SMA calculation mathematically meaningless.

**File Changed:** `row2/Candles Grouping & Latest 20 per Symbol`

**Changes Applied:**
- Added explicit interval filter at the top of the node, before any grouping logic:
  ```js
  const only2h = allCandles.filter(item => item.json.interval === '2h');
  ```
- Hard guard: if `only2h.length === 0`, logs `CRITICAL [A-05]` and returns empty array
  to prevent SMA from silently running on zero candles.
- All grouping, sorting, and slicing now operates exclusively on 2h candles.
- Diagnostic log: `Input candles: [total] total, [N] after 2h filter` confirms filter
  is active and effective on every run.

---

## A-06 — SMA 20: Guaranteed 20 × 2h Candles

**Severity:** High (dependent on A-05)
**Root Cause:** SMA 20 requires exactly 20 completed 2h candles per symbol. Due to the
A-05 interval mixing problem, the node was receiving fewer than 20 qualifying candles for
many symbols and silently skipping their SMA calculation (`SKIPPING SMA 20 calculation`
log line). The SMA skip meant those symbols had no SMA-based signal data for the cycle.

**File:** `row2/SMA 20 Calculation` (already reads only close_price and open_time — no
code changes required in this node once A-05 is resolved)

**Resolution:** With the A-05 2h filter in place, `Candles Grouping & Latest 20 per
Symbol` now delivers exactly 20 2h candles per symbol. SMA 20 Calculation receives the
correct input and completes for all symbols without skip conditions.

**Additional A-02 hardening applied in this node (same release):**
- `scan_cycle_id || 1` replaced with `|| null` + explicit throw.
- `cycle_timestamp: new Date().toISOString()` replaced with propagated upstream value.

---

## Dependency Chain

The five fixes are sequentially dependent in the following order:

```
A-02 → scan_cycle_id propagated correctly through all nodes
A-03 → candles grouped correctly by interval and symbol
A-04 → median volume fields survive de-duplication
A-05 → 2h filter ensures SMA receives correct interval
A-06 → resolved as consequence of A-05 (no independent code change)
```

Applying fixes out of order (e.g. A-05 without A-03) would produce incorrect grouping
upstream that masks the SMA fix. All five must be deployed together.

---

## Remaining Open Items

| ID   | Description                                        | Status     |
|------|----------------------------------------------------|------------|
| A-01 | TAAPI JWT secret hardcoded in Separation of Requests | ⏳ Pending |
| A-02p2 | Fetch Data AFTER TAAPI: WHERE clause uses fresh timestamp instead of incoming scan_cycle_id | ⏳ Pending (manual N8N edit) |

---

*CRYPTO_SIGNAL_SYSTEM — Data Integrity Patch v1.0 — 2026-05-11*
