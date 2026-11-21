# Generates the self-contained Txx_*.sql files (T00c, T01-T19) with a shared prelude.
# Usage: python3 tests/tools/generate_tests.py   (T00 and T00b are hand-written)
import os
D=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
PRE='''BEGIN;

-- ---- shared test prelude (identical in every Txx file) --------------------
-- Clean slate inside this transaction (ROLLBACK at the end restores everything).
DELETE FROM public.paper_position_events;
DELETE FROM public.paper_positions;
DELETE FROM public.paper_candles;
DELETE FROM public.paper_monitor_runs;
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
'''
def write(name, part, title, body):
    hdr=f'''-- =====================================================================
-- {name} — {title}
-- Spec: {part}. Run in a TEST project/branch only (see tests/README.md).
-- Prerequisites: 001, 002, 003 (incl. Part 4). Ends with ROLLBACK; aborts on any mismatch.
-- =====================================================================
'''
    open(os.path.join(D,name+'.sql'),'w').write(hdr+PRE+'\nDO $$\n'+body.strip('\n')+f"\n\n  RAISE NOTICE '{name.split('_')[0]} PASSED: {title}';\nEND $$;\n\nROLLBACK;\n")

write('T00c_open_formulas','P-09, P-10','open-time formulas, leverage clamp, category, eval start', r'''
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
''')

write('T09_duplicate_open','P-08 step 4','duplicate open position per symbol', r'''
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
''')

write('T10_validation','P-08 steps 2-3','invalid levels, allocation, stale', r'''
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
''')

write('T16_trigger_error','P-08 step 8','trigger error never blocks the signal', r'''
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
''')

write('T18_sizing','P-09','PERCENT_EQUITY margin and insufficient balance', r'''
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
''')

write('T19_max_open','P-08 steps 1, 5','max open positions and global switch', r'''
DECLARE
  p public.paper_positions;
BEGIN
  UPDATE public.paper_config SET max_open_positions = 2 WHERE id = 1;
  p := pg_temp.sig('M1USDT','LONG',1, 100,95,105,110,115);
  PERFORM pg_temp.chk(p.status = 'OPEN', 'T19: 1st opens');
  p := pg_temp.sig('M2USDT','SHORT',2, 100,105,95,90,85);
  PERFORM pg_temp.chk(p.status = 'OPEN', 'T19: 2nd opens');
  p := pg_temp.sig('M3USDT','LONG',1, 100,95,105,110,115);
  PERFORM pg_temp.chk(p.status = 'SKIPPED' AND p.status_reason LIKE 'MAX_OPEN_POSITIONS%',
                      'T19: 3rd must be SKIPPED MAX_OPEN_POSITIONS, got ' || p.status);

  -- global switch off -> SKIPPED PAPER_DISABLED (checked before everything else)
  UPDATE public.paper_config SET enabled = false WHERE id = 1;
  p := pg_temp.sig('M4USDT','BUY',1, 100,95,105,110,115);
  PERFORM pg_temp.chk(p.status = 'SKIPPED' AND p.status_reason = 'PAPER_DISABLED',
                      'T19: disabled must SKIP with PAPER_DISABLED');
''')

# ======================= PART 4 =======================
EX1 = "pg_temp.sig('BTCUSDT','LONG',1, 80000,78800,81200,81600,82000, 40,40,20, 1, NULL, b + interval '14 minutes')"
DECL = """DECLARE
  b timestamptz := date_trunc('hour', now()) - interval '80 hours';
  p public.paper_positions;
  q public.paper_positions;
  e public.paper_position_events;
  r jsonb;
BEGIN"""

write('T01_example_1a','P-14, P-15, P-16','Example 1a: LONG TP1 then SL', DECL + f"""
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := {EX1};
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
""")

