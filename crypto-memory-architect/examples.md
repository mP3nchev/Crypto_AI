# examples.md — Execution Traces

Full execution traces using real scenarios from the audit documents and correspondence
of this session. All module names, file paths, and failure descriptions are from actual findings.

---

## Example 1: /debug — Systematic SHORT Bias in Signal Direction

**Scenario:** User reports that over 2 weeks of demo trading, SHORT signals appear
to score consistently higher than LONG signals with similar market setups. The bias
seems to be in the trend component.

---

**User input:**
```
/debug SHORT signals score higher than LONG signals even in trending bullish markets.
Trend score is systematically lower for LONG direction.
```

**Memory lookup:**
SYSTEM_MEMORY.md returns:

```
KNOWN FAILURE ZONES:
TREND SCORE CALCULATOR:
  findings: T-04 (3 structural bugs — FIXED v4.0), D-01 (macd_histogram_1h always null → SHORT bias — OPEN P1)
  open_issues: D-01

Merge (SQL node):
  findings: A-10 (COALESCE sentinels — FIXED), D-01 (macd_histogram_1h missing from SELECT — OPEN P1)
  open_issues: D-01

HOT FILES:
4.  row3/TREND SCORE CALCULATOR — 2 audit findings (T-04, D-01)
6.  row3/Merge               — 2 audit findings (A-10 SQL, D-01)

OPEN ISSUES:
D-01 | P1 | macd_histogram_1h never in Merge SELECT → SHORT bias in trend score
     | row3/TREND SCORE CALCULATOR, row3/Merge
```

**Hypothesis formed from memory (before opening any files):**
D-01 is an open P1 issue directly matching the described symptom. The mechanism is:
`macd_histogram_1h` is absent from `row3/Merge` SQL SELECT → TREND SCORE CALCULATOR
reads `safeFloat(null) = 0` → `macd_bullish_1h = false` always → when 2h MACD is
bullish (`macd_bullish_2h = true`), alignment check fails → LONG signals score +5
instead of +15 in MACD component. SHORT signals always get +15 (false alignment).

**Files accessed:**
1. `row3/TREND SCORE CALCULATOR` — to confirm `safeFloat(scanData.macd_histogram_1h)` usage
2. `row3/Merge` — to confirm `macd_histogram_1h` is absent from SQL SELECT

(2 files, within the ≤3 limit)

**Verification from files:**

In `row3/TREND SCORE CALCULATOR`:
```javascript
const macd_histogram_1h = safeFloat(scanData.macd_histogram_1h);
// safeFloat returns 0 for null/undefined
const macd_bullish_1h = macd_histogram_1h > 0;  // always false when null
```

In `row3/Merge` SQL: scanning all `input*.macd_*` fields —
`macd_value_2h`, `macd_signal_2h`, `macd_histogram_2h` are present.
`macd_histogram_1h` is NOT in the SELECT.

**Quality gate:**
```
dependency_chain_verified: true
  — Merge → TREND SCORE CALCULATOR chain confirmed in DEPENDENCY GRAPH
minimal_file_access_confirmed: true
  — 2 files opened, both justified
no_breaking_changes_introduced: true
  — diagnostic only, no changes proposed yet
```

