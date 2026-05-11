# CRYPTO SIGNAL SYSTEM — AUDIT REPORT
## Revision: commit bd7b902 vs Execution Plan v2
## Audit Date: 2026-05-11
## Auditor scope: Priority 1 (unchanged-SHA files) + Priority 2 (changed files regression)

---

## 1. ARCHITECTURAL ISSUES

---

### [A-07] Cooldown after Batch 6 — setTimeout NOT removed (fix NOT applied)
**File:** `row2/Cooldown after Batch 6` — SHA 52d94ceb (UNCHANGED)

**Problem:**
The Changelog claims this node was "rewritten as passthrough." The file at bd7b902 still contains two `setTimeout`-based Promises: 30 seconds after batch 6, 20 seconds after batch 12. The node is NOT a passthrough. The fix was not applied.

**Risk:** P1 — In N8N's Code node, `return new Promise(resolve => { setTimeout(...) })` is not supported in all execution modes (especially queue mode). If N8N's execution engine does not support async Promise resolution in Code nodes, this causes a silent hang or unhandled rejection that terminates the batch loop without error. Even where it technically works, adding 30–50 seconds of artificial latency per full pipeline run degrades throughput. This is a known architectural anti-pattern for N8N.

**Explanation:**
Batch 6 index check `batchIndex === 6` uses `$('Loop Over Items1').context.currentRunIndex`. If the loop context is ever unavailable (e.g. direct execution, test mode), `batchIndex` defaults to `0`, triggering the 30-second cooldown on EVERY run.

**QA Note:** Verify by checking N8N execution logs for 30-second gaps between batch 6 and 7. Confirm whether N8N version in use supports Promise-returning Code nodes.

---

### [A-09] ASSET TIER CALCULATOR — Tier boundaries do not match Execution Plan
**File:** `row3/ASSET TIER CALCULATOR` — SHA 44036c67 (UNCHANGED, not in Changelog)

**Problem:**
The Execution Plan specifies Tier 1 = rank 1–5, Tier 2 = rank 6–15, Tier 3 = rank 16–20. The actual `TIER_CONFIG` in production uses: Tier 1 = rank 1–10, Tier 2 = rank 11–40, Tier 3 = rank 41–150. This was flagged as A-09 (not in Changelog, not applied).

**Risk:** P1 — The tier assignment directly controls: SL multiplier (1.5/2.0/2.5x ATR), max leverage cap (10/7/5x), BBW thresholds in Volatility Score, targetRiskPct in R/R Filter (2.0/1.5/1.0%), and the minimum R/R floor (1.5/2.0/2.5). Misclassifying a rank-6 asset as Tier 1 instead of Tier 2 reduces its SL multiplier from 2.0 to 1.5 (tighter stop = higher stop-hunt risk) and raises its leverage cap from 7x to 10x. The opposite mis-tier (rank-11 asset classified Tier 2 instead of Tier 1) gives it a wider SL and lower leverage cap than intended.

**Explanation:**
The current boundaries (1–10, 11–40, 41–150) form a valid alternative configuration, but they are inconsistent with the Execution Plan. Since A-09 is not in the Changelog, it is unclear whether these boundaries were intentionally retained or are simply an unfixed bug. No fix was ever committed.

**QA Note:** Confirm with product owner whether the intended boundaries are plan-v2 (1-5/6-15/16-20) or the wider current config (1-10/11-40/41-150). Until confirmed, the mismatch is a live risk.

---

### [A-10] SCORE AGGREGATOR + Merge — WEIGHTS_MISSING sentinel NOT added (fix NOT applied)
**File:** `row3/SCORE AGGREGATOR` — SHA bfc2fe5f (UNCHANGED); `row3/Merge` — SHA a041a86b (UNCHANGED)

**Problem:**
The Changelog claims a `WEIGHTS_MISSING` sentinel was added to Merge SQL and a `results.filter(Boolean)` fail-fast guard was added to SCORE AGGREGATOR. Neither is present in either file. The Merge node has no sentinel column. SCORE AGGREGATOR does not call `filter(Boolean)` or check for a missing-weights indicator.