write('T02_ambiguous_candle','P-14 step 4, P-16','Example 1b: ambiguous candle -> SL first', DECL + f"""
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := {EX1};
  PERFORM pg_temp.candle('BTCUSDT', b + interval '1 hour', 80000, 81300, 78700, 79000);
  r := public.paper_evaluate_positions();
  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(p.status = 'CLOSED' AND p.exit_reason = 'SL' AND p.tp_hits = 0, 'T02: SL must win, TP1 not counted');
  PERFORM pg_temp.chk(pg_temp.near(p.realized_net_usd, -4.27), 'T02: net ' || p.realized_net_usd || ' expected -4.27');
  PERFORM pg_temp.chk(pg_temp.exits(p.id) = 1 AND (pg_temp.ev(p.id, 'SL')).pct_of_position = 100, 'T02: only one SL event for 100%');
  PERFORM pg_temp.chk(p.exit_summary = 'SL', 'T02: summary');
""")

write('T03_example_2_short','P-14, P-15, P-16','Example 2: SHORT, all TPs', DECL + """
  UPDATE public.paper_config SET leverage_override = 3 WHERE id = 1;
  p := pg_temp.sig('XYZUSDT','SHORT',3, 100,104,97,95,92, 50,35,15, 1, NULL, b + interval '14 minutes');
  PERFORM pg_temp.candle('XYZUSDT', b + interval '1 hour',  99.9, 100.5, 96.9, 97.5);
  PERFORM pg_temp.candle('XYZUSDT', b + interval '2 hours', 97.5, 98.0, 94.9, 95.5);
  PERFORM pg_temp.candle('XYZUSDT', b + interval '3 hours', 95.5, 96.0, 91.9, 92.5);
  r := public.paper_evaluate_positions();
  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(p.status = 'CLOSED' AND p.exit_reason = 'TP3' AND p.tp_hits = 3, 'T03: closed by TP3');
  PERFORM pg_temp.chk(pg_temp.near((pg_temp.ev(p.id,'TP1')).net_usd, 2.02), 'T03: TP1 net ' || (pg_temp.ev(p.id,'TP1')).net_usd);
  PERFORM pg_temp.chk(pg_temp.near((pg_temp.ev(p.id,'TP2')).net_usd, 2.47), 'T03: TP2 net ' || (pg_temp.ev(p.id,'TP2')).net_usd);
  PERFORM pg_temp.chk(pg_temp.near((pg_temp.ev(p.id,'TP3')).net_usd, 1.73), 'T03: TP3 net ' || (pg_temp.ev(p.id,'TP3')).net_usd);
  PERFORM pg_temp.chk(pg_temp.near(p.realized_net_usd, 6.23), 'T03: net ' || p.realized_net_usd || ' expected 6.23');
  PERFORM pg_temp.chk(pg_temp.near(p.return_on_margin_pct, 12.45), 'T03: ROM ' || p.return_on_margin_pct);
  PERFORM pg_temp.chk(p.exit_summary = 'TP1+TP2+TP3' AND p.remaining_pct = 0, 'T03: summary');
  PERFORM pg_temp.chk(pg_temp.near(p.liquidation_price, 132.57) AND NOT p.stop_capped_by_liquidation, 'T03: liquidation 132.57, not capped');
""")

write('T04_two_tps_one_candle','P-14 step 5','TP1 and TP2 in one candle', DECL + f"""
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := {EX1};
  PERFORM pg_temp.candle('BTCUSDT', b + interval '1 hour', 80100, 81700, 80000, 81500);
  r := public.paper_evaluate_positions();
  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(pg_temp.exits(p.id) = 2 AND (pg_temp.ev(p.id,'TP1')).id IS NOT NULL
                  AND (pg_temp.ev(p.id,'TP2')).id IS NOT NULL, 'T04: two events TP1 + TP2');
  PERFORM pg_temp.chk(p.status = 'OPEN' AND p.remaining_pct = 20 AND p.tp_hits = 2, 'T04: OPEN with 20% remaining, got ' || p.remaining_pct);
  PERFORM pg_temp.chk(p.last_evaluated_open_time = b + interval '1 hour', 'T04: cursor');
  PERFORM pg_temp.chk(p.exit_reason IS NULL AND p.closed_at IS NULL, 'T04: not closed');
""")

