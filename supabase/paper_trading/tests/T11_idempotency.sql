-- =====================================================================
-- T11_idempotency — re-running evaluate / ingest changes nothing
-- Spec: P-13, P-14, P-28. Run in a TEST project/branch only (see tests/README.md).
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
  n_ev bigint;
  v_net numeric;
  n_c bigint;
  bad public.paper_positions;
BEGIN
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := pg_temp.sig('BTCUSDT','LONG',1, 80000,78800,81200,81600,82000, 40,40,20, 1, NULL, b + interval '14 minutes');
  r := public.paper_ingest_candles(jsonb_build_array(
         jsonb_build_object('symbol','BTCUSDT','open_time', b + interval '1 hour',
                            'close_time', b + interval '2 hours' - interval '1 millisecond',
                            'open','80050','high','81300','low','79900','close','81000','volume','10'),
         jsonb_build_object('symbol','BTCUSDT','open_time', b + interval '2 hours',
                            'close_time', b + interval '3 hours' - interval '1 millisecond',
                            'open',80500,'high',80600,'low',78700,'close',78900,'volume',10),
         jsonb_build_object('symbol','BTCUSDT','open_time', b + interval '2 hours',
                            'close_time', b + interval '3 hours' - interval '1 millisecond',
                            'open',80500,'high',80600,'low',78700,'close',78900,'volume',10),
         jsonb_build_object('symbol','BTCUSDT','open_time', b + interval '3 hours',
                            'close_time', b + interval '4 hours' - interval '1 millisecond',
                            'open',80500,'high',80000,'low',78700,'close',78900,'volume',10)));  -- invalid: high < open
  PERFORM pg_temp.chk((r->>'received')::int = 4 AND (r->>'valid')::int = 2 AND (r->>'inserted')::int = 2,
                      'T11: first ingest ' || r::text);
  r := public.paper_ingest_candles((SELECT jsonb_agg(to_jsonb(pc) - 'ingested_at') FROM public.paper_candles pc));
  PERFORM pg_temp.chk((r->>'inserted')::int = 0 AND (r->>'updated')::int = 0, 'T11: re-ingest must change nothing ' || r::text);
  SELECT count(*) INTO n_c FROM public.paper_candles;
  PERFORM pg_temp.chk(n_c = 2, 'T11: candle count');

  r := public.paper_evaluate_positions();
  SELECT count(*) INTO n_ev FROM public.paper_position_events;
  v_net := (pg_temp.pos(p.id)).realized_net_usd;
  r := public.paper_evaluate_positions();
  PERFORM pg_temp.chk((SELECT count(*) FROM public.paper_position_events) = n_ev, 'T11: second evaluate added events');
  PERFORM pg_temp.chk((pg_temp.pos(p.id)).realized_net_usd = v_net, 'T11: second evaluate changed P&L');
  PERFORM pg_temp.chk((r->>'candles_used')::int = 0 AND jsonb_array_length(r->'events') = 0, 'T11: nothing to do on re-run');

  -- corrected candle data is updated, not duplicated
  r := public.paper_ingest_candles(jsonb_build_array(jsonb_build_object('symbol','btcusdt',
         'open_time', b + interval '1 hour', 'close_time', b + interval '2 hours' - interval '1 millisecond',
         'open',80050,'high',81300,'low',79900,'close',81001,'volume',10)));
  PERFORM pg_temp.chk((r->>'updated')::int = 1 AND (SELECT count(*) FROM public.paper_candles) = 2, 'T11: correction');

  -- one broken position does not stop the others; failed symbols -> PARTIAL
  q := pg_temp.sig('OKUSDT','LONG',1, 100,95,105,110,115, 40,40,20, 1, NULL, b + interval '14 minutes');
  bad := pg_temp.sig('BADUSDT','LONG',1, 100,95,105,110,115, 40,40,20, 1, NULL, b + interval '14 minutes');
  UPDATE public.paper_positions SET config_snapshot = '{}'::jsonb WHERE id = bad.id;
  PERFORM pg_temp.candle('OKUSDT',  b + interval '1 hour', 100, 105.5, 99, 105);
  PERFORM pg_temp.candle('BADUSDT', b + interval '1 hour', 100, 105.5, 99, 105);
  r := public.paper_evaluate_positions(now(), ARRAY['FAILUSDT']);
  PERFORM pg_temp.chk(r->>'status' = 'PARTIAL', 'T11: status PARTIAL expected, got ' || (r->>'status'));
  PERFORM pg_temp.chk((pg_temp.pos(q.id)).tp_hits = 1, 'T11: healthy position still evaluated');
  PERFORM pg_temp.chk((pg_temp.ev(bad.id,'ERROR')).id IS NOT NULL AND (pg_temp.pos(bad.id)).last_evaluated_open_time IS NULL,
                      'T11: broken position gets ERROR event and keeps its cursor');
  PERFORM pg_temp.chk((SELECT error FROM public.paper_monitor_runs ORDER BY id DESC LIMIT 1) LIKE '%FAILUSDT%', 'T11: run error lists failed symbols');

  RAISE NOTICE 'T11 PASSED: re-running evaluate / ingest changes nothing';
END $$;

ROLLBACK;
