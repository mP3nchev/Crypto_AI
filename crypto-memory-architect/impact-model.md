# impact-model.md — Dependency and Risk Logic

Derived from actual dependency chains, audit findings, and code structure
of the mp3nchev/crypto_ai pipeline. No invented chains.

---

## Risk Propagation Rules

A change to module X affects module Y if:
1. Y reads from X's output fields (via `$input`, `$(nodeName)`, or SQL `input1.field`)
2. Y uses a constant (TIER_MIN_RR, TIER_BOUNDARIES, TRADING_FEES) that is
   duplicated from X
3. Y's logic branches on a flag that X sets (e.g., `tpsl_calculated`, `is_valid_entry`,
   `filter_status`, `rr_filter_passed`)

### Primary Cascade Tables

**Change to: `row3/ASSET TIER CALCULATOR` (tier boundaries)**
Directly affected downstream:
| Module | What changes | Risk |
|--------|-------------|------|
| row3/ATR Volatility Analyzer2 | `atr_threshold_low`, `atr_threshold_high` per tier | MEDIUM |
| row4/TP-SL CALCULATOR | `SL_MULTIPLIERS[tier]`, TP ratio selection | HIGH |
| row4/RISK-REWARD FILTER | `TIER_MIN_RR[tier]`, `TIER_MAX_LEVERAGE[tier]`, `targetRiskPct` | HIGH |
| row4/HARD FILTERS ENFORCER | `risk_reward.threshold` (TIER_MIN_RR), `tierBaseFloors` | HIGH |
| row3/SCORE AGGREGATOR | `adxStrength`-based floor depends on tier | MEDIUM |
| row3/Volatility Score Calculator1 | BBW thresholds are tier-aware (T-10 fix) | MEDIUM |
→ **Total affected: 6 modules. Cascade depth: 4 (tier → TP/SL → R/R filter → hard filter → ranking)**
→ **Classification: HIGH_RISK. Requires /impact-analysis before any change.**

**Change to: `row3/Merge` (SQL SELECT)**
Directly affected downstream:
| Module | What changes | Risk |
|--------|-------------|------|
| row3/SCORE AGGREGATOR | Any missing field → `safeFloat(null)` = 0 → silent score distortion | HIGH |
| row3/TREND SCORE CALCULATOR | macd_histogram_1h from Merge — currently null (D-01) | HIGH |
| All 5 scoring branches | Any COALESCE change affects which branch's value wins | MEDIUM |
→ **Classification: HIGH_RISK. Every new field added to Merge requires downstream verification.**

**Change to: `row3/SCORE AGGREGATOR` (weights, corrections)**
Directly affected downstream:
| Module | What changes | Risk |
|--------|-------------|------|
| row3/VOLUME PENALTY APPLICATOR | Receives `total_score` — penalty applied to it | MEDIUM |
| row4/TP-SL CALCULATOR | `trend_score` used for TP strategy selection | MEDIUM |
| row4/HARD FILTERS ENFORCER | `total_score` vs dynamic score floor | HIGH |
| row4/SIGNAL RANKING & TOP 5 SELECTION | Sort order and Tier3 threshold (avg − 15) | MEDIUM |
→ **Classification: HIGH_RISK. Score changes affect filter pass rates and Telegram output.**

**Change to: `row4/TP-SL CALCULATOR` (SL formula, TP ratios, fees)**
Directly affected downstream:
| Module | What changes | Risk |
|--------|-------------|------|
| row4/RISK-REWARD FILTER | `fee_adjusted_rr`, `sl_distance_pct` — both used for filter + leverage | HIGH |
| row4/HARD FILTERS ENFORCER | `fee_adjusted_rr` vs TIER_MIN_RR | HIGH |
| Telegram signal | entry_price, stop_loss, take_profit_1/2/3 displayed to users | HIGH |
| row4/signals_log INSERT | All TP/SL fields stored for analysis | LOW |
→ **Classification: HIGH_RISK. Incorrect TP/SL reaches users with financial consequences.**

