-- =====================================================================
-- T17_stats — statistics, daily P&L, Sofia day boundary
-- Spec: P-17 … P-20. Run in a TEST project/branch only (see tests/README.md).
-- Prerequisites: 001 … 004. Ends with ROLLBACK; aborts on any mismatch.
-- =====================================================================
BEGIN;

-- ---- shared test prelude (identical in every Txx file) --------------------
-- Clean slate inside this transaction (ROLLBACK at the end restores everything).
DELETE FROM public.paper_position_events;
DELETE FROM public.paper_positions;
DELETE FROM public.paper_candles;
DELETE FROM public.paper_monitor_runs;
DELETE FROM public.telegram_signals;
DELETE FROM public.paper_config;
INSERT INTO public.paper_config (id) VALUES (1);   -- spec defaults

-- assert helper
CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF NOT coalesce(p_ok, false) THEN RAISE EXCEPTION '%', p_msg; END IF;
END $f$;

-- insert one signal (fires the trigger) and return its paper position
CREATE OR REPLACE FUNCTION pg_temp.sig(
  p_symbol text, p_dir text, p_tier int,
  p_entry numeric, p_sl numeric, p_tp1 numeric, p_tp2 numeric, p_tp3 numeric,
  p_a1 numeric DEFAULT 40, p_a2 numeric DEFAULT 40, p_a3 numeric DEFAULT 20,
  p_lev int DEFAULT 1, p_cycle_ts timestamptz DEFAULT NULL,
  p_sent_at timestamptz DEFAULT now())
RETURNS public.paper_positions LANGUAGE plpgsql AS $f$
DECLARE v_id int; r public.paper_positions;
BEGIN
  INSERT INTO public.telegram_signals
    (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss, tp1, tp2, tp3,
     tp1_allocation, tp2_allocation, tp3_allocation, suggested_leverage,
     cycle_timestamp, sent_at)
  VALUES ('TEST-' || gen_random_uuid(), p_symbol, p_tier, p_dir, p_entry, p_sl, p_tp1, p_tp2, p_tp3,
          p_a1, p_a2, p_a3, p_lev, p_cycle_ts, p_sent_at)
  RETURNING id INTO v_id;
  SELECT * INTO r FROM public.paper_positions WHERE signal_id = v_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'no paper position for signal %', v_id; END IF;
  RETURN r;
END $f$;

-- insert one closed 1h candle (close_time = open + 1h - 1ms, like Binance)
CREATE OR REPLACE FUNCTION pg_temp.candle(p_symbol text, p_open timestamptz,
  o numeric, h numeric, l numeric, c numeric) RETURNS void LANGUAGE sql AS $f$
  INSERT INTO public.paper_candles (symbol, open_time, close_time, open, high, low, close, volume)
  VALUES (p_symbol, p_open, p_open + interval '1 hour' - interval '1 millisecond', o, h, l, c, 1);
$f$;

-- reload a position
CREATE OR REPLACE FUNCTION pg_temp.pos(p_id bigint) RETURNS public.paper_positions
LANGUAGE sql AS $f$ SELECT * FROM public.paper_positions WHERE id = p_id $f$;

-- one event of a position by type
CREATE OR REPLACE FUNCTION pg_temp.ev(p_id bigint, p_type text) RETURNS public.paper_position_events
LANGUAGE sql AS $f$
  SELECT * FROM public.paper_position_events WHERE position_id = p_id AND event_type = p_type
$f$;

-- number of exit (fill) events of a position
CREATE OR REPLACE FUNCTION pg_temp.exits(p_id bigint) RETURNS bigint LANGUAGE sql AS $f$
  SELECT count(*) FROM public.paper_position_events
   WHERE position_id = p_id
     AND event_type IN ('TP1','TP2','TP3','SL','BREAKEVEN_SL','TIMEOUT','LIQUIDATION','DATA_UNAVAILABLE')
$f$;

-- |a - b| <= tol (default 0.01 $)
CREATE OR REPLACE FUNCTION pg_temp.near(a numeric, b numeric, tol numeric DEFAULT 0.01)
RETURNS boolean LANGUAGE sql AS $f$ SELECT abs(a - b) <= tol $f$;
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  p public.paper_positions;
  s jsonb;
  d record;
  n int;
