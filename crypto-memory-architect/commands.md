# commands.md — Command Logic

Full behavioral specification for each command in the crypto-memory-architect skill.

---

## /init

**Purpose:** Read the full repo and all audit documents once. Write `.claude/SYSTEM_MEMORY.md`.
Must run before any other command in a new session.

**Trigger condition:** Run if `.claude/SYSTEM_MEMORY.md` is missing or older than 7 days.

**Steps:**
1. Read `workflow_node_sequence.md` for full pipeline order.
2. Read `CRYPTO_SIGNAL_SYSTEM_AUDIT_REPORT.md` for open issues and known failure zones.
3. Read `CRYPTO_SIGNAL_SYSTEM_FIX_PLAN.md` for detailed problem/solution context.
4. Read all files in `row1/`, `row2/`, `row3/`, `row4/` (full repo scan — only permitted here).
5. Populate all sections of SYSTEM_MEMORY.md per `memory.md` population rules.
6. Write to `.claude/SYSTEM_MEMORY.md` (create `.claude/` directory if needed).
7. Output `/init` schema (see `schema.md`).

**Constraints:**
- Full repo scan is ONLY permitted during `/init` and `/refresh-memory`.
- After `/init` completes, all other commands use SYSTEM_MEMORY.md as their primary reference.
- Do not re-run automatically. User must explicitly call `/refresh-memory` to update.

**Output schema:** `InitOutput` — see `schema.md`

---

## /debug [description]

**Purpose:** Diagnose a specific failure, unexpected output, or regression.
Minimal file access. Maximum 3 files.

**Steps:**
1. Read `.claude/SYSTEM_MEMORY.md`.
   - Check timestamp. If >7 days → emit `MEMORY_STALE` warning before proceeding.
2. Match `description` against KNOWN FAILURE ZONES and HOT FILES in memory.
   - If match found → identify the 1-3 most likely candidate files.
   - If no match → trace from the symptom description through the DEPENDENCY GRAPH.
3. State which files you will open and why (before opening them).
4. Open ≤3 files. Read only the sections relevant to the described failure.
5. Diagnose: identify root cause, affected dependency chain, and risk of fix.
6. Run Quality Gate.
7. Output `DebugOutput` schema.

**File selection heuristic (apply in order):**
- If symptom mentions a score → start with `row3/SCORE AGGREGATOR`
- If symptom mentions direction bias → start with `row3/TREND SCORE CALCULATOR`
- If symptom mentions wrong TP/SL → start with `row4/TP-SL CALCULATOR`
- If symptom mentions wrong tier or leverage → start with `row3/ASSET TIER CALCULATOR`
- If symptom mentions missing data or null → start with `row3/Merge`
- If symptom mentions all signals filtered → start with `row4/HARD FILTERS ENFORCER`
- If symptom mentions candle data → start with `row1/GROUP CANDLE RESPONSES`
- If symptom mentions TAAPI error or 429 → start with `row2/Cooldown after Batch 6`
- If symptom mentions no cycle ID → start with `row2/Separation of Requests`

**Output schema:** `DebugOutput` — see `schema.md`

---

## /root-cause [description]

**Purpose:** Trace backwards through the dependency chain from a known failure point
to identify the originating module.

**Steps:**
1. Read `.claude/SYSTEM_MEMORY.md`.
2. Identify the failure point module from `description`.
3. From DEPENDENCY GRAPH: walk backwards through all upstream dependencies.
4. Cross-reference KNOWN FAILURE ZONES for each upstream module.
5. Form a starting hypothesis from the known failure zone with highest match.
6. Open ≤3 files — prioritise the module where the root cause is hypothesized.
7. Confirm or refute hypothesis. If refuted, move one step further upstream.
8. Run Quality Gate.
9. Output `RootCauseOutput` schema.

**Key dependency chains to know (from this repo):**
- Wrong signal direction → trace: TREND SCORE CALCULATOR → Merge (macd_histogram_1h missing) → D-01
- Wrong score → trace: SCORE AGGREGATOR → Adaptive Weights Calculator1 (WEIGHTS_MISSING) → A-10
- Wrong leverage → trace: RISK-REWARD FILTER → ASSET TIER CALCULATOR (tier boundary) → A-09 (was)
- Silent data corruption → trace: TP-SL CALCULATOR ← candle data → GROUP CANDLE RESPONSES → R-05 (was)
- TAAPI 429 → trace: Cooldown after Batch 6 (passthrough) → A-07 (open)

