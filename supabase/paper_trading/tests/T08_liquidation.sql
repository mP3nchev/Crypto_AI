-- =====================================================================
-- T08_liquidation — L=20, SL beyond liquidation
-- Spec: P-10, P-14, P-15. Run in a TEST project/branch only (see tests/README.md).
-- Prerequisites: 001, 002, 003 (incl. Part 4). Ends with ROLLBACK; aborts on any mismatch.
-- =====================================================================
BEGIN;

-- ---- shared test prelude (identical in every Txx file) --------------------
-- Clean slate inside this transaction (ROLLBACK at the end restores everything).
DELETE FROM public.paper_position_events;
DELETE FROM public.paper_positions;
DELETE FROM public.paper_candles;
DELETE FROM public.paper_monitor_runs;
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
  UPDATE public.paper_config SET max_leverage = 20, leverage_override = 20 WHERE id = 1;
  -- (a) whole position liquidated
  p := pg_temp.sig('LIQUSDT','LONG',1, 100,90,110,115,120, 40,40,20, 1, NULL, b + interval '14 minutes');
  PERFORM pg_temp.chk(p.stop_capped_by_liquidation, 'T08: stop_capped_by_liquidation');
  PERFORM pg_temp.candle('LIQUSDT', b + interval '1 hour', 100.2, 100.5, 95, 96);
  -- (b) TP1 first, then liquidation of the remaining 60%
  q := pg_temp.sig('LIQ2USDT','LONG',1, 100,90,110,115,120, 40,40,20, 1, NULL, b + interval '14 minutes');
  PERFORM pg_temp.candle('LIQ2USDT', b + interval '1 hour',  100.2, 110.5, 100, 110);
  PERFORM pg_temp.candle('LIQ2USDT', b + interval '2 hours', 109, 109.5, 95, 96);
  r := public.paper_evaluate_positions();

  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(p.exit_reason = 'LIQUIDATION', 'T08a: LIQUIDATION expected, got ' || coalesce(p.exit_reason,''));
  PERFORM pg_temp.chk(p.realized_net_usd = -50, 'T08a: net must be -margin (-50), got ' || p.realized_net_usd);
  PERFORM pg_temp.chk((pg_temp.ev(p.id,'LIQUIDATION')).level_price = p.liquidation_price, 'T08a: level = liquidation price');

  q := pg_temp.pos(q.id);
  PERFORM pg_temp.chk(q.exit_summary = 'TP1+LIQUIDATION', 'T08b: summary ' || coalesce(q.exit_summary,''));
  PERFORM pg_temp.chk((pg_temp.ev(q.id,'LIQUIDATION')).net_usd = -30, 'T08b: liquidation of 60% loses 30');
  PERFORM pg_temp.chk(q.realized_net_usd = (pg_temp.ev(q.id,'TP1')).net_usd - 30, 'T08b: total');

  RAISE NOTICE 'T08 PASSED: L=20, SL beyond liquidation';
END $$;

ROLLBACK;
