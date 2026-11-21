-- =====================================================================
-- T18_sizing — PERCENT_EQUITY margin and insufficient balance
-- Spec: P-09. Run in a TEST project/branch only (see tests/README.md).
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
  a public.paper_positions;
  p public.paper_positions;
BEGIN
  UPDATE public.paper_config SET sizing_mode = 'PERCENT_EQUITY', equity_pct = 5 WHERE id = 1;

  -- equity = 1000 -> margin 50
  a := pg_temp.sig('AUSDT','LONG',1, 100,95,105,110,115);
  PERFORM pg_temp.chk(a.margin_usd = 50, 'T18: 5% of 1000 must be 50, got ' || a.margin_usd);

  -- realised +200 on a CLOSED position -> equity 1200 -> margin 60
  UPDATE public.paper_positions SET status = 'CLOSED', remaining_pct = 0, realized_net_usd = 200,
         closed_at = now() WHERE id = a.id;
  p := pg_temp.sig('BUSDT','LONG',1, 100,95,105,110,115);
  PERFORM pg_temp.chk(p.margin_usd = 60, 'T18: 5% of 1200 must be 60, got ' || p.margin_usd);
  PERFORM pg_temp.chk(p.notional_usd = 60 AND p.leverage = 1, 'T18: notional = margin x L');

  -- FIXED 500: equity 1200, used 60 -> 500 ok, 500 ok (used 1060), next: free 140 -> skip
  UPDATE public.paper_config SET sizing_mode = 'FIXED_MARGIN', fixed_margin_usd = 500 WHERE id = 1;
  p := pg_temp.sig('CUSDT','LONG',1, 100,95,105,110,115);
  PERFORM pg_temp.chk(p.status = 'OPEN' AND p.margin_usd = 500, 'T18: C must open with 500');
  p := pg_temp.sig('DUSDT','LONG',1, 100,95,105,110,115);
  PERFORM pg_temp.chk(p.status = 'OPEN', 'T18: D must open (free 640)');
  p := pg_temp.sig('EUSDT','LONG',1, 100,95,105,110,115);
  PERFORM pg_temp.chk(p.status = 'SKIPPED' AND p.status_reason LIKE 'INSUFFICIENT_VIRTUAL_BALANCE%',
                      'T18: E must be SKIPPED INSUFFICIENT_VIRTUAL_BALANCE, got '
                      || p.status || ' ' || coalesce(p.status_reason,''));
  PERFORM pg_temp.chk(p.margin_usd IS NULL AND p.remaining_pct = 0, 'T18: skipped holds no margin');

  RAISE NOTICE 'T18 PASSED: PERCENT_EQUITY margin and insufficient balance';
END $$;

ROLLBACK;