**Output schema:** `RootCauseOutput` — see `schema.md`

---

## /optimize [target]

**Purpose:** Propose a minimal, targeted improvement to a specific module.

**Steps:**
1. Read `.claude/SYSTEM_MEMORY.md`.
2. Locate `target` in MODULE INDEX. Read its risk_level.
3. **BLOCK** if risk_level = `HIGH` and no `/impact-analysis` has been run for this target
   in the current session. Emit `UNSAFE_CHANGE` error. Instruct user to run
   `/impact-analysis [target optimization]` first.
4. If risk_level = `MEDIUM` or `LOW`, or impact analysis already done:
   - State the file you will open before opening it.
   - Open only the target module's primary file.
   - Propose the minimal change. No surrounding refactors. No new abstractions.
5. Run Quality Gate.
6. Output `OptimizeOutput` schema.

**Hard constraints:**
- Maximum 1 file opened (the target module).
- Proposed change must not touch dependency contracts (function signatures, output field names,
  output field types) without `/impact-analysis` confirming downstream safety.
- Changes to `TIER_MIN_RR` in either `RISK-REWARD FILTER` or `HARD FILTERS ENFORCER`
  require explicit mention of the R-04 SYNC REQUIRED obligation in the output.

**Output schema:** `OptimizeOutput` — see `schema.md`

---

## /upgrade [description]

**Purpose:** Propose a feature addition or architectural upgrade with rollback strategy.

**HARD BLOCK:** If `/impact-analysis` has not been run for this change in the current session,
emit `UNSAFE_CHANGE` and refuse to proceed.

**Steps:**
1. Read `.claude/SYSTEM_MEMORY.md`.
2. Identify all modules in the upgrade scope from DEPENDENCY GRAPH.
3. Verify `/impact-analysis` output exists for this change in session context.
4. Define rollback strategy BEFORE proposing the upgrade:
   - Which N8N nodes would be reverted.
   - Whether DB schema changes are involved (irreversible without migration).
   - Whether the change affects `scan_cycle_id` propagation.
5. Propose upgrade in minimal steps. Each step must be independently revertable.
6. For changes touching Supabase schema: flag that table migrations are one-way
   without explicit DOWN migration.
7. Run Quality Gate.
8. Output `UpgradeOutput` schema.

**Special cases:**
- Adding `macd_histogram_1h` to Merge SQL (D-01 fix): requires TAAPI bulk request
  verification first. Flag `[REQUIRES_VERIFICATION]` if TAAPI plan support is unknown.
- Adding funding rate fetch (F-01): requires new Binance Futures `/fapi/v1/premiumIndex`
  HTTP node + TP-SL CALCULATOR changes + HARD FILTERS ENFORCER changes. High cascade risk.
- Any change to `TIER_BOUNDARIES` in ASSET TIER CALCULATOR cascades to
  TP-SL CALCULATOR, RISK-REWARD FILTER, HARD FILTERS ENFORCER, SCORE AGGREGATOR.

**Output schema:** `UpgradeOutput` — see `schema.md`

---

## /impact-analysis [change description]

**Purpose:** Score the stability impact of a proposed change across the full dependency chain.
Required before `/upgrade` and any HIGH-risk `/optimize`.

**Steps:**
1. Read `.claude/SYSTEM_MEMORY.md`.
2. Identify the primary module affected by `change description`.
3. From DEPENDENCY GRAPH: trace ALL downstream modules affected by a change to the primary module.
4. For each affected module: read its risk_level from MODULE INDEX.
5. Calculate stability_score using the formula from `impact-model.md`.
6. Identify cascade failure risks from KNOWN FAILURE ZONES.
7. If stability_score < 0.6 → classify as HIGH_RISK. Require explicit user confirmation.
8. List every file that would need to be changed or verified.
9. Run Quality Gate.
10. Output `ImpactAnalysisOutput` schema.

**No files opened** beyond SYSTEM_MEMORY.md unless a specific module's code
must be read to determine exact impact. If a file must be opened, state it first.