**Output (DebugOutput schema):**
```json
{
  "command": "/debug",
  "description": "SHORT signals score higher than LONG signals even in trending bullish markets",
  "confidence": 97,
  "memory_age_days": 0,
  "memory_stale": false,
  "hypothesis": {
    "primary_suspect_module": "TREND SCORE CALCULATOR",
    "primary_suspect_file": "row3/TREND SCORE CALCULATOR",
    "hypothesis_basis": "KNOWN_FAILURE_ZONE",
    "known_issue_id": "D-01"
  },
  "files_accessed": [
    {
      "path": "row3/TREND SCORE CALCULATOR",
      "reason": "D-01 open issue — macd_histogram_1h null → SHORT bias",
      "relevant_section": "MACD alignment check block (lines ~100-130)"
    },
    {
      "path": "row3/Merge",
      "reason": "Confirm macd_histogram_1h absent from SQL SELECT",
      "relevant_section": "TAAPI INDICATORS (1h) section of SELECT"
    }
  ],
  "diagnosis": {
    "root_cause": "macd_histogram_1h is not in Merge SQL SELECT. TREND SCORE CALCULATOR reads it as null → safeFloat(null)=0 → macd_bullish_1h=false always. LONG signals (macd_bullish_2h=true) fail alignment check → +5 pts. SHORT signals (macd_bullish_2h=false) falsely pass alignment → +15 pts. Net directional bias: 10 MACD alignment points favoring SHORT.",
    "affected_dependency_chain": [
      "row3/Merge",
      "row3/TREND SCORE CALCULATOR",
      "row3/SCORE AGGREGATOR",
      "row4/HARD FILTERS ENFORCER",
      "Telegram output"
    ],
    "is_known_open_issue": true,
    "open_issue_id": "D-01",
    "fix_already_documented": true
  },
  "proposed_fix": {
    "scope": "MULTI_FILE",
    "files_to_change": ["row3/Merge", "row3/TREND SCORE CALCULATOR"],
    "risk_level": "HIGH",
    "impact_analysis_required": true,
    "summary": "Option C (preferred per FIX_PLAN): add macd_histogram_1h to Merge SELECT from the branch that provides it, verify TAAPI bulk request includes 1h MACD. Option A (intermediate): guard safeFloat call with null check and use neutral +10 instead of +5 when data missing. Run /impact-analysis before proceeding."
  },
  "quality_gate": {
    "dependency_chain_verified": true,
    "minimal_file_access_confirmed": true,
    "no_breaking_changes_introduced": true
  }
}
```

---

## Example 2: /impact-analysis — Adding Funding Rate to the Pipeline

**Scenario:** User wants to implement F-01 (funding rate from CRYPTO_SIGNAL_SYSTEM_FIX_PLAN.md):
fetch Binance futures `/fapi/v1/premiumIndex`, factor funding cost into fee-adjusted R/R,
add contrarian signal multiplier in SCORE AGGREGATOR.

---

**User input:**
```
/impact-analysis add funding rate fetch from Binance futures API and integrate into TP-SL CALCULATOR fee-adjusted R/R calculation
```

**Memory lookup:**
SYSTEM_MEMORY.md returns dependency chain for `row4/TP-SL CALCULATOR`:

```
DEPENDENCY GRAPH:
VOLUME PENALTY APPLICATOR → TP-SL CALCULATOR [risk: HIGH]
TP-SL CALCULATOR → RISK-REWARD FILTER [risk: HIGH] [slDistancePct → leverage calc]
RISK-REWARD FILTER → ... → HARD FILTERS ENFORCER [risk: HIGH]
HARD FILTERS ENFORCER → SIGNAL RANKING [risk: MEDIUM]
SIGNAL RANKING → Loop Over Items → Telegram [risk: LOW]
SIGNAL RANKING → signals_log INSERT [risk: LOW]

KNOWN FAILURE ZONES:
TP-SL CALCULATOR: findings T-01, T-05, T-06, P-01 (min SL guard open)

CRYPTO FLOW MAP:
futures_endpoint: /fapi/v1/ (required for funding rate — F-01 open, not yet implemented)
TRADING_FEES: entry=0.00055, exit=0.00055, total=0.0011 (in TP-SL CALCULATOR)
```

**Files accessed:** None (SYSTEM_MEMORY.md sufficient for impact analysis)

**Dependency trace:**

New node required (Binance futures fetch) injects into the pipeline before or alongside
Row 1 symbol selection. This data then flows to TP-SL CALCULATOR.

| Module | Impact | Risk |
|--------|--------|------|
| New fetch node (Binance /fapi/v1/premiumIndex) | New node, no existing deps broken | LOW |
| row4/TP-SL CALCULATOR | `riskWithFees` calculation changes; `fee_adjusted_rr` output changes | HIGH |
| row4/RISK-REWARD FILTER | Receives changed `fee_adjusted_rr` → tier filter pass rates change | HIGH |
| row4/HARD FILTERS ENFORCER | `fee_adjusted_rr` vs TIER_MIN_RR check affected | HIGH |
| row4/SIGNAL RANKING & TOP 5 SELECTION | Sort order may shift as R/R values decrease | MEDIUM |
| row3/SCORE AGGREGATOR | If contrarian multiplier added → total_score changes | HIGH |
| Telegram output | Different signals may be selected / rejected | HIGH |
| row4/signals_log INSERT | New `funding_rate` field may need Supabase schema update | MEDIUM |

Affected HIGH-risk modules: TP-SL CALCULATOR, RISK-REWARD FILTER, HARD FILTERS ENFORCER, SCORE AGGREGATOR = 4 modules