write('T05_gap_through_sl','P-14 step 4','gap below SL fills at open', DECL + f"""
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := {EX1};
  PERFORM pg_temp.candle('BTCUSDT', b + interval '1 hour', 78000, 78100, 77900, 78050);
  r := public.paper_evaluate_positions();
  p := pg_temp.pos(p.id);
  e := pg_temp.ev(p.id, 'SL');
  PERFORM pg_temp.chk(e.fill_price = 78000 * 0.9995, 'T05: fill must be open x (1 - 0.05%), got ' || e.fill_price);
  PERFORM pg_temp.chk((e.details ->> 'gap_through')::boolean, 'T05: gap_through flag');
  PERFORM pg_temp.chk(p.exit_reason = 'SL' AND p.realized_net_usd < -4.27, 'T05: worse than a normal SL');
""")

write('T06_timeout_data_unavailable','P-14 steps 8 and after-loop','TIMEOUT at 72h, DATA_UNAVAILABLE', DECL + f"""
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := {EX1};
  FOR i IN 1..75 LOOP
    PERFORM pg_temp.candle('BTCUSDT', b + make_interval(hours => i), 80000, 80100, 79900, 80050);
  END LOOP;
  -- DATA_UNAVAILABLE: no candles at all, 100h old (> 72 + 24)
  q := pg_temp.sig('NODATAUSDT','LONG',1, 100,95,105,110,115, 40,40,20, 1, NULL,
                   date_trunc('hour', now()) - interval '100 hours' + interval '14 minutes');
  r := public.paper_evaluate_positions();

  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(p.status = 'CLOSED' AND p.exit_reason = 'TIMEOUT', 'T06: TIMEOUT expected, got ' || coalesce(p.exit_reason, p.status));
  PERFORM pg_temp.chk(p.last_evaluated_open_time = b + interval '72 hours', 'T06: closed in the candle where 72h elapse, cursor ' || p.last_evaluated_open_time);
  PERFORM pg_temp.chk(p.closed_at = b + interval '73 hours' - interval '1 millisecond', 'T06: closed_at');
  PERFORM pg_temp.chk((pg_temp.ev(p.id,'TIMEOUT')).fill_price = 80050 * 0.9995, 'T06: fill = close with stop slippage');
  PERFORM pg_temp.chk(pg_temp.near(p.duration_hours, 72 + 46/60.0, 0.001), 'T06: duration ' || p.duration_hours);

  q := pg_temp.pos(q.id);
  PERFORM pg_temp.chk(q.status = 'CLOSED' AND q.exit_reason = 'DATA_UNAVAILABLE', 'T06: DATA_UNAVAILABLE expected, got ' || coalesce(q.exit_reason, q.status));
  e := pg_temp.ev(q.id, 'DATA_UNAVAILABLE');
  PERFORM pg_temp.chk(e.level_price = q.entry_fill_price AND e.details ->> 'price_source' = 'entry_fill', 'T06: no candles -> entry_fill');

  -- last known close is used when an older candle exists; 90h old stays OPEN
  q := pg_temp.sig('OLDUSDT','LONG',1, 100,95,105,110,115, 40,40,20, 1, NULL,
                   date_trunc('hour', now()) - interval '100 hours' + interval '14 minutes');
  PERFORM pg_temp.candle('OLDUSDT', date_trunc('hour', now()) - interval '110 hours', 101, 102, 100, 101.5);
  p := pg_temp.sig('YOUNGUSDT','LONG',1, 100,95,105,110,115, 40,40,20, 1, NULL,
                   date_trunc('hour', now()) - interval '90 hours');
  r := public.paper_evaluate_positions();
  PERFORM pg_temp.chk((pg_temp.ev(q.id,'DATA_UNAVAILABLE')).level_price = 101.5, 'T06: last known close');
  PERFORM pg_temp.chk((pg_temp.pos(p.id)).status = 'OPEN', 'T06: 90h without data is still OPEN');
""")

