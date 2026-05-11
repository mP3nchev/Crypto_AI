# CRYPTO SIGNAL SYSTEM — AUDIT REPORT
## Revision: commit e5c4c51 vs Execution Plan v2
## Audit Date: 2026-05-11
## Coverage: All files changed in revision round (A-01, A-07, A-08, A-10, T-02, T-03, T-04, T-06, T-08) + regression check on prior round fixes

---

## 1. ARCHITECTURAL ISSUES

---

### [A-07] Cooldown after Batch 6 — Wait node pending manual N8N workflow edit
**File:** `row2/Cooldown after Batch 6` — SHA 057052b9 (CHANGED)
**Status: CODE FIX APPLIED — WORKFLOW ACTION REQUIRED**

**Problem:**
The `setTimeout`-based Promise has been removed. The node is now a clean passthrough with diagnostic logging. The code comment correctly documents where N8N native Wait nodes must be inserted: after `currentRunIndex === 6` (+30s) and after `currentRunIndex === 12` (+20s). This is an N8N workflow-level action that cannot be expressed in a Code node — it must be done manually in the N8N workflow editor.

**Risk:** P1 — Until the Wait nodes are added in the workflow editor, all TAAPI batches fire back-to-back with no rate-limit protection. The code fix alone does not restore the cooldown. A 429 from TAAPI batch 7+ will cause partial indicator data for that cycle.

**Explanation:**
The node correctly passes through `$input.all()` and logs batch position. `batchIndex` still reads from `$('Loop Over Items1').context.currentRunIndex || 0` — if the loop context is unavailable, the log shows batch 1 (harmless in passthrough mode).

**QA Note:** Confirm in N8N workflow editor that IF node + Wait node branching exists at batch 6 and 12. Check execution timeline for 30-second gap between batch 6 and 7 completions.

---

### [A-09] ASSET TIER CALCULATOR — Tier boundaries do not match Execution Plan
**File:** `row3/ASSET TIER CALCULATOR` — SHA 44036c67 (UNCHANGED — not in this revision)

**Problem:**
Not addressed in this revision round. Boundaries remain: Tier 1 = rank 1–10, Tier 2 = rank 11–40, Tier 3 = rank 41–150. Execution Plan specifies: Tier 1 = rank 1–5, Tier 2 = rank 6–15, Tier 3 = rank 16–20. With 20 active symbols, Tier 3 is never assigned.

**Risk:** P1 — All downstream tier-sensitive parameters remain misaligned: SL multiplier, leverage cap, targetRiskPct, R/R floor, BBW thresholds. Rank 16–20 altcoins receive Tier 2 parameters (SL 2.0×ATR, max 7x leverage, R/R floor 2.0) instead of Tier 3 (SL 2.5×ATR, max 5x, R/R floor 2.5).

**QA Note:** Confirm with product owner whether intended boundaries are plan-v2 (1-5/6-15/16-20) or the current wider config (1-10/11-40/41-150). Until confirmed, all rank-16–20 signals carry misaligned risk parameters.

---

### [A-10] SCORE AGGREGATOR + Merge — WEIGHTS_MISSING sentinel — RESOLVED
**Files:** `row3/SCORE AGGREGATOR` — SHA 8307f6ca (CHANGED); `row3/Merge` — SHA 35a6e913 (CHANGED)
**Status: CORRECTLY FIXED**

Merge SQL: `COALESCE(input1.market_condition, 'WEIGHTS_MISSING')` and `COALESCE(input1.weight_*, -1)` for all six weight fields confirmed present.
SCORE AGGREGATOR: `WEIGHTS_MISSING` sentinel check at Step 2 entry confirmed. `hasInvalidWeights` guard checks `w < 0` (catches -1 sentinel). `results.filter(Boolean)` at return confirmed.
Signal with failed ADX branch now produces a named error log and a clean exclusion — no silent fallback.

---

## 2. SIGNAL QUALITY ISSUES

---

### [T-04] TREND SCORE CALCULATOR — Three structural bugs — RESOLVED
**File:** `row3/TREND SCORE CALCULATOR` — SHA 7e1916d2 (CHANGED)
**Status: CORRECTLY FIXED**

All three bugs confirmed fixed:
- `histogramPct = 0` declared at function scope (line 6 of `calculateTrendScore`) — ReferenceError eliminated.
- `totalScore += macdContribution` is present inside the MACD block before its closing brace.
- EMA block is a fully independent conditional at the same nesting depth as MACD.
- Final score calculation and `return` are outside all component blocks.
- Calibration fields `trend_score_legacy` (ADX+EMA, pre-v4 baseline) and `trend_score_v4` (authoritative) added to `trend_components` for audit traceability.
- `trend_calculator_version: 'v4.0 (T-04 Fixed)'` confirms the correct version is running.

**Impact of fix:** MACD contribution (up to 30 raw points, tier-adjusted) now contributes to `trend_score`. Symbols that previously received inflated scores from the 40/40 = 100% calculation will now score more accurately. Expect average `trend_score` to change — calibration logging allows quantifying the delta.

---

