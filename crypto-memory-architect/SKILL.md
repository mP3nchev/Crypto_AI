---
name: crypto-memory-architect
version: 1.0.0
description: >
  Persistent memory and safe-change architecture skill for the mp3nchev/crypto_ai
  N8N signal pipeline (Binance Perpetual Futures, TAAPI.io, Supabase, Telegram).

  Always use this skill when working on crypto_ai or any session involving:
  - SCORE AGGREGATOR, TREND SCORE CALCULATOR, HARD FILTERS ENFORCER
  - ASSET TIER CALCULATOR, GROUP CANDLE RESPONSES
  - TP-SL CALCULATOR, RISK-REWARD FILTER, RISK-REWARD SCORE OUTPUT
  - Merge (SQL node, Row 3 Part 2), Adaptive Weights Calculator1
  - TAAPI bulk batch processing, Separation of Requests, Cooldown after Batch 6
  - Any change to scoring weights, tier boundaries (1-5 / 6-15 / 16-20), or R/R thresholds
  - Any change to SL multipliers, leverage caps, or fee calculations
  - Any file in row1/, row2/, row3/, or row4/
  - Supabase table schema (crypto_symbols, raw_candles_data, asset_tiers, scan_results, signals_log)
  - Audit report updates, fix plan reviews, post-PR verification

  Triggered by phrases:
  - "change the tier" / "update tier boundaries"
  - "update the scoring" / "change score weights" / "modify weights"
  - "modify the filter" / "change the threshold" / "update R/R"
  - "fix the candle" / "candle processing" / "Binance fetch"
  - "add indicator" / "new TAAPI field" / "MACD" / "RSI" / "ATR"
  - "change the SL" / "stop loss" / "take profit" / "TP levels"
  - "update leverage" / "leverage cap" / "recommended leverage"
  - "what's broken" / "debug signal" / "why is the score"
  - "why is the signal" / "false signal" / "wrong direction"
  - "TAAPI rate limit" / "429" / "batch cooldown"
  - "funding rate" / "perpetual" / "fee-adjusted"
  - "scan_cycle_id" / "cycle propagation"
  - "Supabase insert" / "signals_log" / "asset_tiers"
  - "audit" / "fix plan" / "open issue" / "remaining issue"

platforms:
  - claude-code
---

# crypto-memory-architect

Persistent memory and safe-change architecture skill for the `mp3nchev/crypto_ai`
N8N signal pipeline. Prevents silent regressions in a system where one wrong tier
boundary or missing SQL field silently corrupts all downstream signals.

---

## Mandatory First Step

**`/init` must run before any other command in a new session.**

If SYSTEM_MEMORY.md does not exist at `.claude/SYSTEM_MEMORY.md`, or is older
than 7 days, Claude will prompt for `/init` or `/refresh-memory` before proceeding.

---

## Command Reference

| Command | Purpose |
|---------|---------|
| `/init` | Read full repo + audit docs once. Write `.claude/SYSTEM_MEMORY.md`. |
| `/debug [description]` | Diagnose a failure using memory + ≤3 files. |
| `/root-cause [description]` | Trace dependency chain backwards from failure point. |
| `/optimize [target]` | Propose minimal change. Blocked if target is HIGH risk without `/impact-analysis`. |
| `/upgrade [description]` | Propose upgrade + rollback. Blocked without prior `/impact-analysis`. |
| `/impact-analysis [change]` | Score stability impact across full dependency chain. Required before any HIGH-risk change. |
| `/architecture-review` | Summarize current state vs known failure zones. Reads memory only. |
| `/refresh-memory` | Re-run `/init`. Overwrites SYSTEM_MEMORY.md. Use after significant repo changes. |
| `/generate-skill` | Output updated version of this skill package reflecting current SYSTEM_MEMORY.md. |

Full command logic: see `commands.md`

---

## File Access Strategy

1. **Always read `.claude/SYSTEM_MEMORY.md` first.** This is the single source of
   truth for module names, dependency chains, risk levels, and hot files.

2. **Open at most 3 files per command** (excluding SYSTEM_MEMORY.md). Name each
   file before reading it. Justify why each is needed.

3. **Never perform a full repo scan after `/init` is complete.** The module index
   in SYSTEM_MEMORY.md eliminates the need.

4. **SYSTEM_MEMORY.md lives at:** `.claude/SYSTEM_MEMORY.md` in the repo root.
   This path is fixed and cannot be changed.

---

## Quality Gate

Runs automatically after every command output. See `rules.md` for full definition.
If any gate check fails → regenerate internally → do not return result.

```
dependency_chain_verified: bool
minimal_file_access_confirmed: bool
no_breaking_changes_introduced: bool
```