write('T07_breakeven','P-14 steps 2, 6','break-even after TP1, effective next candle', DECL + f"""
  UPDATE public.paper_config SET leverage_override = 5, move_sl_to_breakeven_after_tp1 = true WHERE id = 1;
  p := {EX1};
  -- TP1 candle dips below entry_fill (80040): BE must NOT apply here
  PERFORM pg_temp.candle('BTCUSDT', b + interval '1 hour',  80100, 81300, 79990, 81000);
  PERFORM pg_temp.candle('BTCUSDT', b + interval '2 hours', 80500, 80600, 80000, 80300);
  r := public.paper_evaluate_positions();
  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk((pg_temp.ev(p.id,'BE_ACTIVATED')).candle_open_time = b + interval '1 hour', 'T07: BE_ACTIVATED in the TP1 candle');
  PERFORM pg_temp.chk(p.exit_reason = 'BREAKEVEN_SL' AND p.exit_summary = 'TP1+BREAKEVEN_SL', 'T07: got ' || coalesce(p.exit_summary,''));
  e := pg_temp.ev(p.id, 'BREAKEVEN_SL');
  PERFORM pg_temp.chk(e.candle_open_time = b + interval '2 hours', 'T07: BE stop hit in the NEXT candle');
  PERFORM pg_temp.chk(e.fill_price = 80040 * 0.9995, 'T07: BE fill = entry_fill with slippage, got ' || e.fill_price);
  PERFORM pg_temp.chk(p.be_active, 'T07: be_active');
""")

write('T08_liquidation','P-10, P-14, P-15','L=20, SL beyond liquidation', DECL + """
  UPDATE public.paper_config SET max_leverage = 20, leverage_override = 20 WHERE id = 1;
  -- (a) whole position liquidated
  p := pg_temp.sig('LIQUSDT','LONG',1, 100,90,110,115,120, 40,40,20, 1, NULL, b + interval '14 minutes');
  PERFORM pg_temp.chk(p.stop_capped_by_liquidation, 'T08: stop_capped_by_liquidation');
  PERFORM pg_temp.candle('LIQUSDT', b + interval '1 hour', 100.2, 100.5, 95, 96);
  -- (b) TP1 first, then liquidation of the remaining 60%
  q := pg_temp.sig('LIQ2USDT','LONG',1, 100,90,110,115,120, 40,40,20, 1, NULL, b + interval '14 minutes');
  PERFORM pg_temp.candle('LIQ2USDT', b + interval '1 hour',  100.2, 110.5, 100, 110);
  PERFORM pg_temp.candle('LIQ2USDT', b + interval '2 hours', 109, 109.5, 95, 96);
  r := public.paper_evaluate_positions();

  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(p.exit_reason = 'LIQUIDATION', 'T08a: LIQUIDATION expected, got ' || coalesce(p.exit_reason,''));
  PERFORM pg_temp.chk(p.realized_net_usd = -50, 'T08a: net must be -margin (-50), got ' || p.realized_net_usd);
  PERFORM pg_temp.chk((pg_temp.ev(p.id,'LIQUIDATION')).level_price = p.liquidation_price, 'T08a: level = liquidation price');

  q := pg_temp.pos(q.id);
  PERFORM pg_temp.chk(q.exit_summary = 'TP1+LIQUIDATION', 'T08b: summary ' || coalesce(q.exit_summary,''));
  PERFORM pg_temp.chk((pg_temp.ev(q.id,'LIQUIDATION')).net_usd = -30, 'T08b: liquidation of 60% loses 30');
  PERFORM pg_temp.chk(q.realized_net_usd = (pg_temp.ev(q.id,'TP1')).net_usd - 30, 'T08b: total');
""")

