#!/usr/bin/env bash
# P-27 — main pipeline regression guard.
#   1. In row1/ … row4/ ONLY the allowed files may differ from the starting commit.
#   2. SIGNAL LOGGER: behavioural comparison of the old and the new version.
#
#   scripts/check_pipeline_regression.sh [BASE_COMMIT]
# BASE_COMMIT defaults to the commit BEFORE paper trading started (fixed, so the check keeps
# working after the work is merged into main; a merge-base with main would then be HEAD itself).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PAPER_BASE="7ac68817e1bf2161e1c53d60dd19ab98b23706af"   # merge of PR #23, last commit before paper trading
BASE="${1:-$PAPER_BASE}"
git cat-file -e "$BASE^{commit}" 2>/dev/null || { echo "base commit $BASE not found (shallow clone? use fetch-depth: 0)"; exit 2; }
echo "base commit: $(git log --oneline -1 "$BASE")"

# Allowed per spec section 3 ("Modified files"):
ALLOWED=(
  "row1/Sort & Select Top 20"
  "row4/SIGNAL LOGGER"
  "row4/SUPABASE SIGNAL INSERT — N8N CONFIG"
  # Added later, on purpose, after a production timeout in Row 2 (ECONNABORTED on ~960 single
  # POSTs): a NEW additive node; no existing Row 2 file is modified.
  "row2/CANDLE BATCHER FOR UPSERT"
  # TAAPI v1 -> v2 migration (the user's key is a v2 key; v1 endpoint rejects it). Output fields of the
  # processor are unchanged; scripts/test_taapi_v2_adapter.js proves it.
  "row2/Separation of Requests"
  "row2/TAAPI RESPONSE PROCESSOR"
  # v2 has no 2h timeframe: the 9 two-hour indicators are computed from Binance candles (TA-Lib algorithms).
  "row2/2H INDICATOR CALCULATOR"
  "row2/TAAPI v2 MIGRATION — N8N CONFIG"
)

FAIL=0
echo "== files changed in row1/ … row4/"
# -z: NUL-separated, so the unusual file names (spaces, em dash) are handled exactly
while IFS= read -r -d '' f; do
  ok=0
  for a in "${ALLOWED[@]}"; do [ "$f" = "$a" ] && ok=1; done
  if [ "$ok" = 1 ]; then echo "  allowed   $f"; else echo "  FORBIDDEN $f"; FAIL=1; fi
done < <(git diff -z --name-only "$BASE" HEAD -- row1 row2 row3 row4)

echo "== Sort & Select Top 20: only LIMIT changed"
changed=$(git diff -U0 "$BASE" HEAD -- "row1/Sort & Select Top 20" | grep -E '^[+-][^+-]' | grep -vE '^[+-]\s*//' || true)
echo "$changed" | sed 's/^/  /'
if [ "$(echo "$changed" | grep -c .)" != 2 ] || ! echo "$changed" | grep -q '^+const LIMIT = 20;'; then
  echo "  FAIL: expected exactly the LIMIT line to change"; FAIL=1
fi

echo "== SIGNAL LOGGER: no existing line removed except the weights block"
removed=$(git diff -U0 "$BASE" HEAD -- "row4/SIGNAL LOGGER" | grep -E '^-[^-]' || true)
unexpected=$(echo "$removed" | grep -vE 'data\.weight_(momentum|trend|volatility|volume|price_action)|^-\s*weights: \{|^-\s*$' || true)
if [ -n "$unexpected" ]; then echo "  FAIL: unexpected removed lines:"; echo "$unexpected" | sed 's/^/    /'; FAIL=1; else echo "  ok"; fi

echo "== SIGNAL LOGGER: behaviour old vs new"
git show "$BASE:row4/SIGNAL LOGGER" > "${TMPDIR:-/tmp}/signal_logger_old.js"
node scripts/test_signal_logger_regression.js "${TMPDIR:-/tmp}/signal_logger_old.js" "row4/SIGNAL LOGGER" || FAIL=1

echo "== TAAPI v2 adapter (Row 2): request shape + same output fields as v1"
node scripts/test_taapi_v2_adapter.js || FAIL=1

echo
[ "$FAIL" = 0 ] && echo "PIPELINE REGRESSION: OK" || { echo "PIPELINE REGRESSION: FAILED"; exit 1; }
