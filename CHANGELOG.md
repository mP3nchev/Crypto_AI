# CRYPTO SIGNAL SYSTEM — CHANGELOG

Based on audit report at commit `2eb9fc9`.
All fixes reference issue IDs from `CRYPTO_SIGNAL_SYSTEM_Execution_Plan_v2.md`.

---

## [Phase 4] Risk & Trading Logic Fixes — commit `c58c85c`

### T-01 — Leverage Calculation Duplicated and Wrong
**Files:** `row4/TP-SL CALCULATOR`, `row4/RISK-REWARD FILTER`

TP-SL CALCULATOR was computing `suggestedLeverage = floor(10 / slDistancePct)` using a
hardcoded denominator `10` with undefined semantics, then outputting it as
`recommended_leverage`. RISK-REWARD FILTER recalculated and overwrote it — making the
first computation dead code. Additionally, `targetRiskPct` values in RISK-REWARD FILTER
were **inverted**: Tier 1 had 1.0% (lowest quality, tightest SL), Tier 3 had 2.0%
(highest risk). Correct values are the opposite: Tier 1 = 2.0%, Tier 2 = 1.5%, Tier 3
= 1.0%. Tier 2 max leverage was also wrong (7.5x vs spec 7x).

**Changes:**
- Removed the entire leverage calculation block from TP-SL CALCULATOR.
- Removed `recommended_leverage` from TP-SL CALCULATOR output.
- Renamed `max_leverage_tier` → `tier_max_leverage` (static tier cap, no calculation).
- Fixed `targetRiskPct`: Tier 1 `1.0 → 2.0`, Tier 3 `2.0 → 1.0`.
- Fixed `TIER_MAX_LEVERAGE[2]`: `7.5 → 7`.
- Surfaced `leverage_at_minimum` flag to top-level RISK-REWARD FILTER output
  (was buried inside nested `leverage_calculation` object, invisible to downstream nodes).

---

### T-05 — TP1 Ratio 1:1 Produces Negative Expected Value at Leverage
**File:** `row4/TP-SL CALCULATOR`

All three strategies used `tp_ratios[0] = 1.0` for TP1. After trading fees of 0.11%
total, fee-adjusted R/R at TP1 ≈ 0.89 — a net loss on every TP1 exit. At 5x leverage
with 40–60% position allocated to TP1 and 50% win rate, the system was systematically
losing on the most-hit take profit level on every trade.

**Changes:**
- `STRONG_TREND` TP1 ratio: `1.0 → 1.5`
- `MODERATE_TREND` TP1 ratio: `1.0 → 1.3`
- `WEAK_RANGING` TP1 ratio: `1.0 → 1.2`
- `WEAK_RANGING` TP1 allocation: `60% → 50%` (allows more position to run to TP2).
- `WEAK_RANGING` remaining allocation rebalanced: `30/10 → 35/15`.
- All strategies now produce fee-adjusted R/R > 1.0 at TP1.

---

### T-07 — HARD FILTERS ENFORCER R/R Check Fragile
**File:** `row4/HARD FILTERS ENFORCER`

The `risk_reward` filter check used `rrFilterPassed && feeAdjustedRR >= tierMin`.
The `rrFilterPassed` boolean is set by RISK-REWARD FILTER (node 5) and must survive
intact through the N8N Merge before reaching HARD FILTERS ENFORCER. In the event of
a merge glitch, `rrFilterPassed` could arrive as `false` even when `feeAdjustedRR`
is numerically valid (e.g., 3.0). This silently rejected correct signals. Additionally,
there was no NaN/null guard on `feeAdjustedRR` before the numeric comparison.

**Changes:**
- Replaced `rrFilterPassed && feeAdjustedRR >= tierMin` with
  `tpsl_calculated === true && safeRR >= tierMin`.
- Added NaN/null guard: `isNaN(feeAdjustedRR) ? 0 : (feeAdjustedRR ?? 0)`.
- Removed `upstream_flag_override` and `flag_value` diagnostic fields (now meaningless).
- Updated log line to display numeric R/R vs tier floor directly, with `tpsl_calculated`
  state, for cleaner debugging.