**Risk:** P1 — If the Adaptive Weights Calculator node fails or produces null weights, SCORE AGGREGATOR silently falls back to hardcoded defaults (`weight_momentum: 0.25`, etc.) via the `|| 0.25` pattern. This means a pipeline failure upstream produces signals scored as if the market condition were NEUTRAL with equal weights — no error is raised, no signal is suppressed. Downstream ranking and filtering proceed with corrupted quality scores.

**QA Note:** Test by deliberately making the Adaptive Weights Calculator node return empty output. Confirm whether an alert fires or signals silently proceed with fallback weights.

---

## 2. SIGNAL QUALITY ISSUES

---

### [T-04] TREND SCORE CALCULATOR — EMA block nested inside MACD block (fix NOT applied)
**File:** `row3/TREND SCORE CALCULATOR` — SHA 466d12f0 (UNCHANGED)

**Problem:**
The Changelog claims a "full rewrite" where three bugs were fixed: (1) EMA block nested in MACD if, (2) `macdContribution` never added to `totalScore`, (3) `return` inside MACD block cutting off EMA. In the file at bd7b902, all three bugs remain present in exactly the described form:

- `macdContribution` is computed inside the MACD block but `totalScore += macdContribution` is ABSENT. The MACD contribution is never added to `totalScore`.
- The entire Component 3 (EMA Alignment) code block — including `maxScore += 30`, the alignment logic, and `totalScore += emaContribution` — is physically nested inside the MACD `if (macd_value_2h !== 0 || macd_signal_2h !== 0)` block's closing brace. This is confirmed by indentation and brace structure in the file.
- The closing brace of the MACD block wraps both MACD scoring and EMA scoring, so if MACD data is missing (both values === 0), EMA scoring is entirely skipped and `maxScore` is never incremented by 30, causing `finalScore` to be calculated over a smaller denominator.

The return value references `histogramPct` which is declared inside the MACD block. If MACD data is absent, `histogramPct` is undefined and the `return` of `calculateTrendScore` throws a ReferenceError, crashing the entire symbol batch.

**Impact:** P0 — MACD contribution (up to 30 points, 30% of max) is always zero regardless of signal quality. EMA contribution is suppressed whenever MACD indicators are zero, which occurs during low-volatility or data-gap conditions. `trend_score` is systematically underweighted, producing lower total scores and incorrect signal ranking. Additionally, any symbol with both `macd_value_2h === 0` and `macd_signal_2h === 0` will throw a ReferenceError (`histogramPct is not defined`), propagating an unhandled exception.

**QA Note:** Verify by checking any symbol where `macd_value_2h === 0`: the node should either throw or return `trend_score: 0`. Check production logs for ReferenceError stack traces from TREND SCORE CALCULATOR.

---

### [T-02] SCORE AGGREGATOR — getMomentumCorrectionMultiplier() NOT added (fix NOT applied)
**File:** `row3/SCORE AGGREGATOR` — SHA bfc2fe5f (UNCHANGED)

**Problem:**
The Changelog claims `getMomentumCorrectionMultiplier()` was added at Step 4 with the SHORT direction table: ≥75 → 0.35, ≥60 → 0.55, ≥50 → 0.80, <50 → 1.00. The function does not exist in the file. There is no `momentum_correction_multiplier` field in `score_breakdown`. Step 4 computes `weightedMomentum = momentumScore * weights.momentum` with no direction-based correction.

**Impact:** P1 — SHORT signals with high momentum scores (RSI overbought, strong upward histogram) receive full momentum weight despite being counter-directional. A SHORT signal with `momentumScore = 75` should receive a 0.35 multiplier (reducing its momentum contribution by 65%). Without the fix, that signal receives 100% momentum weight, inflating `total_score` by up to `75 × 0.25 × 0.65 ≈ 12 points`. This corrupts signal ranking: over-scored SHORT signals displace correctly scored LONG signals in Top 5 selection.

**QA Note:** Identify recent SHORT signals in Telegram output with momentum_score ≥ 60. Their `total_score` is artificially inflated by up to 12 points.

