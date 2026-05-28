# schema.md — Output Schemas

Strict typed output schemas for every command.
Field names derived from actual codebase terminology (mp3nchev/crypto_ai).

---

## InitOutput

```typescript
interface InitOutput {
  command: "/init"
  status: "SUCCESS" | "PARTIAL" | "FAILED"
  memory_path: ".claude/SYSTEM_MEMORY.md"
  timestamp: string  // ISO-8601 UTC

  modules_indexed: number          // count from MODULE INDEX
  dependency_chains_mapped: number // count of edges in DEPENDENCY GRAPH
  open_issues_found: number        // count from OPEN ISSUES section
  hot_files_ranked: number         // count in HOT FILES section

  files_read: {
    path: string
    sha: string | "[NOT_AVAILABLE]"
    role: "audit_doc" | "fix_plan" | "workflow_sequence" | "node_code"
  }[]

  warnings: {
    type: "REQUIRES_VERIFICATION" | "FILE_NOT_FOUND" | "STALE_REFERENCE"
    message: string
    affected_field: string  // which SYSTEM_MEMORY.md section is affected
  }[]

  quality_gate: {
    dependency_chain_verified: boolean
    minimal_file_access_confirmed: boolean  // always true for /init (full scan permitted)
    no_breaking_changes_introduced: boolean // always true for /init (read-only)
  }
}
```

---

## DebugOutput

```typescript
interface DebugOutput {
  command: "/debug"
  description: string  // user-provided failure description
  confidence: number   // 0-100

  memory_age_days: number
  memory_stale: boolean

  hypothesis: {
    primary_suspect_module: string   // from MODULE INDEX
    primary_suspect_file: string     // exact path
    hypothesis_basis: "KNOWN_FAILURE_ZONE" | "DEPENDENCY_TRACE" | "HOT_FILE_HEURISTIC"
    known_issue_id: string | null    // e.g., "D-01", "P-01" if matches open issue
  }

  files_accessed: {
    path: string
    reason: string  // why this file was opened
    relevant_section: string  // which part of the file answered the question
  }[]  // max length: 3

  diagnosis: {
    root_cause: string
    affected_dependency_chain: string[]  // ordered list of module names
    is_known_open_issue: boolean
    open_issue_id: string | null
    fix_already_documented: boolean  // true if in CRYPTO_SIGNAL_SYSTEM_FIX_PLAN.md
  }

  proposed_fix: {
    scope: "SINGLE_FILE" | "MULTI_FILE" | "N8N_UI_ACTION" | "EXTERNAL_ACTION"
    files_to_change: string[]
    risk_level: "HIGH" | "MEDIUM" | "LOW"
    impact_analysis_required: boolean
    summary: string
  }

  quality_gate: {
    dependency_chain_verified: boolean
    minimal_file_access_confirmed: boolean
    no_breaking_changes_introduced: boolean
  }
}
```

---

## RootCauseOutput

```typescript
interface RootCauseOutput {
  command: "/root-cause"
  description: string
  confidence: number  // 0-100

  failure_point_module: string   // where failure was observed
  failure_point_file: string

  dependency_chain_traced: {
    module: string
    file: string
    direction: "UPSTREAM" | "DOWNSTREAM"
    ruled_out: boolean
    ruling_reason: string | null
  }[]

  root_cause: {
    module: string
    file: string
    mechanism: string    // e.g., "macd_histogram_1h is null because it is absent from Merge SQL SELECT"
    audit_finding: string | null  // e.g., "D-01"
    depth_from_failure: number   // how many hops upstream from observed failure
  }

  files_accessed: {
    path: string
    reason: string
  }[]  // max length: 3

  fix_pointer: string  // "See CRYPTO_SIGNAL_SYSTEM_FIX_PLAN.md [ID]" or "No documented fix — new finding"

  quality_gate: {
    dependency_chain_verified: boolean
    minimal_file_access_confirmed: boolean
    no_breaking_changes_introduced: boolean
  }
}
```

---

## OptimizeOutput

