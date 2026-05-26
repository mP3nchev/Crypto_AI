# rules.md — Constraints and Safety

Hard rules grounded in the specific audit findings of this system.
Every NEVER and ALWAYS maps to a real failure mode found in mp3nchev/crypto_ai.

---

## NEVER

**NEVER change tier boundaries without running `/impact-analysis` first.**
Tier boundaries in `row3/ASSET TIER CALCULATOR` feed SL_MULTIPLIERS, TIER_MAX_LEVERAGE,
TIER_MIN_RR, targetRiskPct, score floors, and BBW thresholds in 4 downstream nodes.
A single boundary change silently recalibrates risk parameters for all 20 symbols.
Basis: A-09 audit finding — wrong boundaries caused Tier 3 to be unreachable, resulting
in rank 16-20 altcoins receiving 7x leverage instead of 5x, 2.0×ATR SL instead of 2.5×ATR.

**NEVER change `TIER_MIN_RR` in one node without syncing the other.**
The object `{1: 1.5, 2: 2.0, 3: 2.5}` exists independently in both
`row4/RISK-REWARD FILTER` and `row4/HARD FILTERS ENFORCER`.
N8N Code nodes have no shared state — there is no automatic sync.
Basis: R-04 audit finding. SYNC REQUIRED comments added in PR #6. Always update both.

**NEVER modify the Merge SQL node without verifying all 5 branch input field names.**
The SQL uses `input1.field_name` through `input5.field_name`. A renamed output field
in any scoring branch (ADX, Momentum, Volatility, Trend, Volume/Price Action) silently
becomes NULL in the merged row. NULL propagates through SCORE AGGREGATOR as 0 via
`safeFloat()`, distorting all downstream scores without any error.
Basis: A-10 audit finding (WEIGHTS_MISSING), D-01 (macd_histogram_1h missing from SELECT).

**NEVER assume `volatility_score` is output by `row3/ATR Volatility Analyzer2`.**
T-08 fix removed `volatility_score` from that node's output. The SOLE authoritative
producer is `row3/Volatility Score Calculator1` (Scoring Branch 3).
If a change reintroduces `volatility_score` to ATR Volatility Analyzer2, it creates
a non-deterministic race condition with Branch 3 via the Merge node.

**NEVER change `TRADING_FEES` constants in `row4/TP-SL CALCULATOR` without
recalculating all R/R thresholds in RISK-REWARD FILTER and HARD FILTERS ENFORCER.**
Fee-adjusted R/R flows directly into tier pass/fail decisions. A fee change with
unchanged thresholds silently degrades signal quality.

**NEVER run `/upgrade` before `/impact-analysis` confirms safety.**
Basis: every P1 finding in this system had at least 3 downstream modules affected.

**NEVER perform a full repo scan after `/init` is complete.**
SYSTEM_MEMORY.md eliminates the need. Full scans are expensive and bypass the
minimal-file-access discipline that prevents context pollution.

**NEVER generate, log, or suggest TAAPI API key material.**
The old hardcoded TAAPI key already exists in git history (P0 outstanding action).
Basis: identified as security risk in OUTSTANDING ACTIONS section of audit report.

**NEVER assume `scan_cycle_id` is present without checking.**
`row2/Separation of Requests` throws if `scan_cycle_id` is missing (A-02 fix).
Any upstream change that drops `scan_cycle_id` from the data flow will cause a hard
failure at Row 2. Always trace `scan_cycle_id` propagation in upgrade proposals.

**NEVER modify N8N Wait node durations in `row2/Cooldown after Batch 6` code.**
The Code node is a passthrough. Duration is set in the N8N native Wait node (UI-only).
A-07 is still open — the Wait node has not been added to the workflow yet.

**NEVER propose adding indicators to the TAAPI bulk request without verifying:**
1. The TAAPI subscription plan supports the indicator.
2. The indicator is added to the Merge SQL SELECT.
3. `safeFloat()` handling is added in the consuming calculator node.
Basis: D-01 — `macd_histogram_1h` was referenced in TREND SCORE CALCULATOR but
never added to the TAAPI request or Merge SELECT, causing systematic SHORT bias.

---

## ALWAYS