---

### [T-03] SCORE AGGREGATOR — getVolumeCorrectionMultiplier() NOT added (fix NOT applied)
**File:** `row3/SCORE AGGREGATOR` — SHA bfc2fe5f (UNCHANGED)

**Problem:**
The Changelog claims `getVolumeCorrectionMultiplier()` was added with OBV-based SHORT correction: SHORT with OBV > 1M → 0.75, OBV > 500k → 0.85. The function does not exist in the file. There is no `volume_correction_multiplier` field in output. Volume score is applied at full weight for all directions unconditionally.

**Impact:** P1 — SHORT signals on high-OBV assets (strong net buying pressure) should have their volume contribution penalized. Without the correction, a SHORT signal with `volume_score = 80` and `obv_1h > 1M` receives its full weighted contribution. The OBV data is present in the pipeline (passed through SCORE AGGREGATOR as `obv_1h`) but unused for this purpose.

**QA Note:** Check `obv_1h` values on recent SHORT signals to quantify the potential score inflation.

---

### [T-06] Price Action Score Calculator — close_price used instead of latest_1m_price for VWAP distance
**File:** `row3/Price Action Score Calculator` — SHA 88105116 (UNCHANGED)

**Problem:**
The Changelog claims `latest_1m_price` should be used for VWAP distance calculation instead of `close_price`. The file still uses `close_price` as the reference price in Component 1 (VWAP Analysis): `const close_price = parseFloat(data.close_price)` followed by `const vwapDistance = ((close_price - vwap_1h) / vwap_1h) * 100`. `latest_1m_price` is not referenced anywhere in this file.

**Impact:** P1 — `close_price` is the last 1h candle close, which can be up to 60 minutes stale. `vwap_1h` is the current session VWAP. For assets with intra-hour price moves of 1–3% (common in Tier 3), the VWAP distance classification can shift by an entire category (e.g., from "near VWAP +50 points" to "overextended +20 points"). VWAP is the highest-weighted component (50 of 100 max points), so a wrong category directly corrupts `price_action_score` by up to 30 points. This in turn corrupts `total_score` by up to `30 × weight_price_action ≈ 3 points`, which is material at the score-floor boundary.

**QA Note:** `latest_1m_price` is correctly extracted in `Restore Full Data After Tier Insert` and propagated through `Merge`. It is available in the input to Price Action Score Calculator. The fix is a single variable substitution.

---

### [T-08] ATR Volatility Analyzer2 — volatility_score field NOT removed from output (fix NOT applied)
**File:** `row3/ATR Volatility Analyzer2` — SHA b8c87078 (UNCHANGED)

**Problem:**
The Changelog claims `volatility_score` should be REMOVED from ATR Volatility Analyzer2's output because the authoritative `volatility_score` is computed by the separate `Volatility Score Calculator1` node. The file still explicitly outputs `volatility_score: volatilityScore` in its return object alongside all other fields via the spread `...data`.

**Impact:** P1 — ATR Volatility Analyzer2 uses a simplified scoring table (EXTREME=25, HIGH=50, NORMAL=75, LOW=95) that ignores tier-specific BBW thresholds. Volatility Score Calculator1 uses a more sophisticated model with tier-aware ATR bands and BBW tiers. In the Merge SQL, `input3.volatility_score` is the field used (where input3 = ATR Volatility Analyzer2 branch based on column ordering). If ATR Analyzer2's `volatility_score` takes precedence over Volatility Score Calculator1's score in the merge, the BBW component (40 of 100 max points in the proper scorer) is silently discarded.

**Explanation:**
The Merge node explicitly assigns `input3.volatility_score` (not COALESCE across all inputs). The question of which node maps to input3 determines which score wins. If this is ATR Analyzer2, the simplified score propagates to SCORE AGGREGATOR.

**QA Note:** Trace which node feeds `input3` in the Merge node connection order. If ATR Analyzer2 is input3, the BBW-aware volatility score from Volatility Score Calculator1 is never used.

---

