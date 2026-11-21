#!/usr/bin/env bash
# Runs the whole paper-trading SQL suite on a THROWAWAY PostgreSQL database.
#
#   PGHOST=... PGPORT=... PGUSER=... PGPASSWORD=... tests/run_all.sh [dbname]
#
# Creates the database (default: paper_test), applies telegram_signals.sql and
# 001 … 006 twice (idempotency), then runs every Txx test and the concurrency check.
# NEVER point this at production: it creates and drops a database.
set -euo pipefail

DB="${1:-paper_test}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$HERE/.."
BASE="$SQL/../telegram_signals.sql"
FAILED=0

case "$DB" in postgres|template0|template1|production|prod) echo "refusing to use database '$DB'"; exit 2;; esac

psql -qv ON_ERROR_STOP=1 -d postgres -c "DROP DATABASE IF EXISTS \"$DB\"" -c "CREATE DATABASE \"$DB\""
export PGDATABASE="$DB"
trap 'psql -q -d postgres -c "DROP DATABASE IF EXISTS \"'"$DB"'\"" >/dev/null 2>&1 || true' EXIT

q() { psql -qX -v ON_ERROR_STOP=1 "$@" 2>&1 | grep -v "NOTICE" || true; }

psql -qX -v ON_ERROR_STOP=1 -f "$HERE/tools/supabase_roles.sql" >/dev/null
psql -qX -v ON_ERROR_STOP=1 -f "$BASE" >/dev/null

echo "== applying migrations (twice: must be idempotent)"
for pass in 1 2; do
  for f in 001_schema 002_signal_ingest 003_engine 004_analytics 005_security 006_dashboard; do
    out=$(psql -qX -v ON_ERROR_STOP=1 -f "$SQL/$f.sql" 2>&1 | grep -E "ERROR" || true)
    if [ -n "$out" ]; then echo "FAIL  $f (pass $pass): $out"; FAILED=1; fi
  done
done
[ "$FAILED" = 0 ] && echo "ok    001 … 006 applied twice"

echo "== tests"
for t in "$HERE"/T*.sql; do
  name=$(basename "$t" .sql)
  out=$(psql -qX -v ON_ERROR_STOP=1 -f "$t" 2>&1 || true)
  if echo "$out" | grep -q "PASSED"; then printf "ok    %s\n" "$name"
  else printf "FAIL  %s\n%s\n" "$name" "$(echo "$out" | grep -E 'ERROR|T[0-9]+' | head -3)"; FAILED=1; fi
done

echo "== concurrency (real parallel sessions)"
if "$HERE/concurrency_test.sh"; then echo "ok    concurrency"; else echo "FAIL  concurrency"; FAILED=1; fi

echo
if [ "$FAILED" = 0 ]; then echo "ALL PASSED"; else echo "FAILURES — see above"; exit 1; fi