---

### T-09 — Signal Ranking Tier Diversification Score-Blind
**File:** `row4/SIGNAL RANKING & TOP 5 SELECTION`

The tier diversification loop forced up to 2 Tier 3 slots without any score quality
check. A Tier 3 signal at score 56 could displace a Tier 2 signal at score 72 purely
because the Tier 3 count was below 2. At 3x–5x leverage on small altcoins this
represents direct, unnecessary user risk.

**Changes:**
- Added pre-loop detection: `allAreTier3 = sortedSignals.every(tier === 3)`.
- Tier 3 candidates (only) are checked against a minimum score threshold before the
  tier count slot is consumed:
  - If no signals selected yet: threshold = **50** (Tier 3 absolute hard filter floor).
  - If signals already selected: threshold = **avg(selected scores) − 15**.
- Candidates failing the threshold are pushed to `skippedSignals` with reason
  `SCORE_BELOW_TIER3_THRESHOLD` — the tier slot is **not** incremented.
- Exception: when `allAreTier3 = true`, the relative threshold is bypassed entirely
  (all signals are altcoins — likely altseason or risk-off cycle, both valid scenarios).
- `portfolio_composition` object attached to every selected signal:
  ```
  { all_tier3_exception, tier_distribution: {tier1, tier2, tier3}, portfolio_risk_level }
  ```
- `portfolio_risk_warning: 'ALL_TIER3_ELEVATED_RISK'` flag set when exception triggers,
  for Telegram node to render a visible risk warning to subscribers.

---

### T-10 — BBW Thresholds Not Tier-Aware, Tier 1 Structurally Underscored
**File:** `row3/Volatility Score Calculator1`

Bollinger Bands Width scoring used fixed global thresholds (`≤0.02` = squeeze,
`≤0.05` = optimal) regardless of asset tier. BTC structurally operates at BBW
0.010–0.018 — under fixed thresholds, a healthy BTC squeeze at BBW = 0.012 scored
25 pts (LOW zone) instead of the correct 40 pts (OPTIMAL zone). Small altcoins
operating at BBW 0.05 were rewarded identically to BTC at BBW 0.05, which represents
a very different volatility profile.

**Changes:**
- Replaced fixed thresholds with tier-aware lookup:
  - **Tier 1**: squeeze ≤ 0.008, optimal ≤ 0.015, elevated ≤ 0.025
  - **Tier 2**: squeeze ≤ 0.015, optimal ≤ 0.040, elevated ≤ 0.070
  - **Tier 3**: squeeze ≤ 0.025, optimal ≤ 0.060, elevated ≤ 0.100
- Default to Tier 2 thresholds when `tier` is null or unknown (conservative).
- Points per zone unchanged: squeeze = 25, optimal = 40, elevated = 30, extreme = 15.
- `bbw_tier_thresholds` added to `components` output for audit traceability.
- Existing `bbw_1h > 0` guard retained (zero/NaN correctly skips the component).

---

## [Phase 2–3] Data Integrity + Pipeline Architecture — commits `3fd014f`, `220f802`, `1599fd1`

### A-02 — Dual scan_cycle_id Race Condition on Minute Boundary
**Files:** `row1/Bulk Requests Generator`, `row2/Separation of Requests`,
`row2/SMA 20 Calculation`

`scan_cycle_id` was generated independently in three nodes via `new Date()`. At a
minute boundary, slow execution could produce different IDs per node, causing
Row 3's Fetch Data AFTER TAAPI to query the wrong cycle and return 0 results.

- **Bulk Requests Generator**: removed `new Date()` regeneration; reads
  `scan_cycle_id` from input items (propagated from Crypto Symbols Metadata),
  with fallback to `$('Crypto Symbols Metadata')` cross-node reference; throws
  explicitly if ID is absent.
- **Separation of Requests**: same removal; reads from first input item; throws
  if absent rather than silently continuing.