### [T-02] SCORE AGGREGATOR — getMomentumCorrectionMultiplier() — RESOLVED
**File:** `row3/SCORE AGGREGATOR` — SHA 8307f6ca (CHANGED)
**Status: CORRECTLY FIXED**

`getMomentumCorrectionMultiplier(score, direction)` confirmed present with correct table:
SHORT ≥75 → 0.35, ≥60 → 0.55, ≥50 → 0.80, <50 → 1.00. LONG mirror logic applied.
Multiplier applied to `weightedMomentum` only (raw `momentum_score` preserved).
`momentum_correction_multiplier` added to `score_breakdown` for full audit trail.

---

### [T-03] SCORE AGGREGATOR — getVolumeCorrectionMultiplier() — RESOLVED
**File:** `row3/SCORE AGGREGATOR` — SHA 8307f6ca (CHANGED)
**Status: CORRECTLY FIXED**

`getVolumeCorrectionMultiplier(score, direction, obv)` confirmed present. SHORT with `obv_1h > 1,000,000` → 0.75; `obv_1h > 500,000` → 0.85. LONG mirror logic applied. Ceiling 0.75 preserved per spec (avoids over-penalizing direction-neutral volume metrics).
`volume_correction_multiplier` and `obv_1h_at_correction` in `score_breakdown` confirmed.

**Residual precision note:** Multiplier adjusts the full `weightedVolume` contribution, not just the OBV sub-component (30/100 of volume score). This is the accepted tradeoff from Option A — direction-neutral MFI and volume tier points are slightly penalized as a side effect. Score impact is bounded at `volumeScore × weight_volume × (1 - 0.75) = max ~4 points` at the ceiling.

---

### [T-06] Price Action Score Calculator — latest_1m_price for VWAP distance — RESOLVED
**File:** `row3/Price Action Score Calculator` — SHA ebf23ae2 (CHANGED)
**Status: CORRECTLY FIXED**

`price_for_vwap = (raw_1m > 0) ? raw_1m : close_price` confirmed. `priceSource` logged per symbol for audit. Components 2 (candle structure) and 3 (EMA20 positioning) continue using `close_price` — correct for OHLC-based analysis.

**TP-SL CALCULATOR** (SHA edecc059, CHANGED): 3% deviation guard confirmed. If `|latest_1m_price − close_price| / close_price > 0.03`, substitutes `close_price` with a `console.warn`. Below 3%, uses `latest_1m_price` as intended.

---

### [T-08] ATR Volatility Analyzer2 + Restore Full Data — Dual volatility_score — RESOLVED
**Files:** `row3/ATR Volatility Analyzer2` — SHA 05f4aba4 (CHANGED); `row3/Restore Full Data After Tier Insert` — SHA 08b93dc7 (CHANGED)
**Status: CORRECTLY FIXED**

ATR Volatility Analyzer2: Output object no longer includes `volatility_score`. Comment `[T-08] volatility_score intentionally NOT output here` confirmed. Node outputs: `volatility_status`, `atr_percentage_1h`, `volatility_warning`, `risk_level`, `max_suggested_leverage` — all metadata fields preserved.

Restore Full Data: `volatility_score` explicitly excluded from the merge object with comment `[T-08] volatility_score NOT propagated from tierData`. Chain is now deterministic: ATR Analyzer2 → Supabase stores no volatility_score → Restore does not inject it → Merge `input3.volatility_score` reads exclusively from Volatility Score Calculator1 (Branch 3).

**Minor diagnostic issue (no functional impact):** ATR Volatility Analyzer2 summary block still calculates `avgVolScore = reduce((sum, r) => sum + (r.json.volatility_score || 0))` — this will always log `0.0/100` because `volatility_score` is no longer in the output. Misleading log, correct behavior.

**Same minor issue** in Restore Full Data validation: `console.log(' - volatility_score: ${sampleRecord.volatility_score}')` will log `undefined`. Informational only.

---

## 3. REGRESSION FINDINGS (REVISION ROUND)

---

### [R-01] TREND SCORE CALCULATOR — ReferenceError crash — RESOLVED
**Status: RESOLVED by T-04 fix**

`histogramPct` is now declared with `let histogramPct = 0` at function scope before all component blocks. Any symbol with `macd_value_2h === 0 AND macd_signal_2h === 0` no longer causes a ReferenceError. The MACD block is skipped cleanly; `histogramPct` remains 0 in the return object.

---

### [R-02] HARD FILTERS ENFORCER — rrFilterPassed extracted but unused
**File:** `row4/HARD FILTERS ENFORCER` — SHA 48227461 (unchanged from previous revision)

**Problem:**
`rrFilterPassed` is extracted from `data.rr_filter_passed` and included in `console.log` output, but does not appear in any control-flow condition. The actual filter check uses `tpsl_calculated === true && safeRR >= tierMin`. This is correct behavior — the T-07 fix was applied correctly in the previous round — but the extracted variable is dead code.

**Risk:** P2 — Maintenance risk only. Future developer may assume `rrFilterPassed` contributes to the filter decision.

**QA Note:** No functional impact. The filter logic is correct.