write('T11_idempotency','P-13, P-14, P-28','re-running evaluate / ingest changes nothing', DECL.replace('BEGIN', '  n_ev bigint;\n  v_net numeric;\n  n_c bigint;\n  bad public.paper_positions;\nBEGIN') + f"""
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := {EX1};
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
  UPDATE public.paper_positions SET config_snapshot = '{{}}'::jsonb WHERE id = bad.id;
  PERFORM pg_temp.candle('OKUSDT',  b + interval '1 hour', 100, 105.5, 99, 105);
  PERFORM pg_temp.candle('BADUSDT', b + interval '1 hour', 100, 105.5, 99, 105);
  r := public.paper_evaluate_positions(now(), ARRAY['FAILUSDT']);
  PERFORM pg_temp.chk(r->>'status' = 'PARTIAL', 'T11: status PARTIAL expected, got ' || (r->>'status'));
  PERFORM pg_temp.chk((pg_temp.pos(q.id)).tp_hits = 1, 'T11: healthy position still evaluated');
  PERFORM pg_temp.chk((pg_temp.ev(bad.id,'ERROR')).id IS NOT NULL AND (pg_temp.pos(bad.id)).last_evaluated_open_time IS NULL,
                      'T11: broken position gets ERROR event and keeps its cursor');
  PERFORM pg_temp.chk((SELECT error FROM public.paper_monitor_runs ORDER BY id DESC LIMIT 1) LIKE '%FAILUSDT%', 'T11: run error lists failed symbols');
""")

write('T12_future_candle','P-13, P-14','unclosed candle is ignored', """DECLARE
  h timestamptz := date_trunc('hour', now());
  p public.paper_positions;
  r jsonb;
BEGIN
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := pg_temp.sig('BTCUSDT','LONG',1, 80000,78800,81200,81600,82000, 40,40,20, 1, NULL,
                   h - interval '2 hours' + interval '14 minutes');
  PERFORM pg_temp.candle('BTCUSDT', h - interval '1 hour', 80000, 80100, 79900, 80050);   -- closed, neutral
  PERFORM pg_temp.candle('BTCUSDT', h, 80000, 81300, 79900, 81000);                        -- NOT closed, hits TP1
  r := public.paper_evaluate_positions();
  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(p.tp_hits = 0 AND p.last_evaluated_open_time = h - interval '1 hour',
                      'T12: the current (unclosed) candle must be ignored');
  r := public.paper_ingest_candles(jsonb_build_array(jsonb_build_object('symbol','BTCUSDT','open_time', h,
         'close_time', h + interval '1 hour' - interval '1 millisecond','open',1,'high',1,'low',1,'close',1,'volume',1)));
  PERFORM pg_temp.chk((r->>'valid')::int = 0, 'T12: ingest must drop an unclosed candle');
  -- once it is closed (clock moved), it counts
  r := public.paper_evaluate_positions(now() + interval '2 hours');
  PERFORM pg_temp.chk((pg_temp.pos(p.id)).tp_hits = 1, 'T12: after close the candle is evaluated');
""")

write('T13_partial_first_hour','P-10, P-14','signal at 10:14: the 10:00 candle is not evaluated', DECL + """
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := pg_temp.sig('BTCUSDT','LONG',1, 80000,78800,81200,81600,82000, 40,40,20, 1, NULL,
                   b + interval '10 hours 14 minutes');
  PERFORM pg_temp.candle('BTCUSDT', b + interval '10 hours', 80000, 81300, 79900, 81000);  -- TP1, partial hour
  PERFORM pg_temp.candle('BTCUSDT', b + interval '11 hours', 80000, 80100, 79900, 80050);  -- neutral
  r := public.paper_evaluate_positions();
  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(p.tp_hits = 0, 'T13: TP in the partial first hour must not count');
  PERFORM pg_temp.chk(p.eval_start_open_time = b + interval '11 hours'
                  AND p.last_evaluated_open_time = b + interval '11 hours', 'T13: evaluation starts at 11:00');
  PERFORM pg_temp.chk((r->>'candles_used')::int = 1, 'T13: exactly one candle used');
""")