**Output schema:** `ImpactAnalysisOutput` — see `schema.md`

---

## /architecture-review

**Purpose:** Summarize current system state vs known failure zones. Identify coupling issues.

**Steps:**
1. Read `.claude/SYSTEM_MEMORY.md` only (no additional files unless specific question requires).
2. Check timestamp. If >7 days → emit `MEMORY_STALE` before proceeding.
3. Summarize:
   - Open issues by priority (P0, P1, P2) from OPEN ISSUES section.
   - Hot files and their current risk status.
   - Dependency chains with high coupling (modules depended on by 3+ others).
4. Identify top 3 architectural improvements ranked by risk/reward ratio.
5. Cross-reference with FIX_PLAN.md findings if available.
6. Run Quality Gate.
7. Output `ArchitectureReviewOutput` schema.

**Output schema:** `ArchitectureReviewOutput` — see `schema.md`

---

## /refresh-memory

**Purpose:** Re-run `/init`. Overwrites SYSTEM_MEMORY.md.

**When to use:**
- After merging a PR that fixes open issues.
- After adding new nodes to the N8N workflow.
- After any Supabase schema changes.
- After SYSTEM_MEMORY.md is >7 days old.

**Steps:** Identical to `/init`. Overwrites existing `.claude/SYSTEM_MEMORY.md`.
Logs previous timestamp in a `## PREVIOUS /init` section before overwriting.

---

## /generate-skill

**Purpose:** Output a complete updated version of this skill package.

**Steps:**
1. Read `.claude/SYSTEM_MEMORY.md`.
2. Read current skill files in `crypto-memory-architect/`.
3. Update `SYSTEM_MEMORY.template.md` to reflect current open issues and module index.
4. Output all 9 files with updated content (including new `strategic-edge` additions).
5. Write updated files to `crypto-memory-architect/` directory.

---

## /strategic-edge [context?]

**Purpose:** Strategic profitability analysis of the signal pipeline.
Identifies where the system loses valid edge through over-filtering, confirmation stacking,
late-entry patterns, or regime-blind static thresholds. Produces minimal, testable
micro-adjustment proposals with full risk/reward asymmetry scoring.

**NOT a code-fix tool. NOT a feature-addition tool.**
This command answers: "Where is the system leaving profit on the table through policy, not bugs?"

**When to use:**
- Signal frequency feels too low (0–1 signals per cycle when 2–3 are expected)
- Entries are consistently after the move (price already extended > 5% from ideal entry)
- System performs unevenly across trending vs. ranging market conditions
- Before a demo or live deployment to surface hidden strategic weaknesses
- After resolving P1 open issues — to find the next layer of improvement

**Trigger phrases:** `too few signals`, `late entry`, `missed move`, `over-filtered`,
`filter too strict`, `signal frequency`, `profitability`, `missed trade`, `strategic edge`,
`why didn't we catch it early`, `improve expectancy`

---

**Steps:**

1. Read `.claude/SYSTEM_MEMORY.md`.
   - Check timestamp. If >7 days → emit `MEMORY_STALE` warning before proceeding.
   - Load: OPEN ISSUES (to avoid re-deriving documented bugs as strategic proposals),
     MODULE INDEX, DEPENDENCY GRAPH, KNOWN FAILURE ZONES (premortem basis).

2. **Premortem Failure Simulation.**
   Assume the system has produced low-quality or low-frequency signals for 30 consecutive days.
   Construct 3–5 specific failure scenarios grounded in this codebase's architecture:
   - For each scenario: identify the root mechanism, affected modules (from MODULE INDEX),
     `signal_loss_estimate` (LOW/MEDIUM/HIGH), `frequency_of_occurrence` (RARE/OCCASIONAL/FREQUENT).
   - Cross-reference each against OPEN ISSUES. If a scenario maps to a known issue
     (e.g., D-01 SHORT bias, A-07 missing batch cooldown), set `maps_to_open_issue` to
     the issue ID. Do NOT re-derive a fix for it — reference the FIX_PLAN entry instead.

