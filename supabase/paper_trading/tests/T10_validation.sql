-- =====================================================================
-- T10_validation — invalid levels, allocation, stale
-- Spec: P-08 steps 2-3. Run in a TEST project/branch only (see tests/README.md).
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
BEGIN
  p := pg_temp.sig('D1USDT','BUY',1, 100,95,105,110,115);
  PERFORM pg_temp.chk(p.status = 'REJECTED' AND p.status_reason LIKE 'INVALID_DIRECTION%', 'T10: direction');
  PERFORM pg_temp.chk(p.direction IS NULL, 'T10: invalid direction is stored as NULL');

  p := pg_temp.sig('L1USDT','LONG',1, 100,101,105,110,115);
  PERFORM pg_temp.chk(p.status = 'REJECTED' AND p.status_reason LIKE 'INVALID_LEVEL_ORDER%', 'T10: LONG SL above entry');
  p := pg_temp.sig('L2USDT','LONG',1, 100,95,99,110,115);
  PERFORM pg_temp.chk(p.status = 'REJECTED' AND p.status_reason LIKE 'INVALID_LEVEL_ORDER%', 'T10: LONG TP1 below entry');
  p := pg_temp.sig('L3USDT','LONG',1, 100,95,110,105,115);
  PERFORM pg_temp.chk(p.status = 'REJECTED' AND p.status_reason LIKE 'INVALID_LEVEL_ORDER%', 'T10: LONG TP2 < TP1');
  p := pg_temp.sig('S1USDT','SHORT',1, 100,105,95,97,90);
  PERFORM pg_temp.chk(p.status = 'REJECTED' AND p.status_reason LIKE 'INVALID_LEVEL_ORDER%', 'T10: SHORT TP2 > TP1');
  p := pg_temp.sig('Z1USDT','LONG',1, 100,95,NULL,110,115);
  PERFORM pg_temp.chk(p.status = 'REJECTED' AND p.status_reason LIKE 'INVALID_LEVELS%', 'T10: missing TP1');
  p := pg_temp.sig('Z2USDT','LONG',1, 100,0,105,110,115);
  PERFORM pg_temp.chk(p.status = 'REJECTED' AND p.status_reason LIKE 'INVALID_LEVELS%', 'T10: SL = 0');

  p := pg_temp.sig('A1USDT','LONG',1, 100,95,105,110,115, 40,40,10);
  PERFORM pg_temp.chk(p.status = 'REJECTED' AND p.status_reason LIKE 'INVALID_ALLOCATION%', 'T10: alloc sum 90');
  p := pg_temp.sig('A2USDT','LONG',1, 100,95,105,110,115, 40,40,20.4);
  PERFORM pg_temp.chk(p.status = 'OPEN', 'T10: alloc 100.4 is within tolerance');
  p := pg_temp.sig('A3USDT','LONG',1, 100,95,105,110,115, NULL,NULL,NULL);
  PERFORM pg_temp.chk(p.status = 'OPEN' AND p.status_reason = 'DEFAULT_ALLOCATION'
                  AND p.alloc1 = 40 AND p.alloc2 = 40 AND p.alloc3 = 20, 'T10: missing alloc -> 40/40/20');
  p := pg_temp.sig('A4USDT','LONG',1, 100,95,105,110,115, 60,40,NULL);
  PERFORM pg_temp.chk(p.status = 'OPEN' AND p.alloc3 = 0, 'T10: partial alloc 60/40/- sums to 100');

  p := pg_temp.sig('T2USDT','LONG',1, 100,95,105,NULL,NULL);
  PERFORM pg_temp.chk(p.status = 'OPEN' AND p.tp2 = 105 AND p.tp3 = 105, 'T10: missing TP2/TP3 -> previous level');

  p := pg_temp.sig('ST1USDT','LONG',1, 100,95,105,110,115, 40,40,20, 1, now() - interval '46 minutes');
  PERFORM pg_temp.chk(p.status = 'REJECTED' AND p.status_reason LIKE 'STALE_SIGNAL%', 'T10: 46 min -> stale');
  p := pg_temp.sig('ST2USDT','LONG',1, 100,95,105,110,115, 40,40,20, 1, now() - interval '44 minutes');
  PERFORM pg_temp.chk(p.status = 'OPEN', 'T10: 44 min is not stale');

  p := pg_temp.sig('TR4USDT','LONG',4, 100,95,105,110,115);
  PERFORM pg_temp.chk(p.status = 'REJECTED' AND p.status_reason LIKE 'NO_SLIPPAGE_FOR_TIER%', 'T10: tier 4 not configured');

  PERFORM pg_temp.chk(NOT EXISTS (SELECT 1 FROM public.paper_position_events e
                                    JOIN public.paper_positions q ON q.id = e.position_id
                                   WHERE q.status = 'REJECTED'), 'T10: REJECTED must have no events');
  PERFORM pg_temp.chk((SELECT count(*) FROM public.paper_positions WHERE status = 'REJECTED') = 10,
                      'T10: expected 10 REJECTED');

  RAISE NOTICE 'T10 PASSED: invalid levels, allocation, stale';
END $$;

ROLLBACK;
