-- =====================================================================
-- T13_partial_first_hour — signal at 10:14: the 10:00 candle is not evaluated
-- Spec: P-10, P-14. Run in a TEST project/branch only (see tests/README.md).
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
  p := pg_temp.sig('BTCUSDT','LONG',1, 80000,78800,81200,81600,82000, 40,40,20, 1, NULL,
                   b + interval '10 hours 14 minutes');
  PERFORM pg_temp.candle('BTCUSDT', b + interval '10 hours', 80000, 81300, 79900, 81000);  -- TP1, partial hour
  PERFORM pg_temp.candle('BTCUSDT', b + interval '11 hours', 80000, 80100, 79900, 80050);  -- neutral
  r := public.paper_evaluate_positions();
  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(p.tp_hits = 0, 'T13: TP in the partial first hour must not count');
  PERFORM pg_temp.chk(p.eval_start_open_time = b + interval '11 hours'
                  AND p.last_evaluated_open_time = b + interval '11 hours', 'T13: evaluation starts at 11:00');
  PERFORM pg_temp.chk((r->>'candles_used')::int = 1, 'T13: exactly one candle used');

  RAISE NOTICE 'T13 PASSED: signal at 10:14: the 10:00 candle is not evaluated';
END $$;

ROLLBACK;
