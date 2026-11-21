-- =====================================================================
-- T00c_open_formulas — open-time formulas, leverage clamp, category, eval start
-- Spec: P-09, P-10. Run in a TEST project/branch only (see tests/README.md).
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
  e public.paper_position_events;
BEGIN
  -- Example 1 (P-16): LONG, Tier 1, margin 50, L = 5
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := pg_temp.sig('BTCUSDT','LONG',1, 80000,78800,81200,81600,82000,
                   40,40,20, 1, NULL, '2026-11-21 10:14:00+00');
  PERFORM pg_temp.chk(p.status = 'OPEN', 'T00c: ex1 not OPEN: ' || coalesce(p.status_reason,''));
  PERFORM pg_temp.chk(p.entry_fill_price = 80040, 'T00c: ex1 entry_fill ' || p.entry_fill_price);
  PERFORM pg_temp.chk(p.leverage = 5 AND p.margin_usd = 50 AND p.notional_usd = 250, 'T00c: ex1 sizing');
  PERFORM pg_temp.chk(abs(p.quantity - 250/80040.0) < 1e-12, 'T00c: ex1 quantity ' || p.quantity);
  PERFORM pg_temp.chk(abs(p.liquidation_price - 64432.2) < 0.01, 'T00c: ex1 liq ' || p.liquidation_price);
  PERFORM pg_temp.chk(p.effective_stop = 78800 AND NOT p.stop_capped_by_liquidation, 'T00c: ex1 stop');
  PERFORM pg_temp.chk(p.category = 'BTC', 'T00c: ex1 category ' || p.category);
  PERFORM pg_temp.chk(p.opened_at = '2026-11-21 10:14:00+00'
                  AND p.eval_start_open_time = '2026-11-21 11:00:00+00',
                      'T00c: eval_start must be the next full hour (T13 rule), got ' || p.eval_start_open_time);
  PERFORM pg_temp.chk(p.last_evaluated_open_time IS NULL AND p.remaining_pct = 100 AND p.tp_hits = 0,
                      'T00c: ex1 initial aggregates');
  PERFORM pg_temp.chk((p.config_snapshot ->> 'leverage_override')::int = 5, 'T00c: config_snapshot');

  SELECT * INTO e FROM public.paper_position_events WHERE position_id = p.id;
  PERFORM pg_temp.chk(e.event_type = 'OPENED' AND e.fill_price = 80040 AND e.pct_of_position = 100,
                      'T00c: OPENED event');
  PERFORM pg_temp.chk((SELECT count(*) FROM public.paper_position_events WHERE position_id = p.id) = 1,
                      'T00c: exactly one event at open');
  PERFORM pg_temp.chk(abs((e.details -> 'tranche_qty' ->> 0)::numeric - p.quantity * 0.4) < 1e-12,
                      'T00c: tranche 1 qty');

  -- Example 2 (P-16): SHORT, Tier 3, L = 3 -> liquidation 132.57, not capped
  UPDATE public.paper_config SET leverage_override = 3 WHERE id = 1;
  p := pg_temp.sig('XYZUSDT','SHORT',3, 100,104,97,95,92, 50,35,15);
  PERFORM pg_temp.chk(p.status = 'OPEN', 'T00c: ex2 not OPEN: ' || coalesce(p.status_reason,''));
  PERFORM pg_temp.chk(p.entry_fill_price = 99.8 AND p.notional_usd = 150, 'T00c: ex2 fill/notional');
  PERFORM pg_temp.chk(abs(p.liquidation_price - 132.57) < 0.01, 'T00c: ex2 liq ' || p.liquidation_price);
  PERFORM pg_temp.chk(p.effective_stop = 104 AND NOT p.stop_capped_by_liquidation, 'T00c: ex2 stop');
  PERFORM pg_temp.chk(p.category = 'OTHER', 'T00c: unknown symbol must be OTHER');

  -- T08 open part: L = 20, SL beyond liquidation -> capped
  UPDATE public.paper_config SET max_leverage = 20, leverage_override = 20 WHERE id = 1;
  p := pg_temp.sig('LIQUSDT','LONG',1, 100,90,110,115,120);
  PERFORM pg_temp.chk(p.leverage = 20, 'T00c: L=20');
  PERFORM pg_temp.chk(abs(p.liquidation_price - 100.05 * (1 - 0.05 + 0.005)) < 1e-9, 'T00c: L20 liq');
  PERFORM pg_temp.chk(p.stop_capped_by_liquidation AND p.effective_stop = p.liquidation_price,
                      'T00c: L20 stop must be capped by liquidation');
  p := pg_temp.sig('LIQSUSDT','SHORT',1, 100,110,90,85,80);
  PERFORM pg_temp.chk(p.stop_capped_by_liquidation AND p.effective_stop = p.liquidation_price
                  AND p.effective_stop < 110, 'T00c: SHORT L20 capped');

  -- leverage clamp
  UPDATE public.paper_config SET max_leverage = 10, leverage_override = 50 WHERE id = 1;
  p := pg_temp.sig('CL1USDT','LONG',2, 10,9,11,12,13);
  PERFORM pg_temp.chk(p.leverage = 10, 'T00c: override above max must clamp to 10, got ' || p.leverage);
  UPDATE public.paper_config SET leverage_override = NULL WHERE id = 1;
  p := pg_temp.sig('CL2USDT','LONG',2, 10,9,11,12,13, 40,40,20, 0);
  PERFORM pg_temp.chk(p.leverage = 1, 'T00c: signal leverage 0 must clamp to 1, got ' || p.leverage);
  p := pg_temp.sig('CL3USDT','LONG',2, 10,9,11,12,13, 40,40,20, 3);
  PERFORM pg_temp.chk(p.leverage = 3 AND p.entry_fill_price = 10.01, 'T00c: signal leverage 3 / tier-2 slippage');

  RAISE NOTICE 'T00c PASSED: open-time formulas, leverage clamp, category, eval start';
END $$;

ROLLBACK;