### [T-08] Restore Full Data After Tier Insert — volatility_score IS propagated from tierData (fix NOT applied)
**File:** `row3/Restore Full Data After Tier Insert` — SHA ac71af4b (UNCHANGED)

**Problem:**
The Changelog claims `volatility_score` should NOT be propagated from `tierData` in this node. The file explicitly includes `volatility_score: tierData.volatility_score` in the merge output object (line in Step 4 merge block). This overwrites the `volatility_score` that was computed by any scoring branch with the value stored in the Supabase tier record (which was written by ATR Volatility Analyzer2).

**Impact:** P1 — Combined with the T-08 finding above: the chain is ATR Analyzer2 → Supabase INSERT → Restore Full Data reads back `volatility_score` from Supabase and re-injects it, permanently overwriting any BBW-aware score. Even if Volatility Score Calculator1 produces the correct score and it is COALESCEd correctly in Merge, Restore Full Data After Tier Insert re-introduces the ATR-only score into the data object used by all five scoring branches. The Volatility Score Calculator1 then overwrites this again — but the correctness of the final value depends entirely on execution order of the fan-out branches.

**QA Note:** Verify the execution order of the five branches after Restore Full Data. If Volatility Score Calculator1 runs AFTER the data merge, its `volatility_score` is the final value in the Merge input. If it runs before, ATR Analyzer2's score wins via the Merge SQL `input3.volatility_score` assignment.

---

## 3. REGRESSION FINDINGS (REVISION ROUND)

---

### [R-01] TREND SCORE CALCULATOR — macdHistogramPct undefined causes ReferenceError (new crash vector)
**File:** `row3/TREND SCORE CALCULATOR` — SHA 466d12f0

**Problem:**
The return statement of `calculateTrendScore` references `histogramPct` unconditionally. `histogramPct` is declared with `let` inside the MACD `if` block. If `macd_value_2h === 0 AND macd_signal_2h === 0`, the MACD block is skipped, `histogramPct` is never declared, and the `return { ..., macd_histogram_pct: histogramPct }` line throws `ReferenceError: histogramPct is not defined`. This crashes `calculateTrendScore`, propagates as an unhandled exception in the `.map()`, and causes the entire TREND SCORE CALCULATOR to return an empty array or throw, halting the pipeline for that cycle.

**Plan vs Implementation:** The Execution Plan (T-04) specified that the EMA block should be made independent and the return statement should be outside both conditionals, which would have exposed and forced resolution of the `histogramPct` scoping issue. Since T-04 was not applied, this crash vector was not introduced by the fix — it pre-existed — but it was supposed to have been resolved.

**Risk:** P0 — Any symbol with zero MACD values (which can occur with stale data, new listings, or TAAPI errors returning 0) causes a full node crash for that execution cycle.

**QA Note:** Search N8N execution history for "ReferenceError" in TREND SCORE CALCULATOR output. Monitor for cycles where trend_score is absent from downstream nodes.

---

### [R-02] HARD FILTERS ENFORCER — risk_reward filter uses tpsl_calculated AND NaN guard, but rr_filter_passed is NOT used
**File:** `row4/HARD FILTERS ENFORCER` — SHA 48227461 (CHANGED)

**Problem:**
The Changelog for T-07 claims the condition was changed to `tpsl_calculated === true && safeRR >= tierMin` (not `rrFilterPassed AND`). The implementation correctly uses `data.tpsl_calculated === true` as the primary guard and a NaN-safe expression for `feeAdjustedRR`. However, `rrFilterPassed` (which is `data.rr_filter_passed === true`) is extracted but then only used in the `console.log` output — it is NOT part of the `risk_reward` filter check logic. This creates an inconsistency: a signal that somehow passed RISK-REWARD FILTER (rrFilterPassed=true) but has `tpsl_calculated` missing would be correctly caught by the new guard. Conversely, a signal with `rr_filter_passed: false` but `tpsl_calculated: true` and sufficient R/R would pass the Hard Filter. This is likely the intended behavior but creates a documentation discrepancy.

