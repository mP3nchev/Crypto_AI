-- =====================================================================
-- T01_example_1a — Example 1a: LONG TP1 then SL
-- Spec: P-14, P-15, P-16. Run in a TEST project/branch only (see tests/README.md).
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
  PERFORM pg_temp.candle('BTCUSDT', b + interval '1 hour', 80050, 81300, 79900, 81000);  -- TP1
  PERFORM pg_temp.candle('BTCUSDT', b + interval '2 hours', 80500, 80600, 78700, 78900); -- SL
  r := public.paper_evaluate_positions();
  p := pg_temp.pos(p.id);

  PERFORM pg_temp.chk(p.status = 'CLOSED' AND p.exit_reason = 'SL', 'T01: must be CLOSED by SL, got ' || p.status || ' ' || coalesce(p.exit_reason,''));
  PERFORM pg_temp.chk(pg_temp.near(p.realized_net_usd, -1.22), 'T01: net ' || p.realized_net_usd || ' expected -1.22');
  PERFORM pg_temp.chk(pg_temp.near(p.return_on_margin_pct, -2.45), 'T01: ROM ' || p.return_on_margin_pct || ' expected -2.45');
  PERFORM pg_temp.chk(p.exit_summary = 'TP1+SL', 'T01: exit_summary ' || coalesce(p.exit_summary,''));
  PERFORM pg_temp.chk(pg_temp.exits(p.id) = 2, 'T01: expected 2 exit events');
  e := pg_temp.ev(p.id, 'TP1');
  PERFORM pg_temp.chk(pg_temp.near(e.net_usd, 1.34) AND e.fill_price = 81200 AND e.pct_of_position = 40, 'T01: TP1 tranche ' || e.net_usd);
  e := pg_temp.ev(p.id, 'SL');
  PERFORM pg_temp.chk(e.fill_price = 78760.6, 'T01: SL fill ' || e.fill_price || ' expected 78760.6');
  PERFORM pg_temp.chk(pg_temp.near(e.net_usd, -2.56) AND e.pct_of_position = 60, 'T01: SL net ' || e.net_usd);
  PERFORM pg_temp.chk(p.remaining_pct = 0 AND p.tp_hits = 1, 'T01: aggregates');
  PERFORM pg_temp.chk(pg_temp.near(p.realized_gross_usd - p.fees_usd, p.realized_net_usd, 1e-9), 'T01: gross - fees = net');
  PERFORM pg_temp.chk(p.closed_at = b + interval '3 hours' - interval '1 millisecond', 'T01: closed_at = SL candle close_time');
  PERFORM pg_temp.chk((r ->> 'closed')::int = 1 AND jsonb_array_length(r -> 'events') = 2 AND r ->> 'status' = 'OK', 'T01: result json ' || r::text);
  PERFORM pg_temp.chk((SELECT status FROM public.paper_monitor_runs ORDER BY id DESC LIMIT 1) = 'OK', 'T01: run row');

  RAISE NOTICE 'T01 PASSED: Example 1a: LONG TP1 then SL';
END $$;

ROLLBACK;
