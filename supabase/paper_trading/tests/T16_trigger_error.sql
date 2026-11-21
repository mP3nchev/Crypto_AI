-- =====================================================================
-- T16_trigger_error — trigger error never blocks the signal
-- Spec: P-08 step 8. Run in a TEST project/branch only (see tests/README.md).
-- Prerequisites: 001, 002, 003. Ends with ROLLBACK; aborts on any mismatch.
-- =====================================================================
BEGIN;

-- ---- shared test prelude (identical in every Txx file) --------------------
-- Clean slate inside this transaction (ROLLBACK at the end restores everything).
DELETE FROM public.paper_position_events;
DELETE FROM public.paper_positions;
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
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_sig int;
  p public.paper_positions;
BEGIN
  -- force an error inside the engine (restored by ROLLBACK)
  EXECUTE $x$
    CREATE OR REPLACE FUNCTION public.paper_open_position(p_sig public.telegram_signals)
    RETURNS bigint LANGUAGE plpgsql AS $b$
    BEGIN
      RAISE EXCEPTION 'forced test failure';
    END $b$;
  $x$;

  INSERT INTO public.telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss, tp1)
  VALUES ('T16', 'ERRUSDT', 1, 'LONG', 100, 95, 105)
  RETURNING id INTO v_sig;

  PERFORM pg_temp.chk(EXISTS (SELECT 1 FROM public.telegram_signals WHERE id = v_sig),
                      'T16: signal must be saved');
  SELECT * INTO p FROM public.paper_positions WHERE signal_id = v_sig;
  PERFORM pg_temp.chk(p.status = 'REJECTED' AND p.status_reason LIKE 'INTERNAL_ERROR: forced test failure%',
                      'T16: position must be REJECTED INTERNAL_ERROR, got ' || coalesce(p.status,'none'));
  PERFORM pg_temp.chk(EXISTS (SELECT 1 FROM public.paper_position_events
                               WHERE position_id = p.id AND event_type = 'ERROR'
                                 AND details ->> 'message' = 'forced test failure'),
                      'T16: ERROR event missing');

  RAISE NOTICE 'T16 PASSED: trigger error never blocks the signal';
END $$;

ROLLBACK;
