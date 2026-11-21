-- =====================================================================
-- T06_timeout_data_unavailable — TIMEOUT at 72h, DATA_UNAVAILABLE
-- Spec: P-14 steps 8 and after-loop. Run in a TEST project/branch only (see tests/README.md).
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
  b timestamptz := date_trunc('hour', now()) - interval '80 hours';
  p public.paper_positions;
  q public.paper_positions;
  e public.paper_position_events;
  r jsonb;
BEGIN
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := pg_temp.sig('BTCUSDT','LONG',1, 80000,78800,81200,81600,82000, 40,40,20, 1, NULL, b + interval '14 minutes');
  FOR i IN 1..75 LOOP
    PERFORM pg_temp.candle('BTCUSDT', b + make_interval(hours => i), 80000, 80100, 79900, 80050);
  END LOOP;
  -- DATA_UNAVAILABLE: no candles at all, 100h old (> 72 + 24)
  q := pg_temp.sig('NODATAUSDT','LONG',1, 100,95,105,110,115, 40,40,20, 1, NULL,
                   date_trunc('hour', now()) - interval '100 hours' + interval '14 minutes');
  r := public.paper_evaluate_positions();

  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(p.status = 'CLOSED' AND p.exit_reason = 'TIMEOUT', 'T06: TIMEOUT expected, got ' || coalesce(p.exit_reason, p.status));
  PERFORM pg_temp.chk(p.last_evaluated_open_time = b + interval '72 hours', 'T06: closed in the candle where 72h elapse, cursor ' || p.last_evaluated_open_time);
  PERFORM pg_temp.chk(p.closed_at = b + interval '73 hours' - interval '1 millisecond', 'T06: closed_at');
  PERFORM pg_temp.chk((pg_temp.ev(p.id,'TIMEOUT')).fill_price = 80050 * 0.9995, 'T06: fill = close with stop slippage');
  PERFORM pg_temp.chk(pg_temp.near(p.duration_hours, 72 + 46/60.0, 0.001), 'T06: duration ' || p.duration_hours);

  q := pg_temp.pos(q.id);
  PERFORM pg_temp.chk(q.status = 'CLOSED' AND q.exit_reason = 'DATA_UNAVAILABLE', 'T06: DATA_UNAVAILABLE expected, got ' || coalesce(q.exit_reason, q.status));
  e := pg_temp.ev(q.id, 'DATA_UNAVAILABLE');
  PERFORM pg_temp.chk(e.level_price = q.entry_fill_price AND e.details ->> 'price_source' = 'entry_fill', 'T06: no candles -> entry_fill');

  -- last known close is used when an older candle exists; 90h old stays OPEN
  q := pg_temp.sig('OLDUSDT','LONG',1, 100,95,105,110,115, 40,40,20, 1, NULL,
                   date_trunc('hour', now()) - interval '100 hours' + interval '14 minutes');
  PERFORM pg_temp.candle('OLDUSDT', date_trunc('hour', now()) - interval '110 hours', 101, 102, 100, 101.5);
  p := pg_temp.sig('YOUNGUSDT','LONG',1, 100,95,105,110,115, 40,40,20, 1, NULL,
                   date_trunc('hour', now()) - interval '90 hours');
  r := public.paper_evaluate_positions();
  PERFORM pg_temp.chk((pg_temp.ev(q.id,'DATA_UNAVAILABLE')).level_price = 101.5, 'T06: last known close');
  PERFORM pg_temp.chk((pg_temp.pos(p.id)).status = 'OPEN', 'T06: 90h without data is still OPEN');

  RAISE NOTICE 'T06 PASSED: TIMEOUT at 72h, DATA_UNAVAILABLE';
END $$;

ROLLBACK;