**Plan vs Implementation:** The plan said "not rrFilterPassed AND" — the implementation dropped `rrFilterPassed` from the condition entirely and re-checks R/R from raw values. This is correct, but `rrFilterPassed` being extracted and unused creates dead code.

**Risk:** P2 — Dead code / maintenance risk. The `rrFilterPassed` variable is assigned and console-logged but never affects control flow. If a future developer assumes it contributes to the filter decision, they may introduce a bug by modifying it.

**QA Note:** The functional filter behavior is correct. The dead variable is a maintenance issue only.

---

### [R-03] TP-SL CALCULATOR — WEAK_RANGING TP1 allocation is 50%, plan says 50% (CORRECT), but strategy comment says "reduce TP1 allocation to let more run"
**File:** `row4/TP-SL CALCULATOR` — SHA 1c911ab8 (CHANGED)

**Problem:**
The audit checklist asks to verify WEAK_RANGING TP1 allocation = 50% (not 60%). The implementation has `allocation: [50, 35, 15]` for WEAK_RANGING — TP1 is 50%. This matches the plan. However, the inline comment reads "reduce TP1 allocation to let more run to TP2," which is internally contradictory: if the previous version had TP1 at 60%, reducing it to 50% is correct — but 50% is still a majority allocation to TP1, not a reduction that "lets more run." The comment describes an intent inconsistent with the actual numbers: TP2 receives only 35% with WEAK_RANGING.

**Plan vs Implementation:** T-05 allocation is correctly implemented at [50, 35, 15] for WEAK_RANGING. The TP1 ratio is 1.2 (per plan). The discrepancy is documentation only.

**Risk:** P2 — The allocation is numerically correct. The misleading comment could cause a future developer to "fix" the allocation, reintroducing the original 60% figure.

**QA Note:** Minor — confirm the previous version used 60% for TP1 in WEAK_RANGING to validate the comment's historical context.

---

### [R-04] RISK-REWARD FILTER — TIER_MIN_RR does not match HARD FILTERS ENFORCER tier thresholds
**File:** `row4/RISK-REWARD FILTER` — SHA 5077e707 (CHANGED); `row4/HARD FILTERS ENFORCER` — SHA 48227461 (CHANGED)

**Problem:**
RISK-REWARD FILTER uses `TIER_MIN_RR = { 1: 1.5, 2: 2.0, 3: 2.5 }`. HARD FILTERS ENFORCER independently re-checks R/R with the same values embedded inline: `{ 1: 1.5, 2: 2.0, 3: 2.5 }`. The values are consistent between the two nodes, so no signals are double-rejected by different thresholds. However, both nodes independently apply the same R/R threshold, meaning the Hard Filters Enforcer R/R check is redundant — it can only reject signals that should have already been rejected by RISK-REWARD FILTER. The redundancy is acceptable as a defense-in-depth pattern, but the thresholds are hardcoded in two places. If one is updated, the other must be updated manually.

**Risk:** P2 — Maintenance risk only. No current signal impact.

**QA Note:** If TIER_MIN_RR is ever changed in RISK-REWARD FILTER, the corresponding inline literal in HARD FILTERS ENFORCER must also be updated. Consider centralizing threshold configuration.

---

### [R-05] GROUP CANDLE RESPONSES — symbol identity relies on positional ordering preserved by N8N
**File:** `row1/GROUP CANDLE RESPONSES` — SHA 4aa3c65c (CHANGED)

**Problem:**
The implementation relies on N8N preserving item order through the Filter nodes and HTTP request nodes. The comment states: "Symbol identity is derived from the Filter node order (= Bulk Requests Generator order), which N8N preserves when processing items sequentially." When `splitOn = true`, symbol i's candles are retrieved by `resp.slice(i * limit, (i + 1) * limit)`. This is a positional assumption: if any HTTP node reorders, skips, or retries a request (e.g. due to rate limiting on one symbol but not others), `resp[i]` no longer corresponds to `meta[i]`.