---

### [R-04] RISK-REWARD FILTER + HARD FILTERS ENFORCER — Duplicate R/R thresholds
**Files:** `row4/RISK-REWARD FILTER` (SHA 5077e707); `row4/HARD FILTERS ENFORCER` (SHA 48227461)

**Problem:**
`TIER_MIN_RR = { 1: 1.5, 2: 2.0, 3: 2.5 }` is hardcoded independently in both nodes. Values are currently identical, so no double-rejection mismatch exists. If either is updated without the other, signals can pass RISK-REWARD FILTER but fail HARD FILTERS ENFORCER (or vice versa), creating confusing rejection patterns.

**Risk:** P2 — Maintenance risk only. No current signal impact.

**QA Note:** Any future change to R/R tier floors must be applied to both nodes.

---

### [R-05] GROUP CANDLE RESPONSES — Positional symbol matching risk on HTTP retry
**File:** `row1/GROUP CANDLE RESPONSES` — SHA 4aa3c65c (unchanged from previous revision)

**Problem:**
A-03 Option A is implemented: 4 separate HTTP nodes per interval ensure interval identity without positional matching. However, within each interval node, symbol identity is still resolved positionally — `resp.slice(i * limit, (i + 1) * limit)` maps response items to symbols by array index. If Binance rate-limits one symbol and N8N retries that request, the retry response inserts an extra item, shifting all subsequent symbol-to-candle mappings. The error counter increments but the pipeline continues with corrupted candle data for the affected symbols.

**Risk:** P1 — Silent data corruption on HTTP retry. Timestamp-gap and candle-count validation provide partial protection but do not prevent corrupted data from propagating when the mismatch is subtle (e.g., adjacent symbols with similar candle patterns).

**QA Note:** Inject a forced retry for one symbol during testing and verify that no adjacent symbol receives misrouted candle data.

---

### [R-10] SCORE AGGREGATOR — volatility_score provenance — RESOLVED
**Status: RESOLVED by T-08 fix**

With T-08 applied, `volatility_score` in Merge output comes exclusively from `input3.volatility_score` (Volatility Score Calculator1, Branch 3). The non-deterministic race between two producers no longer exists.

---

## 4. PRIORITY SUMMARY

| Priority | ID | Issue | Risk | Status |
|----------|-----|-------|------|--------|
| P0 | T-04 | TREND SCORE CALCULATOR: MACD+EMA structural bugs + ReferenceError crash | P0 | RESOLVED |
| P0 | R-01 | ReferenceError on macd_value_2h === 0 | P0 | RESOLVED |
| P1 | A-07 | Cooldown after Batch 6: Wait node required in N8N workflow editor | P1 | CODE FIXED — N8N ACTION PENDING |
| P1 | A-09 | ASSET TIER CALCULATOR: tier boundaries 1-10/11-40/41-150 vs plan 1-5/6-15/16-20 | P1 | OPEN — not in this revision |
| P1 | R-05 | GROUP CANDLE RESPONSES: positional symbol matching on HTTP retry | P1 | OPEN |
| P1 | T-02 | SCORE AGGREGATOR: getMomentumCorrectionMultiplier absent — SHORT over-scored | P1 | RESOLVED |
| P1 | T-03 | SCORE AGGREGATOR: getVolumeCorrectionMultiplier absent — OBV direction-blind | P1 | RESOLVED |
| P1 | T-06 | Price Action: close_price for VWAP distance; TP-SL: no deviation guard | P1 | RESOLVED |
| P1 | T-08 | Dual volatility_score — non-deterministic provenance | P1 | RESOLVED |
| P1 | A-10 | WEIGHTS_MISSING sentinel absent — silent fallback weights on upstream failure | P1 | RESOLVED |
| P2 | R-02 | HARD FILTERS ENFORCER: rrFilterPassed dead variable | P2 | OPEN |
| P2 | R-04 | Duplicate R/R thresholds in RISK-REWARD FILTER and HARD FILTERS ENFORCER | P2 | OPEN |
| P2 | A-01 | TAAPI secret key hardcoded | P2 | RESOLVED |
| P2 | A-08 | Duplicate Binance validation calls (36 candles → 1) | P2 | RESOLVED |
| P2 | R-10 | volatility_score provenance unknown | P2 | RESOLVED |
| P2 | R-03 | TP-SL CALCULATOR misleading WEAK_RANGING comment | P2 | INFORMATIONAL |

---

## 5. OUTSTANDING ACTIONS (non-code)

| Action | Owner | Priority |
|--------|-------|----------|
| Add IF + Wait nodes in N8N workflow editor for TAAPI batch cooldown (A-07) | N8N workflow | P1 |
| Confirm intended tier boundaries with product owner and apply A-09 fix | Code + config | P1 |
| Rotate TAAPI secret key — old hardcoded key may still be active in git history | Infrastructure | P0 |

---

*Report covers commit e5c4c51 (main branch). All file contents read directly from GitHub repo mp3nchev/crypto_ai at refs/heads/main. SHA verification confirms which files were modified relative to bd7b902.*