**Change to: `row1/GROUP CANDLE RESPONSES` (candle mapping)**
Directly affected downstream:
| Module | What changes | Risk |
|--------|-------------|------|
| row1/BINANCE CANDLE PROCESSOR | Receives candle arrays — wrong candles = wrong OHLCV | HIGH |
| row2/[all TAAPI nodes] | Indicator calculations based on candle data | HIGH |
| row3/[all scoring nodes] | RSI, MACD, ATR, EMA derived from wrong candles | HIGH |
→ **Classification: HIGH_RISK. Candle corruption silently propagates through all indicators.**
→ **R-05 fix (PR #6) added `symbolValid` guard. Any revert cascades to full pipeline.**

**Change to: `row2/Separation of Requests` (batch logic, scan_cycle_id)**
Directly affected downstream:
| Module | What changes | Risk |
|--------|-------------|------|
| All Row 2 → Row 4 nodes | scan_cycle_id missing → hard throw at Separation of Requests | HIGH |
| row3/ASSET TIER CALCULATOR | Receives batched indicator data | HIGH |
→ **Classification: HIGH_RISK. scan_cycle_id is structural — its absence aborts the pipeline.**

**Change to: `row3/TREND SCORE CALCULATOR` (scoring logic)**
Directly affected downstream:
| Module | What changes | Risk |
|--------|-------------|------|
| row3/Merge | `trend_score`, `trend_direction`, `trend_components` | MEDIUM |
| row3/SCORE AGGREGATOR | `trendScore` weighted contribution | MEDIUM |
| row3/SCORE AGGREGATOR | `signal_direction` = `trend_direction` — gates T-02 and T-03 corrections | HIGH |
→ **Classification: HIGH_RISK when direction logic is touched. D-01 open issue: macd_histogram_1h null creates SHORT bias.**

**Change to: `row4/RISK-REWARD FILTER` OR `row4/HARD FILTERS ENFORCER` (TIER_MIN_RR)**
Requires: simultaneous update to BOTH nodes.
Basis: R-04 audit finding. SYNC REQUIRED comments added in PR #6.
→ **Any single-node change triggers `SYNC_VIOLATION` error state.**

---

## Cascade Failure Thresholds

| Depth | Classification | Action Required |
|-------|---------------|-----------------|
| 1 module affected | LOW | No pre-check needed |
| 2 modules affected | MEDIUM | State affected modules in output |
| 3+ modules affected | HIGH | /impact-analysis required before change |
| Contains Telegram output | HIGH (always) | /impact-analysis required |
| Contains Supabase schema change | HIGH (always) | /upgrade required with rollback plan |

**N8N-specific constraint:** N8N Cloud Code nodes have a **10-second execution timeout**.
Any change that introduces synchronous delays (setTimeout, large loops, heavy computation)
will silently fail. The A-07 setTimeout failure is the canonical example of this constraint.

---

## Stability Scoring Formula

```
stability_score = 1 - (Σ(weight_i × affected_i) / total_modules)

where:
  total_modules = 23  (from MODULE INDEX)
  affected_i    = 1 if module i is in the change's downstream chain, else 0
  weight_i      = risk_level_weight of module i

risk_level_weight:
  HIGH   = 3
  MEDIUM = 2
  LOW    = 1

weighted_total = Σ(weight_i × affected_i)
max_weighted   = Σ(weight_i) for all modules = [calculate from MODULE INDEX]

stability_score = 1 - (weighted_total / max_weighted)
```

**Thresholds:**
- `stability_score ≥ 0.8` → LOW_RISK — proceed with standard caution
- `0.6 ≤ stability_score < 0.8` → MEDIUM_RISK — require user confirmation
- `stability_score < 0.6` → HIGH_RISK — block, require `/impact-analysis` sign-off

---

## Known Cascade Patterns (from audit history)

**Pattern 1: Tier boundary cascade** (A-09 — seen in audit report)
Change: `ASSET TIER CALCULATOR` tier boundaries
Cascade: → `TP-SL CALCULATOR` (SL too tight for Tier 3) → `RISK-REWARD FILTER`
(leverage too high) → `HARD FILTERS ENFORCER` (wrong R/R floor) → Telegram
(signals with incorrect risk parameters reach users)
Mitigation: change boundaries + run full test cycle, verify tier distribution in
execution log shows expected 5/10/5 distribution.

**Pattern 2: SQL field omission cascade** (D-01 — identified in audit, open)
Change: new indicator added to TAAPI bulk request but not to Merge SQL SELECT
Cascade: → Merge output has NULL → SCORE AGGREGATOR reads NULL as 0 →
directional bias in scores → wrong signals → Telegram
Historical instance: `macd_histogram_1h` — never added to Merge SELECT,
causing systematic SHORT bias in TREND SCORE CALCULATOR (D-01, still open).
Mitigation: for every new TAAPI indicator, verify TAAPI fetch → Merge SQL → consuming node chain.

**Pattern 3: Passthrough timeout cascade** (A-07 — open)
Change: any synchronous delay code in a Code node
Cascade: N8N Cloud 10s timeout kills execution silently → node appears to complete
but returns empty/default output → downstream nodes receive null data → TAAPI
batches proceed without pause → 429 rate limit → partial indicator data → wrong scores
Mitigation: never use setTimeout in Code nodes. Use N8N native Wait nodes for delays.

**Pattern 4: Dead code confusion cascade** (R-02 — fixed PR #6)
Pattern: extracting a variable (rrFilterPassed) and logging it but not using it in control flow
Risk: future developer assumes the logged variable gates logic → modifies upstream to
set it differently → no effect on filtering → bug assumed fixed but is not
Mitigation: verify every extracted variable is used in a condition before PR approval.

**Pattern 5: Threshold divergence cascade** (R-04 — fixed PR #6)
Pattern: same threshold defined independently in two nodes
Risk: one node updated, other forgotten → confusing rejection patterns where a signal
passes RISK-REWARD FILTER but fails HARD FILTERS ENFORCER at the same threshold value
Mitigation: R-04 SYNC REQUIRED comments added. Always search for `TIER_MIN_RR` across all row4/ files before committing.