The interval-gap validation (`EXPECTED_GAP_MS` check) and candle count validation provide some protection: if a mismatch occurs, it is logged as an error. However, the pipeline continues rather than throwing — `errors++` is incremented but the corrupted candle data is still written to `candleMap` with the wrong symbol.

**Plan vs Implementation:** A-03 Option A is implemented as described. The architectural risk of positional matching was inherent in the design and is not a regression introduced by this fix. The timestamp gap validation and count validation are mitigating controls.

**Risk:** P1 — If N8N's HTTP node retries one symbol's request (common with 429 rate-limit responses from Binance), the retry inserts an extra item, shifting all subsequent `resp[i]` mappings by one. All subsequent symbols receive wrong candle data. The error counter increments but the pipeline does not abort. All downstream scores for those symbols are computed from the wrong candles.

**QA Note:** Add a symbol-field extraction from the HTTP response URL or headers if Binance echoes the symbol in the response, to allow symbol-identity verification independent of position.

---

### [R-06] VOLATILITY SCORE CALCULATOR1 — default tier fallback is 2 (CORRECT per plan)
**File:** `row3/Volatility Score Calculator1` — SHA 3f31fc52 (CHANGED)

**Problem:** None found. The implementation uses `parseInt(data.tier || 2)` — default is Tier 2. The `BBW_THRESHOLDS` table has Tier 1 optimal ≤ 0.015, Tier 2 optimal ≤ 0.040, Tier 3 optimal ≤ 0.060. All three values match the plan. The fallback `BBW_THRESHOLDS[tier] || BBW_THRESHOLDS[2]` also defaults to Tier 2. This finding is PASS.

**QA Note:** No issues. T-10 implemented correctly.

---

### [R-07] DEBUG + DE-DUPLICATION — median_volume_1h, median_volume_2h, and latest_1m_price included (CORRECT)
**File:** `row2/DEBUG + DE-DUPLICATION` — SHA 0a7c2ac5 (CHANGED)

**Problem:** None found. The `validCandles.push` block explicitly includes `median_volume_1h: candle.median_volume_1h || 0`, `median_volume_2h: candle.median_volume_2h || 0`, and `latest_1m_price: candle.latest_1m_price || null`. A-04 fix is correctly applied.

**QA Note:** Note that `latest_1m_price` defaults to `null` (not `0`) when absent. Downstream consumers must handle null. `median_volume_1h` and `median_volume_2h` default to `0`, which is appropriate.

---

### [R-08] Candles Grouping — interval filter `=== '2h'` present (CORRECT)
**File:** `row2/Candles Grouping & Latest 20 per Symbol` — SHA 11229fe9 (CHANGED)

**Problem:** None found. The file opens with `const only2h = allCandles.filter(item => item.json.interval === '2h')` before grouping, and includes a CRITICAL error return if no 2h candles are found. A-05 fix is correctly applied.

**QA Note:** No issues.

---

### [R-09] SIGNAL RANKING — Tier3 threshold logic, allAreTier3 exception, portfolio_risk_warning (CORRECT)
**File:** `row4/SIGNAL RANKING & TOP 5 SELECTION` — SHA 03b22715 (CHANGED)

**Problem:** None found. The implementation:
- Uses `TIER3_ABSOLUTE_FLOOR = 50` when no signals are yet selected (matching plan: "50 for absolute")
- Uses `avgSelected - 15` as relative threshold when signals already selected (matching plan: "avg(selected) - 15")
- Correctly detects `allAreTier3` and bypasses the relative threshold when every candidate is Tier 3
- Sets `portfolio_risk_warning: allAreTier3 ? 'ALL_TIER3_ELEVATED_RISK' : null` on all selected signals

T-09 is correctly implemented.

**QA Note:** No issues. One observation: `TIER3_ABSOLUTE_FLOOR = 50` is the minimum floor from Hard Filters Enforcer (Tier 3, ranging market). There is no scenario where the absolute floor in SIGNAL RANKING is more restrictive than Hard Filters Enforcer — signals reaching SIGNAL RANKING already have `total_score >= 50`. The absolute floor here is therefore a no-op. This is not a bug but reduces the effectiveness of the guard.

---