write('T14_catch_up_and_targets','P-12, P-14, P-28','catch-up of 10 hours, targets, data gap', DECL + f"""
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  r := public.paper_get_monitor_targets();
  PERFORM pg_temp.chk((r->>'count')::int = 0 AND r->'targets' = '[]'::jsonb, 'T14: no OPEN -> empty targets');

  p := {EX1};
  r := public.paper_get_monitor_targets();
  PERFORM pg_temp.chk((r->'targets'->0->>'start_time_ms')::bigint = extract(epoch FROM b + interval '1 hour')::bigint * 1000,
                      'T14: start = eval_start ' || r::text);

  PERFORM pg_temp.candle('BTCUSDT', b + interval '1 hour',  80000, 80100, 79900, 80050);
  PERFORM pg_temp.candle('BTCUSDT', b + interval '2 hours', 80000, 80100, 79900, 80050);
  r := public.paper_evaluate_positions();
  PERFORM pg_temp.chk((r->>'candles_used')::int = 2, 'T14: first run 2 candles');
  r := public.paper_get_monitor_targets();
  PERFORM pg_temp.chk((r->'targets'->0->>'start_time_ms')::bigint = extract(epoch FROM b + interval '3 hours')::bigint * 1000,
                      'T14: start = cursor + 1h');

  -- monitor was down for 10 hours
  FOR i IN 3..11 LOOP
    PERFORM pg_temp.candle('BTCUSDT', b + make_interval(hours => i), 80000, 80100, 79900, 80050);
  END LOOP;
  PERFORM pg_temp.candle('BTCUSDT', b + interval '12 hours', 80000, 81300, 79900, 81000);   -- TP1 in the 10th
  r := public.paper_evaluate_positions();
  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk((r->>'candles_used')::int = 10, 'T14: one run catches up 10 candles, got ' || (r->>'candles_used'));
  PERFORM pg_temp.chk(p.last_evaluated_open_time = b + interval '12 hours' AND p.tp_hits = 1, 'T14: cursor and TP1');
  PERFORM pg_temp.chk((pg_temp.ev(p.id,'TP1')).candle_open_time = b + interval '12 hours', 'T14: TP1 in the right candle');
  PERFORM pg_temp.chk(NOT p.has_data_gap, 'T14: contiguous candles are not a gap');

  -- data gap: recorded once, processing continues
  q := pg_temp.sig('GAPUSDT','LONG',1, 100,95,105,110,115, 40,40,20, 1, NULL, b + interval '14 minutes');
  PERFORM pg_temp.candle('GAPUSDT', b + interval '1 hour',  100, 101, 99, 100);
  PERFORM pg_temp.candle('GAPUSDT', b + interval '2 hours', 100, 101, 99, 100);
  PERFORM pg_temp.candle('GAPUSDT', b + interval '5 hours', 100, 101, 99, 100);
  r := public.paper_evaluate_positions();
  PERFORM pg_temp.candle('GAPUSDT', b + interval '8 hours', 100, 101, 99, 100);
  r := public.paper_evaluate_positions();
  q := pg_temp.pos(q.id);
  PERFORM pg_temp.chk(q.has_data_gap AND q.last_evaluated_open_time = b + interval '8 hours', 'T14: gap flagged, cursor moved on');
  PERFORM pg_temp.chk((SELECT count(*) FROM public.paper_position_events WHERE position_id = q.id AND event_type = 'DATA_GAP') = 1,
                      'T14: DATA_GAP recorded once');
""")

write('T15_lock_held','P-14 locking','concurrent run backs off', DECL + f"""
  UPDATE public.paper_config SET leverage_override = 5 WHERE id = 1;
  p := {EX1};
  PERFORM pg_temp.candle('BTCUSDT', b + interval '1 hour', 80050, 81300, 79900, 81000);
  -- simulate "another monitor run holds the lock" (restored by ROLLBACK)
  EXECUTE $x$ CREATE OR REPLACE FUNCTION public.paper_try_monitor_lock() RETURNS boolean
              LANGUAGE sql AS $b$ SELECT false $b$ $x$;
  r := public.paper_evaluate_positions();
  PERFORM pg_temp.chk(r->>'status' = 'SKIPPED_LOCKED', 'T15: status ' || (r->>'status'));
  p := pg_temp.pos(p.id);
  PERFORM pg_temp.chk(p.tp_hits = 0 AND p.last_evaluated_open_time IS NULL, 'T15: no changes while locked');
  PERFORM pg_temp.chk(pg_temp.exits(p.id) = 0, 'T15: no events while locked');
  PERFORM pg_temp.chk((SELECT status FROM public.paper_monitor_runs ORDER BY id DESC LIMIT 1) = 'SKIPPED_LOCKED', 'T15: run row');
""")