stability_score = 1 − (4×3 + 2×2) / max_weighted = 1 − (16) / [sum of all weights]
→ stability_score ≈ 0.58 → HIGH_RISK classification

**Quality gate:**
```
dependency_chain_verified: true
  — traced from new fetch node through full output chain
minimal_file_access_confirmed: true
  — no additional files opened, SYSTEM_MEMORY.md sufficient
no_breaking_changes_introduced: true
  — analysis only, no code changes
```

**Output (ImpactAnalysisOutput schema):**
```json
{
  "command": "/impact-analysis",
  "change_description": "Add funding rate fetch from Binance futures API, integrate into TP-SL CALCULATOR fee-adjusted R/R",
  "primary_module": "TP-SL CALCULATOR",
  "primary_file": "row4/TP-SL CALCULATOR",
  "affected_modules": [
    {
      "module": "TP-SL CALCULATOR",
      "file": "row4/TP-SL CALCULATOR",
      "risk_level": "HIGH",
      "impact_mechanism": "riskWithFees calculation changes — fee_adjusted_rr output decreases by funding cost",
      "cascade_depth": 1
    },
    {
      "module": "RISK-REWARD FILTER",
      "file": "row4/RISK-REWARD FILTER",
      "risk_level": "HIGH",
      "impact_mechanism": "fee_adjusted_rr used for TIER_MIN_RR pass/fail — lower R/R increases rejection rate",
      "cascade_depth": 2
    },
    {
      "module": "HARD FILTERS ENFORCER",
      "file": "row4/HARD FILTERS ENFORCER",
      "risk_level": "HIGH",
      "impact_mechanism": "fee_adjusted_rr vs TIER_MIN_RR check — same impact as RISK-REWARD FILTER",
      "cascade_depth": 3
    },
    {
      "module": "SCORE AGGREGATOR",
      "file": "row3/SCORE AGGREGATOR",
      "risk_level": "HIGH",
      "impact_mechanism": "If contrarian multiplier added — total_score changes for all signals with high funding rate",
      "cascade_depth": 2
    },
    {
      "module": "SIGNAL RANKING & TOP 5 SELECTION",
      "file": "row4/SIGNAL RANKING & TOP 5 SELECTION",
      "risk_level": "MEDIUM",
      "impact_mechanism": "Sort order changes as fee_adjusted_rr values shift — different top-5 composition",
      "cascade_depth": 4
    }
  ],
  "stability_score": 0.58,
  "risk_classification": "HIGH_RISK",
  "cascade_patterns_triggered": [
    "Passthrough timeout cascade — new HTTP node must not block pipeline if Binance futures API is slow"
  ],
  "known_failure_zones_in_chain": [
    {
      "module": "TP-SL CALCULATOR",
      "open_issue_ids": ["P-01"],
      "interaction_risk": "P-01 (no min SL guard) interacts with funding cost — extremely tight SL + funding cost could push effective R/R to 0"
    }
  ],
  "files_to_verify": [
    "row4/TP-SL CALCULATOR",
    "row4/RISK-REWARD FILTER",
    "row4/HARD FILTERS ENFORCER",
    "row3/SCORE AGGREGATOR",
    "Supabase signals_log schema (if funding_rate column added)"
  ],
  "requires_user_confirmation": true,
  "recommendation": "PROCEED_WITH_CAUTION",
  "quality_gate": {
    "dependency_chain_verified": true,
    "minimal_file_access_confirmed": true,
    "no_breaking_changes_introduced": true
  }
}
```

---

## Example 3: /architecture-review — State of System Before Demo Test

**Scenario:** User asks for a current architecture review before starting the $10k demo test.

---

**User input:**
```
/architecture-review
```

**Memory lookup:** Full SYSTEM_MEMORY.md read. No additional files opened.