3. **Opportunity Suppression Detection.**
   Scan the filter chain from memory (no file reads required):
   - **Scoring bottleneck:** SCORE AGGREGATOR → dynamic score floor in HARD FILTERS ENFORCER
   - **R/R bottleneck:** TP-SL CALCULATOR → RISK-REWARD FILTER (TIER_MIN_RR) → HARD FILTERS ENFORCER
   - **Selection bottleneck:** SIGNAL RANKING & TOP 5 SELECTION (Top-5 cap, Tier 3 avg−15 formula)
   - Identify near-miss patterns: signals rejected at ≤10% above a threshold value.
   - Classify each area:
     - `STRUCTURAL` → maps to an existing open issue ID → reference it, do not re-propose
     - `THRESHOLD_CALIBRATION` → correct implementation, suboptimal value → valid target
     - `TIMING` → confirmation lag (e.g., ADX lagging) → quantify, flag severity
     - `REGIME_BLINDNESS` → static parameter in dynamic market → valid target

4. **File reads (conditional).**
   - If `context` names a specific module → open at most 2 files directly relevant to it.
   - If no `context` provided → operate from SYSTEM_MEMORY.md only (0 additional files).
   - Before opening any file, state: which file, and which specific question it answers.

5. **Adaptive Micro-Adjustment Generation.**
   For each `THRESHOLD_CALIBRATION` or `REGIME_BLINDNESS` opportunity:
   - Propose ONE minimal change: a single parameter adjustment OR a single added condition.
   - **BLOCK and emit `STRATEGY_SCOPE_VIOLATION`** if the proposal:
     - requires a new data source, new TAAPI indicator, or new N8N node
     - touches more than 2 constants simultaneously
     - has `complexity_delta` = MODERATE or HIGH
     - If the idea has architectural merit → note: "Redirect to `/upgrade [description]`"
   - For each approved proposal, fill all R/R asymmetry fields:
     `impact_signal_frequency`, `impact_risk_exposure`, `profitability_gain_estimate`,
     `conditions_effective`, `conditions_fail`.
   - If the proposal touches `TIER_MIN_RR` in any node → flag R-04 SYNC REQUIRED.
     Route to `/upgrade` + `/impact-analysis` (never to `/optimize`).

6. **Run Quality Gate.**

7. **Output `StrategicEdgeOutput` schema.**

---

**File access rule:**

| Context provided | Max additional files |
|-----------------|----------------------|
| None (full pipeline review) | 0 |
| Specific module named | 1 |
| Module + downstream concern | 2 |

Most valuable reads (if file access is warranted):
- `row4/HARD FILTERS ENFORCER` — score floor logic, TIER_MIN_RR usage
- `row4/SIGNAL RANKING & TOP 5 SELECTION` — Tier 3 avg−15 formula, Top-5 cap
- `row3/SCORE AGGREGATOR` — weight composition, correction multipliers

---

**Relationship to other commands:**

| Command | Domain | Key question answered |
|---------|--------|----------------------|
| `/strategic-edge` | **Strategy / Policy** | Where is the system losing profitable trades? |
| `/optimize` | Code correctness | How do I fix this specific technical issue? |
| `/upgrade` | Feature addition | How do I add this new capability safely? |
| `/impact-analysis` | Risk quantification | How dangerous is this proposed change? |
| `/debug` | Failure diagnosis | Why did this specific thing break? |
| `/architecture-review` | Structural health | What is the current overall system state? |

**Execution flow:**
`/strategic-edge` generates proposals → each routes to `/optimize` (single-file, LOW/MEDIUM risk)
or `/upgrade` (multi-file, HIGH risk) → HIGH-risk proposals require `/impact-analysis` first.

---

**Hard constraints:**
- Minimum output: 3 premortem scenarios, 2 opportunity loss areas, ≥1 proposed adjustment.
- Each proposed adjustment must be immediately actionable via a named command (`/optimize` or `/upgrade`).
- Recommendation must be exactly one of: `IMPLEMENT` / `TEST_IN_SHADOW_MODE` / `REJECT`.
- Default is `TEST_IN_SHADOW_MODE` for any proposal that touches a threshold used in live signal filtering.
- `STRUCTURAL` opportunity loss areas (mapped to existing open issues) are listed as
  reference only — they are NOT re-proposed as new adjustments.

**Output schema:** `StrategicEdgeOutput` — see `schema.md`