```typescript
interface OptimizeOutput {
  command: "/optimize"
  target: string        // user-provided target
  target_module: string // resolved from MODULE INDEX
  target_file: string   // primary file from MODULE INDEX
  risk_level: "HIGH" | "MEDIUM" | "LOW"  // from MODULE INDEX
  blocked: boolean      // true if HIGH risk and no impact analysis in session

  block_reason: string | null  // populated if blocked = true
  impact_analysis_required_command: string | null  // e.g., "/impact-analysis optimize SCORE AGGREGATOR OBV correction"

  current_behavior: string    // what the code currently does (from file read)
  proposed_change: {
    description: string
    file: string
    scope: "FUNCTION_LEVEL" | "CONSTANT_LEVEL" | "LOGIC_BLOCK"
    is_additive_only: boolean  // true = no existing output fields removed or renamed
    sync_obligations: string[] // e.g., ["Update TIER_MIN_RR in HARD FILTERS ENFORCER — R-04 SYNC REQUIRED"]
  }

  files_accessed: {
    path: string
    reason: string
  }[]  // max length: 1 (target file only)

  quality_gate: {
    dependency_chain_verified: boolean
    minimal_file_access_confirmed: boolean
    no_breaking_changes_introduced: boolean
  }
}
```

---

## UpgradeOutput

```typescript
interface UpgradeOutput {
  command: "/upgrade"
  description: string
  blocked: boolean  // true if /impact-analysis not run

  block_reason: string | null

  impact_analysis_reference: {
    ran_in_session: boolean
    stability_score: number | null
    affected_modules: string[]
  }

  rollback_strategy: {
    n8n_nodes_to_revert: string[]
    db_schema_changes: boolean        // if true → irreversible without DOWN migration
    scan_cycle_id_affected: boolean   // if true → in-flight cycle data may be corrupt
    rollback_steps: string[]
  }

  upgrade_steps: {
    step: number
    description: string
    file: string | "N8N_UI" | "SUPABASE_SQL"
    independently_revertable: boolean
    requires_verification: string[]  // [REQUIRES_VERIFICATION] items
  }[]

  files_accessed: {
    path: string
    reason: string
  }[]

  quality_gate: {
    dependency_chain_verified: boolean
    minimal_file_access_confirmed: boolean
    no_breaking_changes_introduced: boolean
  }
}
```

---

## ImpactAnalysisOutput

```typescript
interface ImpactAnalysisOutput {
  command: "/impact-analysis"
  change_description: string

  primary_module: string
  primary_file: string

  affected_modules: {
    module: string
    file: string
    risk_level: "HIGH" | "MEDIUM" | "LOW"
    impact_mechanism: string   // e.g., "reads tier from ASSET TIER CALCULATOR output"
    cascade_depth: number      // 1 = direct dependency, 2 = two hops, etc.
  }[]

  stability_score: number      // 0.0 - 1.0
  risk_classification: "LOW_RISK" | "MEDIUM_RISK" | "HIGH_RISK"

  cascade_patterns_triggered: string[]  // names of patterns from impact-model.md
  // e.g., ["Tier boundary cascade", "Threshold divergence cascade"]

  known_failure_zones_in_chain: {
    module: string
    open_issue_ids: string[]
    interaction_risk: string
  }[]

  files_to_verify: string[]    // all files that need checking or changing
  requires_user_confirmation: boolean

  recommendation: "PROCEED" | "PROCEED_WITH_CAUTION" | "BLOCK_REQUIRES_PLAN"

  quality_gate: {
    dependency_chain_verified: boolean
    minimal_file_access_confirmed: boolean
    no_breaking_changes_introduced: boolean
  }
}
```

---

## ArchitectureReviewOutput

```typescript
interface ArchitectureReviewOutput {
  command: "/architecture-review"
  memory_age_days: number
  memory_stale: boolean

  open_issues: {
    id: string            // "A-07", "D-01", etc.
    priority: "P0" | "P1" | "P2"
    description: string
    affected_file: string
  }[]

  hot_files_status: {
    rank: number
    file: string
    audit_finding_count: number
    open_issues: string[]   // IDs of currently open issues in this file
    current_risk: "HIGH" | "MEDIUM" | "LOW"
  }[]

  coupling_issues: {
    module: string
    depended_on_by_count: number  // how many other modules depend on it
    coupling_risk: string         // e.g., "single point of failure for all risk parameters"
  }[]

  top_improvements: {
    rank: number
    improvement: string
    risk_reward: "HIGH_REWARD_LOW_RISK" | "HIGH_REWARD_HIGH_RISK" | "LOW_REWARD_LOW_RISK"
    audit_basis: string  // which finding or open issue motivates this
    command_to_run: string  // e.g., "/upgrade fix D-01 add macd_histogram_1h to Merge"
  }[]

  quality_gate: {
    dependency_chain_verified: boolean
    minimal_file_access_confirmed: boolean
    no_breaking_changes_introduced: boolean
  }
}
```