**ALWAYS read `.claude/SYSTEM_MEMORY.md` before opening any file.**
The module index, dependency graph, and hot files are pre-computed. Use them.

**ALWAYS name the exact files you are about to read before reading them.**
Example: "I am reading `row3/SCORE AGGREGATOR` because it is the primary consumer
of `weights` from `Adaptive Weights Calculator1` and the symptom involves scoring."

**ALWAYS state a confidence score on every diagnostic output.**
Format: `confidence: [0-100]%` with brief justification.
Low confidence (<70%) must include a list of what additional evidence would raise it.

**ALWAYS flag if SYSTEM_MEMORY.md timestamp is older than 7 days.**
Emit `MEMORY_STALE` and recommend `/refresh-memory` before proceeding.

**ALWAYS check OPEN ISSUES before proposing a fix.**
The fix may already be documented in `CRYPTO_SIGNAL_SYSTEM_FIX_PLAN.md` with
edge cases and a preferred solution. Do not re-derive what is already known.

**ALWAYS include rollback strategy in any upgrade proposal.**
This system runs live signals. A broken deployment has immediate financial consequences.

**ALWAYS verify `rr_filter_passed` is NOT used in control flow in HARD FILTERS ENFORCER.**
R-02 fix removed the variable in PR #6, but future changes to that node may re-introduce
a similar dead variable pattern. The actual R/R gate uses `tpsl_calculated` and
`feeAdjustedRR` directly — upstream `rr_filter_passed` is intentionally ignored.

**ALWAYS note the `slDistancePct` edge case when proposing changes to TP-SL CALCULATOR.**
P-01 is open: there is no minimum `slDistancePct` floor. Any change that affects
ATR usage or SL calculation must account for the near-zero ATR edge case.

---

## QUALITY GATE

Runs automatically after every command. If any check = false → regenerate internally
→ do not return result to user.

```
dependency_chain_verified:
  check: every module mentioned in the output appears in SYSTEM_MEMORY.md MODULE INDEX
  fail_action: identify unknown module, add [REQUIRES_VERIFICATION] flag, re-run

minimal_file_access_confirmed:
  check: number of files opened (excluding SYSTEM_MEMORY.md) ≤ 3
  fail_action: reduce to the 3 highest-relevance files, discard others

no_breaking_changes_introduced:
  check: proposed change does not alter output field names, field types, or
         remove fields that downstream modules depend on (per DEPENDENCY GRAPH)
  fail_action: revise proposal to be additive-only, or require /impact-analysis
```

---

## ERROR STATES

**`MEMORY_STALE`**
- Condition: `.claude/SYSTEM_MEMORY.md` is missing or `Last /init` timestamp > 7 days ago.
- Action: Emit warning. Ask user to confirm if they want to proceed with stale memory
  or run `/refresh-memory` first. Do not block — warn and continue if user confirms.

**`FILE_NOT_FOUND`**
- Condition: A file listed in SYSTEM_MEMORY.md MODULE INDEX does not exist on disk.
- Action: Flag the missing file with `[FILE_NOT_FOUND]`. Do not attempt to reconstruct.
  Suggest `/refresh-memory` to update the index. Continue with available files.

**`CIRCULAR_DEPENDENCY`**
- Condition: Tracing DEPENDENCY GRAPH produces a cycle (A → B → C → A).
- Action: Isolate the cycle. Mark all modules in the cycle as `unsafe` for the current
  session. Do not propose changes to any module in an identified cycle.
  Report the cycle path to the user.

**`UNSAFE_CHANGE`**
- Condition: A proposed change touches a HIGH risk module without prior `/impact-analysis`,
  OR changes `TIER_MIN_RR` in one node without the other,
  OR changes `TIER_BOUNDARIES` without full downstream audit.
- Action: Block the change. Emit the specific rule being violated. Provide the exact
  `/impact-analysis` command the user should run to unblock.

**`SYNC_VIOLATION`**
- Condition: A proposed change modifies `TIER_MIN_RR` in `row4/RISK-REWARD FILTER`
  or `row4/HARD FILTERS ENFORCER` without including the identical change in the other node.
- Action: Refuse the partial change. Output both nodes' current values and the required
  synchronized change. Cite R-04 audit finding.