### [R-10] SCORE AGGREGATOR — volatility_score double-source conflict
**File:** `row3/SCORE AGGREGATOR` — SHA bfc2fe5f (UNCHANGED)

**Problem:**
SCORE AGGREGATOR reads `volatility_score` from `data.volatility_score`. This value arrives via the Merge node from `input3.volatility_score`. As established in T-08 findings, this field is potentially sourced from ATR Volatility Analyzer2 (simplified 4-level table, no BBW component) rather than Volatility Score Calculator1 (tier-aware ATR + BBW). SCORE AGGREGATOR has no guard or audit field indicating which source produced the `volatility_score` value it consumes. The `score_breakdown` output does not include a `volatility_score_source` field.

**Risk:** P1 — No observability into which volatility scorer actually contributed to `total_score`. When debugging a mis-scored signal, it is impossible to determine from SCORE AGGREGATOR's output whether `volatility_score: 75` came from the simplified ATR scorer or the full BBW-aware scorer.

**QA Note:** This is a consequence of the unfixed T-08 issues. The volatility score consumed by SCORE AGGREGATOR is of uncertain provenance in every production run.

---

## 4. PRIORITY SUMMARY

| Priority | ID | Issue | Risk |
|----------|-----|-------|------|
| P0 | T-04 | TREND SCORE CALCULATOR: MACD contribution never added to totalScore; EMA block nested in MACD block; histogramPct undefined → ReferenceError crash | P0 |
| P0 | R-01 | ReferenceError crash on any symbol with macd_value_2h === 0 (from T-04 non-fix) | P0 |
| P1 | T-02 | SCORE AGGREGATOR: getMomentumCorrectionMultiplier() absent — SHORT signals with high momentum over-scored by up to 12 points | P1 |
| P1 | T-03 | SCORE AGGREGATOR: getVolumeCorrectionMultiplier() absent — SHORT signals on high-OBV assets over-scored | P1 |
| P1 | T-06 | Price Action Score Calculator: close_price used for VWAP distance instead of latest_1m_price — up to 30pt score error for volatile assets | P1 |
| P1 | T-08 | ATR Volatility Analyzer2: volatility_score not removed — BBW-aware score from Volatility Score Calculator1 may be silently discarded | P1 |
| P1 | T-08 | Restore Full Data After Tier Insert: volatility_score propagated from tierData (Supabase) — re-injects simplified ATR-only score into pipeline | P1 |
| P1 | A-10 | SCORE AGGREGATOR + Merge: WEIGHTS_MISSING sentinel absent — upstream weight calculator failure produces no alert, signals proceed with fallback weights | P1 |
| P1 | A-09 | ASSET TIER CALCULATOR: tier boundaries (1–10/11–40/41–150) inconsistent with Execution Plan (1–5/6–15/16–20) — all downstream tier-dependent parameters affected | P1 |
| P1 | R-05 | GROUP CANDLE RESPONSES: positional symbol matching — HTTP retry or reorder maps wrong candles to wrong symbol silently | P1 |
| P1 | R-10 | SCORE AGGREGATOR: volatility_score provenance unknown — no audit trail for which scorer produced the consumed value | P1 |
| P1 | A-07 | Cooldown after Batch 6: setTimeout NOT removed — async Promise anti-pattern in N8N Code node; triggers on batchIndex=0 if context unavailable | P1 |
| P2 | R-02 | HARD FILTERS ENFORCER: rrFilterPassed extracted but unused — dead code, maintenance risk | P2 |
| P2 | R-03 | TP-SL CALCULATOR: misleading comment on WEAK_RANGING allocation — implementation is correct | P2 |
| P2 | R-04 | RISK-REWARD FILTER + HARD FILTERS ENFORCER: identical R/R thresholds hardcoded in two nodes independently | P2 |

---

*Report covers commit bd7b902 (all files read directly from GitHub repo mp3nchev/crypto_ai at SHA bd7b902344194de35ca44ca5e976633b2098546a). All findings are based on actual file content. SHA comparison confirms which files were and were not modified relative to 2eb9fc9.*