- **SMA 20 Calculation**: replaced `|| 1` fallback (which produced numeric `1`
  as a cycle ID) with explicit throw on missing ID; uses upstream `cycle_timestamp`.
- **Note:** Fetch Data AFTER TAAPI (HTTP GET node, no code file) still requires a
  manual N8N workflow edit to pass the incoming `scan_cycle_id` into its WHERE clause.

---

### A-03 — GROUP CANDLE RESPONSES Positional Matching Unsafe on HTTP Retry
**Files:** `row1/GROUP CANDLE RESPONSES`, `row1/Bulk Requests Generator`

The original algorithm used `responsePointer` (positional index) to match HTTP
responses to symbols/intervals. HTTP retry or parallel connections could reorder
responses, silently swapping BTCUSDT indicators onto ETHUSDT candles.

- **Option A implemented** (4 separate interval HTTP nodes):
  GROUP CANDLE RESPONSES rewritten to pull from 4 cross-node references
  (`$('Filter 2h Requests')` / `$('Binance 2h')`, etc.) — interval identity is
  structurally guaranteed by which HTTP node produced the response.
- Symbol identity derived from Filter node output order (deterministic, matches
  Bulk Requests Generator sort).
- Timestamp-gap validation retained as secondary safety check.
- **v4.1 patch**: auto-detects N8N "Split Into Items" ON/OFF mode by comparing
  `resp.length` to `meta.length × limit`. Split ON slices by index; Split OFF reads
  array directly. Both paths produce identical downstream output.
- 15m limit reverted `2 → 1` (Option B disambiguation no longer needed).

---

### A-04 — DE-DUPLICATION Drops median_volume Fields
**File:** `row2/DEBUG + DE-DUPLICATION`

The `validCandles.push({json:{...}})` block used an explicit field list that omitted
`median_volume_1h` and `median_volume_2h`. VOLUME SCORE CALCULATOR always fell back
to `cs_volume / 24` estimation. The node's own log confirmed: `Records with
median_volume_2h: 0`.

- Added `median_volume_1h` and `median_volume_2h` to the reconstruction block.
- Added `latest_1m_price` propagation for downstream Price Action scoring (T-06 prep).
- Zero values pass through as zero — not defaulted to null or omitted.

---

### A-05 / A-06 — Candles Grouping Mixes Intervals, SMA 20 Always Null
**File:** `row2/Candles Grouping & Latest 20 per Symbol`

All intervals (2h + 1h + 15m + 1m) were grouped together by symbol only. The
`latest 20 by open_time` sort was dominated by 1m and 15m candles, leaving fewer
than 2 genuine 2h candles per symbol in the SMA input. SMA 20 Calculation requires
exactly 20 and skipped every symbol — `sma_20 = null` for all symbols every cycle.

- Added pre-grouping filter: `interval === '2h'` only.
- With 2h candles at limit 20, each symbol now provides exactly 20 candles.
- A-06 resolved as a direct consequence — no separate change needed.

---

## QA Validation Checklist

| ID | Test | Expected |
|----|------|----------|
| T-01 | BTC, ATR=50, price=60000, Tier1 | `floor(2.0/0.125)=16` → capped at 10x |
| T-05 | STRONG_TREND signal, fee-adj R/R at TP1 | > 1.0 for all tier/strategy combos |
| T-07 | `rr_filter_passed=false`, `fee_adjusted_rr=3.0`, Tier2 | Signal passes R/R check |
| T-09 | 4×Tier2 at 80/78/75/72, 1×Tier3 at 56 | 4 signals output (Tier3 rejected) |
| T-10 | BTC BBW=0.012 (Tier1) | OPTIMAL zone → 40 pts (was 25) |
| A-02 | Log scan_cycle_id at Row2 and Row3 entry | Matches Row1 value exactly |
| A-03 | Force retry on 1 symbol | No adjacent symbol receives misrouted data |
| A-04 | `Records with median_volume_2h` log line | Count > 0 |
| A-05 | Post-grouping interval check | All items have `interval === '2h'` |