**Output (ArchitectureReviewOutput schema):**
```json
{
  "command": "/architecture-review",
  "memory_age_days": 1,
  "memory_stale": false,
  "open_issues": [
    { "id": "A-07", "priority": "P1", "description": "N8N Wait node not added — TAAPI batches run without cooldown", "affected_file": "N8N workflow UI" },
    { "id": "D-01", "priority": "P1", "description": "macd_histogram_1h null → systematic SHORT bias in trend score", "affected_file": "row3/TREND SCORE CALCULATOR" },
    { "id": "F-01", "priority": "P1", "description": "Funding rate not in R/R calculation (Perpetual Futures)", "affected_file": "row4/TP-SL CALCULATOR (new node needed)" },
    { "id": "T-03", "priority": "P2", "description": "OBV correction applies to full volume weight (~4pt overshoot)", "affected_file": "row3/SCORE AGGREGATOR" },
    { "id": "P-01", "priority": "P2", "description": "No minimum slDistancePct guard in TP-SL CALCULATOR", "affected_file": "row4/TP-SL CALCULATOR" },
    { "id": "T-08", "priority": "P2", "description": "avgVolScore log shows 0.0/100 every cycle", "affected_file": "row3/ATR Volatility Analyzer2" },
    { "id": "SEC",  "priority": "P0", "description": "Old TAAPI hardcoded key in git history — rotation required", "affected_file": "External (TAAPI dashboard)" }
  ],
  "hot_files_status": [
    { "rank": 1, "file": "row4/TP-SL CALCULATOR", "audit_finding_count": 4, "open_issues": ["P-01"], "current_risk": "HIGH" },
    { "rank": 2, "file": "row3/SCORE AGGREGATOR", "audit_finding_count": 3, "open_issues": ["T-03"], "current_risk": "HIGH" },
    { "rank": 3, "file": "row4/HARD FILTERS ENFORCER", "audit_finding_count": 3, "open_issues": [], "current_risk": "HIGH" },
    { "rank": 4, "file": "row3/TREND SCORE CALCULATOR", "audit_finding_count": 2, "open_issues": ["D-01"], "current_risk": "HIGH" },
    { "rank": 5, "file": "row3/Merge", "audit_finding_count": 2, "open_issues": ["D-01"], "current_risk": "HIGH" }
  ],
  "coupling_issues": [
    {
      "module": "ASSET TIER CALCULATOR",
      "depended_on_by_count": 6,
      "coupling_risk": "Single point of failure for all risk parameters: SL_MULTIPLIERS, TIER_MAX_LEVERAGE, TIER_MIN_RR, score floors, BBW thresholds. Wrong tier silently miscalibrates every downstream node."
    },
    {
      "module": "Merge (SQL node)",
      "depended_on_by_count": 5,
      "coupling_risk": "5 scoring branches converge here. Any missing field in SELECT silently propagates NULL through SCORE AGGREGATOR as 0. No error is raised. D-01 is the active instance of this failure mode."
    },
    {
      "module": "SCORE AGGREGATOR",
      "depended_on_by_count": 4,
      "coupling_risk": "total_score and signal_direction used by VOLUME PENALTY APPLICATOR, TP-SL CALCULATOR (trend_score), HARD FILTERS ENFORCER, and SIGNAL RANKING. A weight change here shifts pass rates system-wide."
    }
  ],
  "top_improvements": [
    {
      "rank": 1,
      "improvement": "Fix D-01: add macd_histogram_1h to Merge SQL SELECT (and TAAPI fetch if not present). Eliminates systematic SHORT bias — highest signal quality impact per effort.",
      "risk_reward": "HIGH_REWARD_LOW_RISK",
      "audit_basis": "D-01 — open P1, documented in FIX_PLAN.md with preferred Option C",
      "command_to_run": "/impact-analysis add macd_histogram_1h to Merge SQL and TAAPI bulk request"
    },
    {
      "rank": 2,
      "improvement": "Fix P-01: add minimum slDistancePct guard in TP-SL CALCULATOR. Prevents garbage signals from corrupted ATR data reaching Telegram.",
      "risk_reward": "HIGH_REWARD_LOW_RISK",
      "audit_basis": "P-01 — open P2, 3-line addition, no downstream contract change",
      "command_to_run": "/optimize row4/TP-SL CALCULATOR minimum SL distance guard"
    },
    {
      "rank": 3,
      "improvement": "Implement F-01: funding rate integration. Critical for accurate R/R on Perpetual Futures — current R/R shown in Telegram is overstated for high-funding periods.",
      "risk_reward": "HIGH_REWARD_HIGH_RISK",
      "audit_basis": "F-01 — open P1, requires new fetch node + 3 file changes",
      "command_to_run": "/impact-analysis add funding rate to TP-SL CALCULATOR R/R calculation"
    }
  ],
  "quality_gate": {
    "dependency_chain_verified": true,
    "minimal_file_access_confirmed": true,
    "no_breaking_changes_introduced": true
  }
}
```