BEGIN
  -- helper: open a position and close it directly with a given net / close time
  CREATE OR REPLACE FUNCTION pg_temp.closed(p_symbol text, p_dir text, p_tier int,
                                            p_net numeric, p_closed timestamptz)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE p public.paper_positions;
  BEGIN
    IF p_dir = 'LONG' THEN
      p := pg_temp.sig(p_symbol, 'LONG', p_tier, 100,95,105,110,115, 40,40,20, 1, NULL, p_closed - interval '5 hours');
    ELSE
      p := pg_temp.sig(p_symbol, 'SHORT', p_tier, 100,105,95,90,85, 40,40,20, 1, NULL, p_closed - interval '5 hours');
    END IF;
    UPDATE public.paper_positions
       SET status = 'CLOSED', remaining_pct = 0, realized_net_usd = p_net, closed_at = p_closed,
           duration_hours = 5, exit_reason = 'TEST'
     WHERE id = p.id;
    RETURN p.id;
  END $f$;

  PERFORM pg_temp.closed('BTCUSDT', 'LONG',  1,  10,    '2026-11-05 10:00+00');
  PERFORM pg_temp.closed('ETHUSDT', 'SHORT', 2,  -5,    '2026-11-05 11:00+00');
  PERFORM pg_temp.closed('SOLUSDT', 'LONG',  1,   0.005,'2026-11-05 12:00+00');   -- BREAKEVEN
  PERFORM pg_temp.closed('XRPUSDT', 'LONG',  3,  20,    '2026-11-05 21:30+00');   -- 23:30 Sofia, same day
  PERFORM pg_temp.closed('ADAUSDT', 'LONG',  2,  -8,    '2026-11-05 23:30+00');   -- 01:30 Sofia, NEXT day
  p := pg_temp.sig('DOTUSDT','LONG',1, 100,95,105,110,115);                         -- stays OPEN
  p := pg_temp.sig('BADUSDT','LONG',1, 100,101,105,110,115, 40,40,20, 1, NULL, '2026-11-05 10:00+00');  -- REJECTED

  -- the 23:30 UTC trade belongs to the NEXT day in Europe/Sofia
  PERFORM pg_temp.chk((SELECT closed_date_local FROM public.paper_positions_v WHERE symbol = 'ADAUSDT') = '2026-11-06',
                      'T17: 23:30 UTC must be 2026-11-06 in Sofia');
  PERFORM pg_temp.chk((SELECT closed_date_local FROM public.paper_positions_v WHERE symbol = 'XRPUSDT') = '2026-11-05',
                      'T17: 21:30 UTC is still 2026-11-05 in Sofia');

  s := public.paper_stats('2026-11-05', '2026-11-05');
  PERFORM pg_temp.chk((s->>'trades')::int = 4 AND (s->>'wins')::int = 2 AND (s->>'losses')::int = 1
                  AND (s->>'breakeven')::int = 1, 'T17: day counts ' || s::text);
  PERFORM pg_temp.chk((s->>'win_rate_pct')::numeric = 50, 'T17: win rate');
  PERFORM pg_temp.chk((s->>'total_net_usd')::numeric = 25.005, 'T17: total net');
  PERFORM pg_temp.chk((s->>'total_return_pct')::numeric = 2.5005, 'T17: return %');
  PERFORM pg_temp.chk((s->>'avg_win_usd')::numeric = 15 AND (s->>'avg_loss_usd')::numeric = -5, 'T17: avg win/loss');
  PERFORM pg_temp.chk((s->>'profit_factor')::numeric = 6, 'T17: profit factor 30/5');
  PERFORM pg_temp.chk((s->>'expectancy_usd')::numeric = 6.25125, 'T17: expectancy');
  PERFORM pg_temp.chk((s->>'avg_duration_hours')::numeric = 5, 'T17: avg duration');
  PERFORM pg_temp.chk((s->>'open_positions')::int = 1, 'T17: open positions ignore the date filter');
  PERFORM pg_temp.chk((s->>'rejected')::int = 1 AND (s->>'skipped')::int = 0, 'T17: rejected by opened date');

  s := public.paper_stats('2026-11-06', '2026-11-06');
  PERFORM pg_temp.chk((s->>'trades')::int = 1 AND (s->>'total_net_usd')::numeric = -8
                  AND (s->>'profit_factor')::numeric = 0 AND (s->>'win_rate_pct')::numeric = 0, 'T17: next day (PF = 0/8 = 0) ' || s::text);

  s := public.paper_stats('2026-11-01', '2026-11-30');
  PERFORM pg_temp.chk((s->>'trades')::int = 5 AND (s->>'total_net_usd')::numeric = 17.005, 'T17: month');
  PERFORM pg_temp.chk(pg_temp.near((s->>'profit_factor')::numeric, 30/13.0, 1e-9), 'T17: month PF');
  PERFORM pg_temp.chk(pg_temp.near((s->>'max_drawdown_pct')::numeric, 8/1025.005*100, 1e-9),
                      'T17: max drawdown ' || (s->>'max_drawdown_pct'));

  s := public.paper_stats('2026-11-01', '2026-11-30', p_symbols => ARRAY['BTCUSDT','XRPUSDT']);
  PERFORM pg_temp.chk(s->'profit_factor' = 'null'::jsonb, 'T17: no losses -> profit factor NULL');

  s := public.paper_stats('2026-11-10', '2026-11-12');
  PERFORM pg_temp.chk((s->>'trades')::int = 0 AND (s->>'win_rate_pct')::numeric = 0
                  AND s->'expectancy_usd' = 'null'::jsonb, 'T17: empty range');

  -- filters
  s := public.paper_stats('2026-11-01', '2026-11-30', p_direction => 'SHORT');
  PERFORM pg_temp.chk((s->>'trades')::int = 1 AND (s->>'total_net_usd')::numeric = -5
                  AND (s->>'open_positions')::int = 0, 'T17: direction filter');
  s := public.paper_stats('2026-11-01', '2026-11-30', p_tiers => ARRAY[1]);
  PERFORM pg_temp.chk((s->>'trades')::int = 2 AND (s->>'total_net_usd')::numeric = 10.005, 'T17: tier filter');
  s := public.paper_stats('2026-11-01', '2026-11-30', p_categories => ARRAY['BTC']);
  PERFORM pg_temp.chk((s->>'trades')::int = 1 AND (s->>'total_net_usd')::numeric = 10, 'T17: category filter');
  s := public.paper_stats('2026-11-01', '2026-11-30', p_symbols => ARRAY['XRPUSDT','ADAUSDT']);
  PERFORM pg_temp.chk((s->>'trades')::int = 2 AND (s->>'total_net_usd')::numeric = 12, 'T17: symbol filter');
  s := public.paper_stats('2026-11-01', '2026-11-30', p_symbols => ARRAY[]::text[]);
  PERFORM pg_temp.chk((s->>'trades')::int = 5, 'T17: empty array = all');

  -- daily P&L: every day of the month, cumulative from 0
  SELECT count(*) INTO n FROM public.paper_daily_pnl('2026-11-17');
  PERFORM pg_temp.chk(n = 30, 'T17: November must have 30 rows, got ' || n);
  SELECT * INTO d FROM public.paper_daily_pnl('2026-11-01') WHERE day = '2026-11-01';
  PERFORM pg_temp.chk(d.trades = 0 AND d.net_usd = 0 AND d.cumulative_net_usd = 0, 'T17: empty day');
  SELECT * INTO d FROM public.paper_daily_pnl('2026-11-01') WHERE day = '2026-11-05';
  PERFORM pg_temp.chk(d.trades = 4 AND d.wins = 2 AND d.losses = 1 AND d.net_usd = 25.005
                  AND d.cumulative_net_usd = 25.005, 'T17: day 5');
  SELECT * INTO d FROM public.paper_daily_pnl('2026-11-01') WHERE day = '2026-11-06';
  PERFORM pg_temp.chk(d.trades = 1 AND d.net_usd = -8 AND d.cumulative_net_usd = 17.005, 'T17: day 6');
  SELECT * INTO d FROM public.paper_daily_pnl('2026-11-01') WHERE day = '2026-11-30';
  PERFORM pg_temp.chk(d.cumulative_net_usd = 17.005, 'T17: month end cumulative');
  PERFORM pg_temp.chk((SELECT sum(net_usd) FROM public.paper_daily_pnl('2026-11-01'))
                      = (public.paper_stats('2026-11-01','2026-11-30')->>'total_net_usd')::numeric,
                      'T17: daily sum = monthly stats');
  SELECT count(*) INTO n FROM public.paper_daily_pnl('2026-11-01', p_direction => 'SHORT') WHERE trades > 0;
  PERFORM pg_temp.chk(n = 1, 'T17: daily P&L respects filters');

  -- comparison breakdown
  PERFORM pg_temp.chk((SELECT count(*) FROM public.paper_stats_breakdown('tier', '2026-11-01', '2026-11-30')) = 3,
                      'T17: breakdown by tier');
  PERFORM pg_temp.chk((SELECT (stats->>'total_net_usd')::numeric FROM public.paper_stats_breakdown('direction', '2026-11-01', '2026-11-30')
                        WHERE segment = 'LONG') = 22.005 AND
                      (SELECT bool_and(small_sample) FROM public.paper_stats_breakdown('symbol')), 'T17: breakdown by direction / small sample');

  -- determinism: same data, same answer
  PERFORM pg_temp.chk(public.paper_stats('2026-11-01','2026-11-30') = public.paper_stats('2026-11-01','2026-11-30'),
                      'T17: repeat call must be identical');

  RAISE NOTICE 'T17 PASSED: statistics, daily P&L, Sofia day boundary';
END $$;

ROLLBACK;
