\# CRYPTO SIGNAL SYSTEM — CHANGELOG

Based on audit report at commit \`2eb9fc9\`.  
All fixes reference issue IDs from \`CRYPTO\_SIGNAL\_SYSTEM\_Execution\_Plan\_v2.md\`.

\---

\#\# \[Phase 4\] Risk & Trading Logic Fixes — commit \`c58c85c\`

## T-01 — Leverage Calculation Duplicated and Wrong

\*\*Files:\*\* \`row4/TP-SL CALCULATOR\`, \`row4/RISK-REWARD FILTER\`

TP-SL CALCULATOR was computing \`suggestedLeverage \= floor(10 / slDistancePct)\` using a  
hardcoded denominator \`10\` with undefined semantics, then outputting it as  
\`recommended\_leverage\`. RISK-REWARD FILTER recalculated and overwrote it — making the  
first computation dead code. Additionally, \`targetRiskPct\` values in RISK-REWARD FILTER  
were \*\*inverted\*\*: Tier 1 had 1.0% (lowest quality, tightest SL), Tier 3 had 2.0%  
(highest risk). Correct values are the opposite: Tier 1 \= 2.0%, Tier 2 \= 1.5%, Tier 3  
\= 1.0%. Tier 2 max leverage was also wrong (7.5x vs spec 7x).

\*\*Changes:\*\*  
\- Removed the entire leverage calculation block from TP-SL CALCULATOR.  
\- Removed \`recommended\_leverage\` from TP-SL CALCULATOR output.  
\- Renamed \`max\_leverage\_tier\` → \`tier\_max\_leverage\` (static tier cap, no calculation).  
\- Fixed \`targetRiskPct\`: Tier 1 \`1.0 → 2.0\`, Tier 3 \`2.0 → 1.0\`.  
\- Fixed \`TIER\_MAX\_LEVERAGE\[2\]\`: \`7.5 → 7\`.  
\- Surfaced \`leverage\_at\_minimum\` flag to top-level RISK-REWARD FILTER output  
 (was buried inside nested \`leverage\_calculation\` object, invisible to downstream nodes).

\---

## T-05 — TP1 Ratio 1:1 Produces Negative Expected Value at Leverage

\*\*File:\*\* \`row4/TP-SL CALCULATOR\`

All three strategies used \`tp\_ratios\[0\] \= 1.0\` for TP1. After trading fees of 0.11%  
total, fee-adjusted R/R at TP1 ≈ 0.89 — a net loss on every TP1 exit. At 5x leverage  
with 40–60% position allocated to TP1 and 50% win rate, the system was systematically  
losing on the most-hit take profit level on every trade.

\*\*Changes:\*\*  
\- \`STRONG\_TREND\` TP1 ratio: \`1.0 → 1.5\`  
\- \`MODERATE\_TREND\` TP1 ratio: \`1.0 → 1.3\`  
\- \`WEAK\_RANGING\` TP1 ratio: \`1.0 → 1.2\`  
\- \`WEAK\_RANGING\` TP1 allocation: \`60% → 50%\` (allows more position to run to TP2).  
\- \`WEAK\_RANGING\` remaining allocation rebalanced: \`30/10 → 35/15\`.  
\- All strategies now produce fee-adjusted R/R \> 1.0 at TP1.

\---

## T-07 — HARD FILTERS ENFORCER R/R Check Fragile

\*\*File:\*\* \`row4/HARD FILTERS ENFORCER\`

The \`risk\_reward\` filter check used \`rrFilterPassed && feeAdjustedRR \>= tierMin\`.  
The \`rrFilterPassed\` boolean is set by RISK-REWARD FILTER (node 5\) and must survive  
intact through the N8N Merge before reaching HARD FILTERS ENFORCER. In the event of  
a merge glitch, \`rrFilterPassed\` could arrive as \`false\` even when \`feeAdjustedRR\`  
is numerically valid (e.g., 3.0). This silently rejected correct signals. Additionally,  
there was no NaN/null guard on \`feeAdjustedRR\` before the numeric comparison.

\*\*Changes:\*\*  
\- Replaced \`rrFilterPassed && feeAdjustedRR \>= tierMin\` with  
 \`tpsl\_calculated \=== true && safeRR \>= tierMin\`.  
\- Added NaN/null guard: \`isNaN(feeAdjustedRR) ? 0 : (feeAdjustedRR ?? 0)\`.  
\- Removed \`upstream\_flag\_override\` and \`flag\_value\` diagnostic fields (now meaningless).  
\- Updated log line to display numeric R/R vs tier floor directly, with \`tpsl\_calculated\`  
 state, for cleaner debugging.

\---

## T-09 — Signal Ranking Tier Diversification Score-Blind

\*\*File:\*\* \`row4/SIGNAL RANKING & TOP 5 SELECTION\`

The tier diversification loop forced up to 2 Tier 3 slots without any score quality  
check. A Tier 3 signal at score 56 could displace a Tier 2 signal at score 72 purely  
because the Tier 3 count was below 2\. At 3x–5x leverage on small altcoins this  
represents direct, unnecessary user risk.

\*\*Changes:\*\*  
\- Added pre-loop detection: \`allAreTier3 \= sortedSignals.every(tier \=== 3)\`.  
\- Tier 3 candidates (only) are checked against a minimum score threshold before the  
 tier count slot is consumed:  
 \- If no signals selected yet: threshold \= \*\*50\*\* (Tier 3 absolute hard filter floor).  
 \- If signals already selected: threshold \= \*\*avg(selected scores) − 15\*\*.  
\- Candidates failing the threshold are pushed to \`skippedSignals\` with reason  
 \`SCORE\_BELOW\_TIER3\_THRESHOLD\` — the tier slot is \*\*not\*\* incremented.  
\- Exception: when \`allAreTier3 \= true\`, the relative threshold is bypassed entirely  
 (all signals are altcoins — likely altseason or risk-off cycle, both valid scenarios).  
\- \`portfolio\_composition\` object attached to every selected signal:  
 \`\`\`  
 { all\_tier3\_exception, tier\_distribution: {tier1, tier2, tier3}, portfolio\_risk\_level }  
 \`\`\`  
\- \`portfolio\_risk\_warning: 'ALL\_TIER3\_ELEVATED\_RISK'\` flag set when exception triggers,  
 for Telegram node to render a visible risk warning to subscribers.

\---

## T-10 — BBW Thresholds Not Tier-Aware, Tier 1 Structurally Underscored

\*\*File:\*\* \`row3/Volatility Score Calculator1\`

Bollinger Bands Width scoring used fixed global thresholds (\`≤0.02\` \= squeeze,  
\`≤0.05\` \= optimal) regardless of asset tier. BTC structurally operates at BBW  
0.010–0.018 — under fixed thresholds, a healthy BTC squeeze at BBW \= 0.012 scored  
25 pts (LOW zone) instead of the correct 40 pts (OPTIMAL zone). Small altcoins  
operating at BBW 0.05 were rewarded identically to BTC at BBW 0.05, which represents  
a very different volatility profile.

\*\*Changes:\*\*  
\- Replaced fixed thresholds with tier-aware lookup:  
 \- \*\*Tier 1\*\*: squeeze ≤ 0.008, optimal ≤ 0.015, elevated ≤ 0.025  
 \- \*\*Tier 2\*\*: squeeze ≤ 0.015, optimal ≤ 0.040, elevated ≤ 0.070  
 \- \*\*Tier 3\*\*: squeeze ≤ 0.025, optimal ≤ 0.060, elevated ≤ 0.100  
\- Default to Tier 2 thresholds when \`tier\` is null or unknown (conservative).  
\- Points per zone unchanged: squeeze \= 25, optimal \= 40, elevated \= 30, extreme \= 15\.  
\- \`bbw\_tier\_thresholds\` added to \`components\` output for audit traceability.  
\- Existing \`bbw\_1h \> 0\` guard retained (zero/NaN correctly skips the component).

\---

\#\# \[Phase 2–3\] Data Integrity \+ Pipeline Architecture — commits \`3fd014f\`, \`220f802\`, \`1599fd1\`

## A-02 — Dual scan\_cycle\_id Race Condition on Minute Boundary

\*\*Files:\*\* \`row1/Bulk Requests Generator\`, \`row2/Separation of Requests\`,  
\`row2/SMA 20 Calculation\`

\`scan\_cycle\_id\` was generated independently in three nodes via \`new Date()\`. At a  
minute boundary, slow execution could produce different IDs per node, causing  
Row 3's Fetch Data AFTER TAAPI to query the wrong cycle and return 0 results.

\- \*\*Bulk Requests Generator\*\*: removed \`new Date()\` regeneration; reads  
 \`scan\_cycle\_id\` from input items (propagated from Crypto Symbols Metadata),  
 with fallback to \`$('Crypto Symbols Metadata')\` cross-node reference; throws  
 explicitly if ID is absent.  
\- \*\*Separation of Requests\*\*: same removal; reads from first input item; throws  
 if absent rather than silently continuing.  
\- \*\*SMA 20 Calculation\*\*: replaced \`|| 1\` fallback (which produced numeric \`1\`  
 as a cycle ID) with explicit throw on missing ID; uses upstream \`cycle\_timestamp\`.  
\- \*\*Note:\*\* Fetch Data AFTER TAAPI (HTTP GET node, no code file) still requires a  
 manual N8N workflow edit to pass the incoming \`scan\_cycle\_id\` into its WHERE clause.

\---

## A-03 — GROUP CANDLE RESPONSES Positional Matching Unsafe on HTTP Retry

\*\*Files:\*\* \`row1/GROUP CANDLE RESPONSES\`, \`row1/Bulk Requests Generator\`

The original algorithm used \`responsePointer\` (positional index) to match HTTP  
responses to symbols/intervals. HTTP retry or parallel connections could reorder  
responses, silently swapping BTCUSDT indicators onto ETHUSDT candles.

\- \*\*Option A implemented\*\* (4 separate interval HTTP nodes):  
 GROUP CANDLE RESPONSES rewritten to pull from 4 cross-node references  
 (\`$('Filter 2h Requests')\` / \`$('Binance 2h')\`, etc.) — interval identity is  
 structurally guaranteed by which HTTP node produced the response.  
\- Symbol identity derived from Filter node output order (deterministic, matches  
 Bulk Requests Generator sort).  
\- Timestamp-gap validation retained as secondary safety check.  
\- \*\*v4.1 patch\*\*: auto-detects N8N "Split Into Items" ON/OFF mode by comparing  
 \`resp.length\` to \`meta.length × limit\`. Split ON slices by index; Split OFF reads  
 array directly. Both paths produce identical downstream output.  
\- 15m limit reverted \`2 → 1\` (Option B disambiguation no longer needed).

\---

## A-04 — DE-DUPLICATION Drops median\_volume Fields

\*\*File:\*\* \`row2/DEBUG \+ DE-DUPLICATION\`

The \`validCandles.push({json:{...}})\` block used an explicit field list that omitted  
\`median\_volume\_1h\` and \`median\_volume\_2h\`. VOLUME SCORE CALCULATOR always fell back  
to \`cs\_volume / 24\` estimation. The node's own log confirmed: \`Records with  
median\_volume\_2h: 0\`.

\- Added \`median\_volume\_1h\` and \`median\_volume\_2h\` to the reconstruction block.  
\- Added \`latest\_1m\_price\` propagation for downstream Price Action scoring (T-06 prep).  
\- Zero values pass through as zero — not defaulted to null or omitted.

\---

## A-05 Candles Grouping Mixes Intervals, SMA 20 Always Null

\*\*File:\*\* \`row2/Candles Grouping & Latest 20 per Symbol\`

All intervals (2h \+ 1h \+ 15m \+ 1m) were grouped together by symbol only. The  
\`latest 20 by open\_time\` sort was dominated by 1m and 15m candles, leaving fewer  
than 2 genuine 2h candles per symbol in the SMA input. SMA 20 Calculation requires  
exactly 20 and skipped every symbol — \`sma\_20 \= null\` for all symbols every cycle.

\- Added pre-grouping filter: \`interval \=== '2h'\` only.  
\- With 2h candles at limit 20, each symbol now provides exactly 20 candles.  
\- A-06 resolved as a direct consequence — no separate change needed.

## A-06 — SMA 20: Guaranteed 20 × 2h Candles

\*\*Severity:\*\* High (dependent on A-05)  
\*\*Root Cause:\*\* SMA 20 requires exactly 20 completed 2h candles per symbol. Due to the  
A-05 interval mixing problem, the node was receiving fewer than 20 qualifying candles for  
many symbols and silently skipping their SMA calculation (\`SKIPPING SMA 20 calculation\`  
log line). The SMA skip meant those symbols had no SMA-based signal data for the cycle.

\*\*File:\*\* \`row2/SMA 20 Calculation\` (already reads only close\_price and open\_time — no  
code changes required in this node once A-05 is resolved)

\*\*Resolution:\*\* With the A-05 2h filter in place, \`Candles Grouping & Latest 20 per  
Symbol\` now delivers exactly 20 2h candles per symbol. SMA 20 Calculation receives the  
correct input and completes for all symbols without skip conditions.

\*\*Additional A-02 hardening applied in this node (same release):\*\*  
\- \`scan\_cycle\_id || 1\` replaced with \`|| null\` \+ explicit throw.  
\- \`cycle\_timestamp: new Date().toISOString()\` replaced with propagated upstream value.

\---

## **T-08 — Volatility Score Race Condition Eliminated**

**Files:** `row3/ATR Volatility Analyzer2`, `row3/Restore Full Data After Tier Insert`

**Problem:** Two nodes were writing `volatility_score` into the pipeline simultaneously. `ATR Volatility Analyzer2` calculated and output the score during the tier classification phase. That value then got saved to Supabase and re-read by `Restore Full Data After Tier Insert`, which propagated it into all 5 scoring branches as the starting value. Meanwhile, `Volatility Score Calculator1` (Branch 3\) was the designated authoritative producer — but it was overwriting a value that had already spread through the pipeline, creating a non-deterministic race depending on execution order.

**Fix:** Removed `volatility_score` from the output of `ATR Volatility Analyzer2`. The node still calculates and uses `volatility_status`, `atr_percentage_1h`, `volatility_warning`, and `risk_level` — all of which are needed downstream for Supabase and Merge input. Only the score field was removed. `Restore Full Data After Tier Insert` was updated to no longer propagate `volatility_score` from `tierData`. `Volatility Score Calculator1` (Branch 3\) is now the sole, uncontested producer.

---

## **T-04 — Trend Score Calculator: Three Structural Bugs Fixed**

**File:** `row3/TREND SCORE CALCULATOR`

**Problem:** A brace-depth trace of `calculateTrendScore` revealed three compounding structural bugs:

1. **EMA block nested inside MACD block.** The entire EMA alignment check (Component 3, 30 points max) was inside the `if (macd_value_2h !== 0 || macd_signal_2h !== 0)` conditional. Any symbol with MACD data of exactly zero had its EMA component silently skipped — 30 points never evaluated.  
2. **`macdContribution` never added to `totalScore`.** The MACD contribution was calculated correctly and stored in `macdContribution`, but `totalScore += macdContribution` was missing. MACD's 30 points were computed and then silently dropped every cycle. Only ADX and EMA contributions were ever summed.  
3. **`return` statement inside the MACD block.** The final score calculation and `return` were placed inside the MACD `if` block. When MACD was absent (value and signal both zero), the function returned `undefined` instead of the zero-score guard object. Any downstream consumer calling `.score` on the result would get a runtime error.

**Fix:** Full rewrite of the function. All three components (ADX, MACD, EMA) are now fully independent `if` blocks at the same nesting depth. `totalScore += macdContribution` is called before the MACD block closes. The final score calculation and `return` are outside all component blocks — they execute unconditionally after all three components have had the opportunity to contribute.

**Calibration logging added:** For the first cycles post-fix, `trend_components` includes both `trend_score_legacy` (ADX \+ EMA only, replicating the pre-fix silent behavior) and `trend_score_v4` (the correct full score) side-by-side. This makes the magnitude of the correction visible without requiring a separate audit run.

**Impact:** For any symbol where MACD data was present, the trend score was previously understated by up to 30 raw points (the missing MACD contribution). The actual final score shift depends on the `maxScore` denominator, but the direction is always upward correction for symbols with valid MACD data.

---

## **T-06 — 1-Minute Price Used for VWAP Distance \+ Deviation Guard**

**Files:** `row3/Price Action Score Calculator`, `row4/TP-SL CALCULATOR`

**Problem:** Two separate issues around price freshness:

1. `Price Action Score Calculator` was using `close_price` (the 2h OHLC close) to calculate VWAP distance in Component 1\. The pipeline already carries `latest_1m_price` — a real-time price extracted from the 1-minute candle processor — which is significantly more accurate for a live distance-to-VWAP calculation. Using a 2h close against a 1h VWAP produces a distance figure that can be up to 2 hours stale.  
2. `TP-SL CALCULATOR` consumed `latest_1m_price` without any sanity check. In rare edge cases (data pipeline delay, exchange glitch, candle processor timing issue), the 1m price could diverge substantially from the 2h close. Using a significantly wrong price for TP/SL math produces incorrect take-profit and stop-loss levels sent to the trading layer.

**Fix (Price Action Score Calculator):** Component 1 VWAP distance now uses `latest_1m_price` when available, falling back to `close_price` only if `latest_1m_price` is zero or absent. Components 2 and 3 continue using `close_price` as before — they rely on 2h OHLC structure (candle body, wick analysis), where the 1m price is not appropriate. The price source used (`1m` or `1h_close(fallback)`) is logged per symbol.

**Fix (TP-SL CALCULATOR):** Replaced the single-line `parseFloat(data.latest_1m_price || ...)` with a deviation sanity check. If both prices are available and `|latest_1m_price − close_price| / close_price > 3%`, a `console.warn` is emitted showing both values and the deviation percentage, and `close_price` is substituted. Below 3%, `latest_1m_price` is used as intended. The 3% threshold is conservative enough to catch genuine data anomalies while accepting normal intraday volatility.

---

## **T-02 — Momentum Direction Correction**

**File:** `row3/SCORE AGGREGATOR` (Step 4\)

**Problem:** The momentum score measures how strong recent price movement is — but it does not account for direction. A momentum score of 80 on a SHORT signal means the asset is showing strong bullish momentum, which directly contradicts the short thesis. The previous aggregator applied the momentum weight unconditionally, so a highly bullish momentum reading could inflate a SHORT signal's total score.

**Fix:** Added `getMomentumCorrectionMultiplier(score, direction)` applied as a multiplier on the weighted momentum contribution (not on the raw score). The multiplier table:

| Signal | Momentum Score | Multiplier |
| ----- | ----- | ----- |
| SHORT | ≥ 75 | 0.35 |
| SHORT | ≥ 60 | 0.55 |
| SHORT | ≥ 50 | 0.80 |
| SHORT | \< 50 | 1.00 |
| LONG | ≤ 25 | 0.35 |
| LONG | ≤ 40 | 0.55 |
| LONG | ≤ 50 | 0.80 |
| LONG | \> 50 | 1.00 |
| NEUTRAL | any | 1.00 |

The raw `momentum_score` field is preserved unchanged for downstream nodes. `momentum_correction_multiplier` is added to `score_breakdown` for full audit traceability.

**Verification case:** SHORT signal, `momentum_score = 72`, `weight_momentum = 0.21` → weighted contribution before correction: `72 × 0.21 = 15.12`. After correction: `15.12 × 0.55 = 8.32`.

---

## **T-03 — OBV Volume Direction Correction**

**File:** `row3/SCORE AGGREGATOR` (Step 4\)

**Problem:** OBV (On-Balance Volume) is directional — it rises when volume flows into an asset on up-candles and falls on down-candles. A strongly positive OBV confirms bullish accumulation. When the signal direction is SHORT, a high `volume_score` driven by strong positive OBV is providing contradictory evidence, yet the aggregator was applying it at full weight. This inflated SHORT signal scores when buying pressure was actually strong.

**Fix:** Added `getVolumeCorrectionMultiplier(score, direction, obv)` applied as a multiplier on the weighted volume contribution. The multiplier uses the raw `obv_1h` value (absolute magnitude), not the derived volume score:

| Signal | OBV 1h Value | Multiplier |
| ----- | ----- | ----- |
| SHORT | \> 1,000,000 | 0.75 |
| SHORT | \> 500,000 | 0.85 |
| SHORT | ≤ 500,000 | 1.00 |
| LONG | \< −1,000,000 | 0.75 |
| LONG | \< −500,000 | 0.85 |
| LONG | ≥ −500,000 | 1.00 |
| NEUTRAL | any | 1.00 |

The ceiling is 0.75 (not lower) because OBV accounts for only 30 of the 100 volume points — the remaining 70 are direction-neutral volume metrics. Over-penalizing the full volume component would underweight volume information that is not direction-conflicted. `volume_correction_multiplier` and `obv_1h_at_correction` (the OBV value at the time of correction) are both added to `score_breakdown`.

## **A-01 — TAAPI Secret Key Removed from Source Code**

**File:** `row2/Separation of Requests`

**Problem:** The TAAPI JWT secret was hardcoded as a string literal directly in the Code node:

const SECRET\_KEY \= "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...";

This is a critical security vulnerability. Any person with read access to the N8N workflow — including exports, version history, shared workflow links, or N8N instance backups — would have full access to the TAAPI account. The secret cannot be rotated without editing source code, and there is no audit trail of where or how it is used.

**Fix:** Replaced the hardcoded value with an N8N environment variable reference:

const SECRET\_KEY \= $env.TAAPI\_SECRET\_KEY;  
if (\!SECRET\_KEY) {  
 throw new Error('CRITICAL \[A-01\]: TAAPI\_SECRET\_KEY env var is missing or empty...');  
}

The explicit `throw` on missing variable is intentional — silent fallback to an empty string would cause all TAAPI requests to fail with authentication errors that are harder to diagnose than an immediate, named halt at startup. The secret must now be configured once in N8N's environment variables panel and is never written into workflow source.

---

## **A-07 — Broken Rate-Limit Cooldown Replaced**

**File:** `row2/Cooldown after Batch 6`

**Problem:** The node was using `setTimeout` to pause execution between TAAPI request batches:

await new Promise(resolve \=\> setTimeout(resolve, 30000));

This does not work in N8N Cloud. Code nodes have an execution timeout of approximately 10 seconds. A 30-second `setTimeout` is silently killed by the runtime before it resolves — the "cooldown" provided zero actual delay. The system was firing all TAAPI batches back-to-back with no rate-limit protection, relying on a mechanism that was never functioning.

**Fix:** The Code node was rewritten as a clean passthrough — it logs the current batch index and total batch count, then returns `$input.all()` unchanged. The actual cooldown must be implemented using N8N's native **Wait** node, which is the only mechanism that survives beyond the Code node timeout. The node contains inline documentation specifying exactly where Wait nodes must be inserted in the workflow editor (after batch index 6: \+30s, after batch index 12: \+20s) and how to configure them. This makes the architectural requirement explicit and visible rather than hidden in broken code.

---

## **A-08 — 72h History Validation: 1,750 Redundant API Calls Eliminated**

**File:** `row1/Validate 72h History`

**Problem:** The node was fetching 36 candles per symbol to validate that 72 hours of history exists on Binance:

const requiredCandles \= 36;  
// ...  
limit: 36

With 50 symbols per cycle, this was 50 × 36 \= **1,800 Binance API calls per validation run** — solely to confirm that data exists before the actual data fetch. The validation check itself only needed to know whether *any* candle was returned; it never used candles 2 through 36 for anything. The full 36-candle fetch was dead weight on every cycle.

**Fix:** Reduced the fetch limit to 1:

const requiredCandles \= 1;  // \[A-08\] minimal existence check only  
// ...  
limit: 1

The validation logic is unchanged — it still checks whether the response contains at least `requiredCandles` entries and marks the symbol as valid or invalid accordingly. The only difference is that it now fetches the single most recent candle instead of 36\. This reduces validation-phase Binance calls from \~1,800 to \~50 per cycle — a **97% reduction** — with no change to what the node actually validates.

---

## **A-10 — Silent Weight Failures Made Detectable**

**Files:** `row3/Merge` (SQL), `row3/SCORE AGGREGATOR`

**Problem:** The Merge node joins 5 parallel scoring branches using LEFT JOIN on `symbol`. If the ADX/Adaptive Weights branch (input1) fails or produces no output for a given symbol, `market_condition`, `adx_strength`, and all six `weight_*` fields arrive at the SCORE AGGREGATOR as SQL `NULL`. The aggregator was handling this with silent JavaScript defaults:

const marketCondition \= data.market\_condition || 'NEUTRAL';  
const weights \= {  
 momentum: parseFloat(data.weight\_momentum) || 0.25,  
 trend:    parseFloat(data.weight\_trend)    || 0.25,  
 // ...  
};

When the ADX branch failed, the system would silently score the symbol using generic equal weights, produce a `total_score`, and pass it downstream as if it were a legitimate signal. The resulting signal had no meaningful weight calibration and no indication in the output that anything was wrong.

**Fix — Merge SQL:** Added `COALESCE` sentinels for all ADX branch fields. String fields use a named sentinel; numeric fields use `-1` (a value that cannot appear in valid normalized weights):

COALESCE(input1.market\_condition, 'WEIGHTS\_MISSING') as market\_condition,  
COALESCE(input1.adx\_strength,     'WEIGHTS\_MISSING') as adx\_strength,  
COALESCE(input1.weight\_momentum,     \-1) as weight\_momentum,  
COALESCE(input1.weight\_trend,        \-1) as weight\_trend,  
COALESCE(input1.weight\_volatility,   \-1) as weight\_volatility,  
COALESCE(input1.weight\_volume,       \-1) as weight\_volume,  
COALESCE(input1.weight\_price\_action, \-1) as weight\_price\_action,

**Fix — SCORE AGGREGATOR:** Added two fail-fast guards at the top of Step 2\. The first checks for the `'WEIGHTS_MISSING'` sentinel; the second checks for any weight field that is `null`, `NaN`, or negative (the `-1` sentinel). Either condition causes the symbol to be excluded via `return null`:

if (marketCondition \=== 'WEIGHTS\_MISSING' || adxStrength \=== 'WEIGHTS\_MISSING') {  
 console.error(\`\[A-10\] WEIGHTS\_MISSING for ${data.symbol} — signal excluded.\`);  
 return null;  
}  
const hasInvalidWeights \= Object.values(rawWeights).some(w \=\> isNaN(w) || w \< 0);  
if (hasInvalidWeights) {  
 console.error(\`\[A-10\] INVALID WEIGHTS for ${data.symbol} — signal excluded.\`);  
 return null;  
}

The `results` array is filtered with `results.filter(Boolean)` before return, cleanly removing all excluded symbols. The net effect: an ADX branch failure no longer produces phantom signals — it produces a named error log and a clean exclusion, with no silent fallback behavior anywhere in the path.

\#\# QA Validation Checklist

| ID | Test | Expected |  
|----|------|----------|  
| T-01 | BTC, ATR=50, price=60000, Tier1 | \`floor(2.0/0.125)=16\` → capped at 10x |  
| T-05 | STRONG\_TREND signal, fee-adj R/R at TP1 | \> 1.0 for all tier/strategy combos |  
| T-07 | \`rr\_filter\_passed=false\`, \`fee\_adjusted\_rr=3.0\`, Tier2 | Signal passes R/R check |  
| T-09 | 4×Tier2 at 80/78/75/72, 1×Tier3 at 56 | 4 signals output (Tier3 rejected) |  
| T-10 | BTC BBW=0.012 (Tier1) | OPTIMAL zone → 40 pts (was 25\) |  
| A-02 | Log scan\_cycle\_id at Row2 and Row3 entry | Matches Row1 value exactly |  
| A-03 | Force retry on 1 symbol | No adjacent symbol receives misrouted data |  
| A-04 | \`Records with median\_volume\_2h\` log line | Count \> 0 |  
| A-05 | Post-grouping interval check | All items have \`interval \=== '2h'\` |

