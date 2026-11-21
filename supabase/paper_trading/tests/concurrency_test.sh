#!/usr/bin/env bash
# Real multi-session checks (what a single-transaction SQL test cannot prove).
# Uses the database from PGDATABASE (already migrated). Cleans up after itself.
set -euo pipefail
Q() { psql -qtAX -v ON_ERROR_STOP=1 "$@"; }
fail() { echo "  concurrency: $*"; exit 1; }

Q -c "DELETE FROM paper_position_events; DELETE FROM paper_positions; DELETE FROM telegram_signals; DELETE FROM paper_candles; DELETE FROM paper_monitor_runs;
      DELETE FROM paper_config; INSERT INTO paper_config (id) VALUES (1);" >/dev/null

# 1. Six sessions insert a signal for the SAME symbol at the same moment:
#    exactly one OPEN position, five SKIPPED DUPLICATE_OPEN_POSITION, 1:1 with signals.
# Each session keeps its transaction open for 0.4 s AFTER the trigger ran, so the sessions
# genuinely overlap (without this the tiny trigger finishes before the next process starts).
for i in 1 2 3 4 5 6; do
  Q -c "BEGIN;
        INSERT INTO telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss, tp1, tp2, tp3,
          tp1_allocation, tp2_allocation, tp3_allocation)
        VALUES ('conc-$i', 'RACEUSDT', 1, 'LONG', 100, 95, 105, 110, 115, 40, 40, 20);
        SELECT pg_sleep(0.4); COMMIT;" >/dev/null &
done
wait
[ "$(Q -c "SELECT count(*) FROM telegram_signals")" = 6 ]                                      || fail "expected 6 saved signals"
[ "$(Q -c "SELECT count(*) FROM paper_positions WHERE status='OPEN'")" = 1 ]                    || fail "expected exactly 1 OPEN position"
[ "$(Q -c "SELECT count(*) FROM paper_positions WHERE status_reason='DUPLICATE_OPEN_POSITION'")" = 5 ] || fail "expected 5 duplicates"
[ "$(Q -c "SELECT count(*) FROM telegram_signals s WHERE (SELECT count(*) FROM paper_positions p WHERE p.signal_id=s.id)<>1")" = 0 ] || fail "1:1 broken"

# 2. Many different symbols at once against max_open_positions = 3.
Q -c "UPDATE paper_config SET max_open_positions = 3" >/dev/null
Q -c "DELETE FROM paper_position_events; DELETE FROM paper_positions; DELETE FROM telegram_signals;" >/dev/null
for i in $(seq 1 10); do
  Q -c "BEGIN;
        INSERT INTO telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss, tp1, tp2, tp3,
          tp1_allocation, tp2_allocation, tp3_allocation)
        VALUES ('cap-$i', 'CAP${i}USDT', 1, 'LONG', 100, 95, 105, 110, 115, 40, 40, 20);
        SELECT pg_sleep(0.2); COMMIT;" >/dev/null &
done
wait
[ "$(Q -c "SELECT count(*) FROM paper_positions WHERE status='OPEN'")" = 3 ]                    || fail "cap breached: $(Q -c "SELECT count(*) FROM paper_positions WHERE status='OPEN'") open"
[ "$(Q -c "SELECT count(*) FROM paper_positions")" = 10 ]                                       || fail "every signal needs a position"

# 3. Four overlapping monitor runs: at least one evaluates, the others back off (SKIPPED_LOCKED); TP1 counted once.
Q -c "DELETE FROM paper_position_events; DELETE FROM paper_positions; DELETE FROM telegram_signals; DELETE FROM paper_monitor_runs;
      UPDATE paper_config SET max_open_positions = 10, leverage_override = 5;" >/dev/null
Q -c "INSERT INTO telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss, tp1, tp2, tp3,
        tp1_allocation, tp2_allocation, tp3_allocation, sent_at)
      VALUES ('mon-1', 'MONUSDT', 1, 'LONG', 80000, 78800, 81200, 81600, 82000, 40, 40, 20,
              date_trunc('hour', now()) - interval '5 hours' + interval '14 minutes')" >/dev/null
Q -c "INSERT INTO paper_candles (symbol, open_time, close_time, open, high, low, close, volume)
      SELECT 'MONUSDT', date_trunc('hour', now()) - make_interval(hours => h), date_trunc('hour', now()) - make_interval(hours => h) + interval '1 hour' - interval '1 millisecond',
             80050, CASE WHEN h = 4 THEN 81300 ELSE 80100 END, 79900, 80050, 1 FROM generate_series(1, 4) h" >/dev/null
Q -c "SELECT pg_sleep(0)" >/dev/null
for i in 1 2 3 4; do Q -c "BEGIN; SELECT paper_evaluate_positions(); SELECT pg_sleep(0.5); COMMIT;" >/dev/null & done
wait
[ "$(Q -c "SELECT tp_hits FROM paper_positions WHERE symbol='MONUSDT'")" = 1 ]                 || fail "TP1 must be counted exactly once"
[ "$(Q -c "SELECT count(*) FROM paper_position_events WHERE event_type='TP1'")" = 1 ]           || fail "duplicate TP1 events"
[ "$(Q -c "SELECT count(*) FROM paper_monitor_runs")" = 4 ]                                     || fail "every run must be logged"
[ "$(Q -c "SELECT count(*) FROM paper_monitor_runs WHERE status='SKIPPED_LOCKED'")" -ge 1 ]     || fail "overlapping runs must back off (SKIPPED_LOCKED)"
[ "$(Q -c "SELECT count(*) FROM paper_monitor_runs WHERE status='OK'")" -ge 1 ]                 || fail "one run must have evaluated"

Q -c "DELETE FROM paper_position_events; DELETE FROM paper_positions; DELETE FROM telegram_signals; DELETE FROM paper_candles; DELETE FROM paper_monitor_runs;
      DELETE FROM paper_config; INSERT INTO paper_config (id) VALUES (1);" >/dev/null
