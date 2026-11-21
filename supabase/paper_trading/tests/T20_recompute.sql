-- =====================================================================
-- T20_recompute — recompute gives an identical result
-- Spec: P-21. Run in a TEST project/branch only (see tests/README.md).
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
  b timestamptz := date_trunc('hour', now()) - interval '80 hours';
  p public.paper_positions;
  q public.paper_positions;
  e public.paper_position_events;
  r jsonb;
  before jsonb;
  after jsonb;
  agg_before jsonb;
BEGIN
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := pg_temp.sig('BTCUSDT','LONG',1, 80000,78800,81200,81600,82000, 40,40,20, 1, NULL, b + interval '14 minutes');
  PERFORM pg_temp.candle('BTCUSDT', b + interval '1 hour',  80050, 81300, 79900, 81000);
  PERFORM pg_temp.candle('BTCUSDT', b + interval '2 hours', 80100, 80200, 80000, 80100);
  PERFORM pg_temp.candle('BTCUSDT', b + interval '4 hours', 80500, 80600, 78700, 78900);  -- after a gap
  r := public.paper_evaluate_positions();

  SELECT jsonb_agg(jsonb_build_array(event_type, tranche, candle_open_time, fill_price, qty, net_usd) ORDER BY id)
    INTO before FROM public.paper_position_events WHERE position_id = p.id;
  SELECT to_jsonb(x) - 'id' INTO agg_before
    FROM (SELECT status, exit_reason, exit_summary, remaining_pct, tp_hits, realized_gross_usd, fees_usd,
                 realized_net_usd, return_on_margin_pct, closed_at, duration_hours,
                 last_evaluated_open_time, has_data_gap, id
            FROM public.paper_positions WHERE id = p.id) x;
  PERFORM pg_temp.chk(agg_before->>'status' = 'CLOSED' AND (agg_before->>'has_data_gap')::boolean, 'T20: setup');

  r := public.paper_recompute_position(p.id, 'T20 test');
  q := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(q.status = 'OPEN' AND q.remaining_pct = 100 AND q.realized_net_usd = 0
                  AND q.last_evaluated_open_time IS NULL AND NOT q.has_data_gap, 'T20: reset');
  PERFORM pg_temp.chk((SELECT array_agg(event_type) FROM public.paper_position_events WHERE position_id = p.id) = ARRAY['OPENED'],
                      'T20: only OPENED remains');
  PERFORM pg_temp.chk((SELECT details->'recompute_log'->0->>'reason' FROM public.paper_position_events
                        WHERE position_id = p.id AND event_type = 'OPENED') = 'T20 test', 'T20: audit log in OPENED details');

  r := public.paper_evaluate_positions();
  SELECT jsonb_agg(jsonb_build_array(event_type, tranche, candle_open_time, fill_price, qty, net_usd) ORDER BY id)
    INTO after FROM public.paper_position_events WHERE position_id = p.id;
  PERFORM pg_temp.chk(after = before, 'T20: events differ after recompute: ' || after::text || ' vs ' || before::text);
  PERFORM pg_temp.chk((SELECT to_jsonb(x) - 'id'
                         FROM (SELECT status, exit_reason, exit_summary, remaining_pct, tp_hits, realized_gross_usd, fees_usd,
                                      realized_net_usd, return_on_margin_pct, closed_at, duration_hours,
                                      last_evaluated_open_time, has_data_gap, id
                                 FROM public.paper_positions WHERE id = p.id) x) = agg_before,
                      'T20: aggregates differ after recompute');

  -- guards
  BEGIN
    PERFORM public.paper_recompute_position((pg_temp.sig('BADUSDT','LONG',1, 100,101,105,110,115)).id);
    RAISE EXCEPTION 'T20: recompute of a REJECTED position must fail';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'T20:%' THEN RAISE; END IF;
  END;
  q := pg_temp.sig('BTCUSDT','LONG',1, 80000,78800,81200,81600,82000, 40,40,20, 1, NULL, b + interval '10 hours');
  BEGIN
    PERFORM public.paper_recompute_position(p.id);
    RAISE EXCEPTION 'T20: recompute must fail while the symbol has another OPEN position';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'T20:%' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'T20 PASSED: recompute gives an identical result';
END $$;

ROLLBACK;
