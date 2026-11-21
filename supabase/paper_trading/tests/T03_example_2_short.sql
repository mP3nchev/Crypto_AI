-- =====================================================================
-- T03_example_2_short — Example 2: SHORT, all TPs
-- Spec: P-14, P-15, P-16. Run in a TEST project/branch only (see tests/README.md).
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
  UPDATE public.paper_config SET leverage_override = 3 WHERE id = 1;
  p := pg_temp.sig('XYZUSDT','SHORT',3, 100,104,97,95,92, 50,35,15, 1, NULL, b + interval '14 minutes');
  PERFORM pg_temp.candle('XYZUSDT', b + interval '1 hour',  99.9, 100.5, 96.9, 97.5);
  PERFORM pg_temp.candle('XYZUSDT', b + interval '2 hours', 97.5, 98.0, 94.9, 95.5);
  PERFORM pg_temp.candle('XYZUSDT', b + interval '3 hours', 95.5, 96.0, 91.9, 92.5);
  r := public.paper_evaluate_positions();
  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(p.status = 'CLOSED' AND p.exit_reason = 'TP3' AND p.tp_hits = 3, 'T03: closed by TP3');
  PERFORM pg_temp.chk(pg_temp.near((pg_temp.ev(p.id,'TP1')).net_usd, 2.02), 'T03: TP1 net ' || (pg_temp.ev(p.id,'TP1')).net_usd);
  PERFORM pg_temp.chk(pg_temp.near((pg_temp.ev(p.id,'TP2')).net_usd, 2.47), 'T03: TP2 net ' || (pg_temp.ev(p.id,'TP2')).net_usd);
  PERFORM pg_temp.chk(pg_temp.near((pg_temp.ev(p.id,'TP3')).net_usd, 1.73), 'T03: TP3 net ' || (pg_temp.ev(p.id,'TP3')).net_usd);
  PERFORM pg_temp.chk(pg_temp.near(p.realized_net_usd, 6.23), 'T03: net ' || p.realized_net_usd || ' expected 6.23');
  PERFORM pg_temp.chk(pg_temp.near(p.return_on_margin_pct, 12.45), 'T03: ROM ' || p.return_on_margin_pct);
  PERFORM pg_temp.chk(p.exit_summary = 'TP1+TP2+TP3' AND p.remaining_pct = 0, 'T03: summary');
  PERFORM pg_temp.chk(pg_temp.near(p.liquidation_price, 132.57) AND NOT p.stop_capped_by_liquidation, 'T03: liquidation 132.57, not capped');

  RAISE NOTICE 'T03 PASSED: Example 2: SHORT, all TPs';
END $$;

ROLLBACK;
