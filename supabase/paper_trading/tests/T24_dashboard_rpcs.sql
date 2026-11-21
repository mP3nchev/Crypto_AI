-- =====================================================================
-- T24_dashboard_rpcs — portfolio summary, month overview, symbols
-- Spec: P-22, P-24 (006_dashboard.sql). Run in a TEST project/branch only (see tests/README.md).
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
  s jsonb;
  d record;
  n int;
BEGIN
  -- helper: open a position and close it directly with a given net / close time
  CREATE OR REPLACE FUNCTION pg_temp.closed(p_symbol text, p_dir text, p_tier int,
                                            p_net numeric, p_closed timestamptz)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE p public.paper_positions;
  BEGIN
    IF p_dir = 'LONG' THEN
      p := pg_temp.sig(p_symbol, 'LONG', p_tier, 100,95,105,110,115, 40,40,20, 1, NULL, p_closed - interval '5 hours');
    ELSE
      p := pg_temp.sig(p_symbol, 'SHORT', p_tier, 100,105,95,90,85, 40,40,20, 1, NULL, p_closed - interval '5 hours');
    END IF;
    UPDATE public.paper_positions
       SET status = 'CLOSED', remaining_pct = 0, realized_net_usd = p_net, closed_at = p_closed,
           duration_hours = 5, exit_reason = 'TEST'
     WHERE id = p.id;
    RETURN p.id;
  END $f$;

  PERFORM pg_temp.closed('BTCUSDT', 'LONG',  1,  10,    '2026-11-05 10:00+00');
  PERFORM pg_temp.closed('ETHUSDT', 'SHORT', 2,  -5,    '2026-11-05 11:00+00');
  PERFORM pg_temp.closed('SOLUSDT', 'LONG',  1,   0.005,'2026-11-05 12:00+00');   -- BREAKEVEN
  PERFORM pg_temp.closed('XRPUSDT', 'LONG',  3,  20,    '2026-11-05 21:30+00');   -- 23:30 Sofia, same day
  PERFORM pg_temp.closed('ADAUSDT', 'LONG',  2,  -8,    '2026-11-05 23:30+00');   -- 01:30 Sofia, NEXT day
  p := pg_temp.sig('DOTUSDT','LONG',1, 100,95,105,110,115);                         -- stays OPEN
  p := pg_temp.sig('BADUSDT','LONG',1, 100,101,105,110,115, 40,40,20, 1, NULL, '2026-11-05 10:00+00');  -- REJECTED

  -- portfolio summary: equity is account level = 1000 + 17.005 (all closed)
  s := public.paper_portfolio_summary();
  PERFORM pg_temp.chk((s->>'equity_usd')::numeric = 1017.005 AND (s->>'realized_net_usd')::numeric = 17.005,
                      'T24: equity ' || s::text);
  PERFORM pg_temp.chk((s->>'equity_return_pct')::numeric = 1.7005, 'T24: equity return');
  PERFORM pg_temp.chk((s->>'open_positions')::int = 1 AND (s->>'open_margin_usd')::numeric = 50
                  AND (s->>'open_notional_usd')::numeric = 50, 'T24: open exposure');
  PERFORM pg_temp.chk(pg_temp.near((s->>'exposure_pct')::numeric, 50 / 1017.005 * 100, 1e-9), 'T24: exposure %');
  -- the CLOSED test positions were created "now" by the trigger -> 24h counts
  PERFORM pg_temp.chk((s->>'signals_24h')::int = 7 AND (s->>'opened_24h')::int = 6 AND (s->>'rejected_24h')::int = 1,
                      'T24: 24h counts ' || s::text);
  -- filters apply to open/24h, not to equity
  s := public.paper_portfolio_summary(p_direction => 'SHORT');
  PERFORM pg_temp.chk((s->>'equity_usd')::numeric = 1017.005 AND (s->>'open_positions')::int = 0
                  AND s->'indicative_unrealized_pct' = 'null'::jsonb, 'T24: filtered summary');

  -- month overview
  s := public.paper_month_overview('2026-11-17');
  PERFORM pg_temp.chk(s->>'month' = '2026-11-01' AND (s->'stats'->>'trades')::int = 5, 'T24: month stats');
  PERFORM pg_temp.chk((s->>'trading_days')::int = 2 AND (s->>'green_days')::int = 1 AND (s->>'red_days')::int = 1,
                      'T24: green/red days ' || s::text);
  PERFORM pg_temp.chk((s->>'best_day_net_usd')::numeric = 25.005 AND s->>'best_day' = '2026-11-05'
                  AND (s->>'worst_day_net_usd')::numeric = -8 AND s->>'worst_day' = '2026-11-06'
                  AND (s->>'max_abs_day_net_usd')::numeric = 25.005, 'T24: best/worst');
  s := public.paper_month_overview('2026-10-01');
  PERFORM pg_temp.chk((s->>'trading_days')::int = 0 AND s->'best_day' = 'null'::jsonb
                  AND (s->>'max_abs_day_net_usd')::numeric = 0, 'T24: empty month');

  -- symbols
  PERFORM pg_temp.chk((SELECT count(*) FROM public.paper_symbols()) = 7, 'T24: symbol count');
  PERFORM pg_temp.chk((SELECT category FROM public.paper_symbols() WHERE symbol = 'BTCUSDT') = 'BTC', 'T24: symbol category');

  RAISE NOTICE 'T24 PASSED: portfolio summary, month overview, symbols';
END $$;

ROLLBACK;
