-- =====================================================================
-- T09_duplicate_open — duplicate open position per symbol
-- Spec: P-08 step 4. Run in a TEST project/branch only (see tests/README.md).
-- Prerequisites: 001 … 004 (T23: 005, T24: 006). Ends with ROLLBACK; aborts on any mismatch.
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
  b public.paper_positions;
  c public.paper_positions;
  n int;
BEGIN
  a := pg_temp.sig('BTCUSDT','LONG',1, 80000,78800,81200,81600,82000);
  PERFORM pg_temp.chk(a.status = 'OPEN', 'T09: first signal must open');

  -- same symbol, opposite direction -> still a duplicate
  b := pg_temp.sig('BTCUSDT','SHORT',1, 80000,81200,78800,78400,78000);
  PERFORM pg_temp.chk(b.status = 'SKIPPED' AND b.status_reason = 'DUPLICATE_OPEN_POSITION'
                  AND b.related_position_id = a.id,
                      'T09: second signal must be SKIPPED DUPLICATE_OPEN_POSITION -> ' || a.id);
  PERFORM pg_temp.chk(NOT EXISTS (SELECT 1 FROM public.paper_position_events WHERE position_id = b.id),
                      'T09: SKIPPED must have no events');

  -- two signals for one symbol in ONE insert statement
  INSERT INTO public.telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss,
                                       tp1, tp2, tp3, tp1_allocation, tp2_allocation, tp3_allocation)
  VALUES ('T09-x1','ETHUSDT',1,'LONG',3000,2900,3100,3200,3300,40,40,20),
         ('T09-x2','ETHUSDT',1,'LONG',3000,2900,3100,3200,3300,40,40,20);
  SELECT count(*) INTO n FROM public.paper_positions WHERE symbol = 'ETHUSDT' AND status = 'OPEN';
  PERFORM pg_temp.chk(n = 1, 'T09: multi-row insert opened ' || n || ' ETH positions');
  SELECT count(*) INTO n FROM public.paper_positions
   WHERE symbol = 'ETHUSDT' AND status = 'SKIPPED' AND status_reason = 'DUPLICATE_OPEN_POSITION';
  PERFORM pg_temp.chk(n = 1, 'T09: multi-row insert: second row must be SKIPPED');

  -- after the first position closes, a new signal opens
  UPDATE public.paper_positions SET status = 'CLOSED', remaining_pct = 0, closed_at = now()
   WHERE id = a.id;
  c := pg_temp.sig('BTCUSDT','LONG',1, 80000,78800,81200,81600,82000);
  PERFORM pg_temp.chk(c.status = 'OPEN', 'T09: signal after close must open, got ' || c.status);

  -- 1:1 signals <-> positions
  PERFORM pg_temp.chk((SELECT count(*) FROM public.telegram_signals s
                        WHERE s.scan_cycle_id LIKE 'T%'
                          AND (SELECT count(*) FROM public.paper_positions p WHERE p.signal_id = s.id) <> 1) = 0,
                      'T09: every signal must have exactly one position');

  RAISE NOTICE 'T09 PASSED: duplicate open position per symbol';
END $$;

ROLLBACK;
