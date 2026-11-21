-- =====================================================================
-- T23_security — RLS and privileges per role (anon / authenticated / service_role)
-- Spec: P-23. Run in a TEST project/branch only (see tests/README.md).
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
  p public.paper_positions;
  v_err text;
  v_n bigint;
  v_stats jsonb;
  v_sig int;
  v_results jsonb := '{}'::jsonb;
BEGIN
  p := pg_temp.sig('SECUSDT','LONG',1, 100,95,105,110,115);   -- as the owner (postgres)

  -- ---------- anon: no access at all ----------
  EXECUTE 'SET LOCAL ROLE anon';
  BEGIN PERFORM count(*) FROM public.paper_positions; v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('anon_select_positions', v_err);
  BEGIN PERFORM count(*) FROM public.telegram_signals; v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('anon_select_signals', v_err);
  BEGIN
    INSERT INTO public.telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss)
    VALUES ('T23-anon', 'ANONUSDT', 1, 'LONG', 100, 95);
    v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('anon_insert_signal', v_err);
  BEGIN PERFORM public.paper_stats(); v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('anon_stats', v_err);
  BEGIN PERFORM * FROM public.paper_positions_v; v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('anon_view', v_err);
  EXECUTE 'RESET ROLE';

  -- ---------- authenticated: read only ----------
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN SELECT count(*) INTO v_n FROM public.paper_positions_v; v_err := 'ok:' || v_n;
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('auth_view', v_err);
  BEGIN v_stats := public.paper_stats(); v_err := 'ok:' || (v_stats->>'open_positions');
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('auth_stats', v_err);
  BEGIN PERFORM * FROM public.paper_health_v; v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('auth_health', v_err);
  BEGIN
    INSERT INTO public.telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss)
    VALUES ('T23-auth', 'AUTHUSDT', 1, 'LONG', 100, 95);
    v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('auth_insert_signal', v_err);
  BEGIN UPDATE public.paper_config SET enabled = false WHERE id = 1; v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('auth_update_config', v_err);
  BEGIN DELETE FROM public.paper_position_events; v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('auth_delete_events', v_err);
  BEGIN PERFORM public.paper_evaluate_positions(); v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('auth_evaluate', v_err);
  BEGIN PERFORM public.paper_recompute_position(p.id); v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('auth_recompute', v_err);
  EXECUTE 'RESET ROLE';

  -- ---------- service_role: N8N writes, trigger opens the position ----------
  EXECUTE 'SET LOCAL ROLE service_role';
  BEGIN
    INSERT INTO public.telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss,
                                         tp1, tp2, tp3, tp1_allocation, tp2_allocation, tp3_allocation)
    VALUES ('T23-svc', 'SVCUSDT', 1, 'LONG', 100, 95, 105, 110, 115, 40, 40, 20)
    RETURNING id INTO v_sig;
    v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('svc_insert_signal', v_err);
  BEGIN PERFORM public.paper_evaluate_positions(); v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('svc_evaluate', v_err);
  BEGIN PERFORM public.paper_ingest_candles('[]'::jsonb); PERFORM public.paper_get_monitor_targets(); v_err := 'ok';
  EXCEPTION WHEN insufficient_privilege THEN v_err := 'denied'; END;
  v_results := v_results || jsonb_build_object('svc_monitor_rpcs', v_err);
  EXECUTE 'RESET ROLE';

  PERFORM pg_temp.chk(v_results = jsonb_build_object(
      'anon_select_positions', 'denied', 'anon_select_signals', 'denied',
      'anon_insert_signal', 'denied', 'anon_stats', 'denied', 'anon_view', 'denied',
      'auth_view', 'ok:1', 'auth_stats', 'ok:1', 'auth_health', 'ok',
      'auth_insert_signal', 'denied', 'auth_update_config', 'denied',
      'auth_delete_events', 'denied', 'auth_evaluate', 'denied', 'auth_recompute', 'denied',
      'svc_insert_signal', 'ok', 'svc_evaluate', 'ok', 'svc_monitor_rpcs', 'ok'),
    'T23: unexpected access matrix: ' || v_results::text);
  PERFORM pg_temp.chk((SELECT status FROM public.paper_positions WHERE signal_id = v_sig) = 'OPEN',
                      'T23: service_role insert must open a position via the trigger');

  RAISE NOTICE 'T23 PASSED: RLS and privileges per role (anon / authenticated / service_role)';
END $$;

ROLLBACK;
