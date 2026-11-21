-- =====================================================================
-- T17b_view_and_health — view fields, indicative P&L, health warnings
-- Spec: P-17, P-20, P-28. Run in a TEST project/branch only (see tests/README.md).
-- Prerequisites: 001 … 004 (T23: also 005). Ends with ROLLBACK; aborts on any mismatch.
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
  b timestamptz := date_trunc('hour', now()) - interval '80 hours';
  p public.paper_positions;
  q public.paper_positions;
  e public.paper_position_events;
  r jsonb;
BEGIN
  r := (SELECT to_jsonb(h) FROM public.paper_health_v h);
  PERFORM pg_temp.chk(NOT (r->>'warning')::boolean, 'T17b: empty system has no warning ' || r::text);

  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := pg_temp.sig('BTCUSDT','LONG',1, 80000,78800,81200,81600,82000, 40,40,20, 1, NULL, b + interval '14 minutes');
  PERFORM pg_temp.candle('BTCUSDT', b + interval '1 hour', 80050, 81300, 79900, 81000);  -- TP1
  -- health: OPEN position, no OK run yet -> warning
  PERFORM pg_temp.chk((SELECT warning FROM public.paper_health_v), 'T17b: no successful run yet -> warning');
  r := public.paper_evaluate_positions();
  PERFORM pg_temp.chk((SELECT last_ok_run_age_hours < 0.1 FROM public.paper_health_v), 'T17b: last OK run age');
  -- cursor is b+1h (~78h ago) -> the position counts as not evaluated for > 3h
  PERFORM pg_temp.chk((SELECT p.id = ANY (stale_open_position_ids) AND warning FROM public.paper_health_v),
                      'T17b: stale OPEN position flagged');

  -- view: partial realised and indicative unrealised (latest close 81000)
  r := (SELECT to_jsonb(v) FROM public.paper_positions_v v WHERE id = p.id);
  PERFORM pg_temp.chk(pg_temp.near((r->>'partially_realized_net_usd')::numeric, 1.34), 'T17b: partially realised ' || (r->>'partially_realized_net_usd'));
  PERFORM pg_temp.chk((r->>'last_price')::numeric = 81000, 'T17b: last price');
  PERFORM pg_temp.chk(pg_temp.near((r->>'indicative_unrealized_usd')::numeric,
                      (250/80040.0*0.6) * ((81000 - 80040) - (80040 + 81000) * 0.00055), 1e-9),
                      'T17b: indicative unrealised ' || (r->>'indicative_unrealized_usd'));
  PERFORM pg_temp.chk(r->'outcome' = 'null'::jsonb AND (r->>'avg_exit_price')::numeric = 81200, 'T17b: open has no outcome; avg exit = TP1');
  -- partial / indicative never enter the metrics
  PERFORM pg_temp.chk((public.paper_stats()->>'trades')::int = 0
                  AND pg_temp.near((public.paper_stats()->>'partially_realized_usd')::numeric, 1.34), 'T17b: stats extras');

  PERFORM pg_temp.candle('BTCUSDT', b + interval '2 hours', 80500, 80600, 78700, 78900);  -- SL
  r := public.paper_evaluate_positions();
  r := (SELECT to_jsonb(v) FROM public.paper_positions_v v WHERE id = p.id);
  PERFORM pg_temp.chk(r->>'outcome' = 'LOSS' AND r->'indicative_unrealized_usd' = 'null'::jsonb, 'T17b: closed view row');
  PERFORM pg_temp.chk(pg_temp.near((r->>'avg_exit_price')::numeric, (81200*0.4 + 78760.6*0.6), 1e-6), 'T17b: weighted avg exit');
  PERFORM pg_temp.chk(pg_temp.near((r->>'price_move_pct')::numeric, ((81200*0.4 + 78760.6*0.6)/80040 - 1)*100, 1e-9), 'T17b: price move');

  -- INTERNAL_ERROR in the last 24 h -> warning
  INSERT INTO public.telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss)
  VALUES ('T17b', 'ERRUSDT', 1, 'LONG', 100, 95);
  UPDATE public.paper_positions SET status_reason = 'INTERNAL_ERROR: test'
   WHERE signal_id = (SELECT id FROM public.telegram_signals WHERE scan_cycle_id = 'T17b');
  PERFORM pg_temp.chk((SELECT cardinality(internal_error_position_ids_24h) = 1 FROM public.paper_health_v), 'T17b: internal error listed');

  RAISE NOTICE 'T17b PASSED: view fields, indicative P&L, health warnings';
END $$;

ROLLBACK;
