-- =====================================================================
-- PAPER TRADING — 003_engine.sql                    [P-08 P-09 P-10 P-11]
-- Position engine: every row inserted into telegram_signals gets exactly
-- one row in paper_positions (OPEN | SKIPPED | REJECTED).
--
-- Part 4 (monitoring / exit simulation) will be appended to this file.
-- Idempotent (CREATE OR REPLACE / DROP TRIGGER IF EXISTS).
-- Prerequisites: 001_schema.sql, 002_signal_ingest.sql.
-- =====================================================================

DO $$
BEGIN
  IF to_regclass('public.paper_positions') IS NULL THEN
    RAISE EXCEPTION 'PAPER-TRADING PREREQUISITE MISSING: run 001_schema.sql first.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'telegram_signals'
                    AND column_name = 'cycle_timestamp') THEN
    RAISE EXCEPTION 'PAPER-TRADING PREREQUISITE MISSING: run 002_signal_ingest.sql first.';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- paper_open_position(signal) — the full P-08 sequence for one signal.
-- Returns the paper_positions.id that was created.
-- Called only by the trigger below; never exposed to anon/authenticated.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_open_position(p_sig public.telegram_signals)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  cfg           public.paper_config%ROWTYPE;
  pos           public.paper_positions%ROWTYPE;
  v_tp1         numeric;
  v_tp2         numeric;
  v_tp3         numeric;
  v_a1          numeric;
  v_a2          numeric;
  v_a3          numeric;
  v_s_e         numeric;   -- entry slippage, fraction
  v_lev         integer;
  v_equity      numeric;
  v_used        numeric;
  v_free        numeric;
  v_margin      numeric;
  v_open_count  integer;
  v_related     bigint;
  v_age_min     numeric;
  v_alloc_note  text;
BEGIN
  -- Serialise position opening so the duplicate / cap / balance checks see a
  -- consistent picture even with concurrent inserts. Released at commit.
  PERFORM pg_advisory_xact_lock(7272001);

  SELECT * INTO cfg FROM public.paper_config WHERE id = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'paper_config row id=1 is missing';
  END IF;

  -- ---- common snapshot (kept for every status, useful for history) ----
  pos.id                         := nextval(pg_get_serial_sequence('public.paper_positions', 'id'));
  pos.signal_id                  := p_sig.id;
  pos.scan_cycle_id              := p_sig.scan_cycle_id;
  pos.symbol                     := p_sig.symbol;
  pos.tier                       := p_sig.tier;
  pos.category                   := coalesce((SELECT c.category FROM public.paper_symbol_categories c
                                               WHERE c.symbol = p_sig.symbol), 'OTHER');
  pos.direction                  := CASE WHEN p_sig.signal_direction IN ('LONG','SHORT')
                                         THEN p_sig.signal_direction END;
  pos.signal_entry_price         := p_sig.entry_price;
  pos.entry_min                  := p_sig.entry_min;
  pos.entry_max                  := p_sig.entry_max;
  pos.stop_loss                  := p_sig.stop_loss;
  pos.tp1                        := p_sig.tp1;
  pos.tp2                        := p_sig.tp2;
  pos.tp3                        := p_sig.tp3;
  pos.alloc1                     := p_sig.tp1_allocation;
  pos.alloc2                     := p_sig.tp2_allocation;
  pos.alloc3                     := p_sig.tp3_allocation;
  pos.signal_leverage            := p_sig.suggested_leverage;
  pos.total_score                := p_sig.total_score;
  pos.market_condition           := p_sig.market_condition;
  pos.tp_strategy                := p_sig.tp_strategy;
  pos.fee_adjusted_rr            := p_sig.fee_adjusted_rr;
  pos.config_snapshot            := to_jsonb(cfg);
  pos.opened_at                  := coalesce(p_sig.sent_at, now());
  pos.stop_capped_by_liquidation := false;
  pos.be_active                  := false;
  pos.remaining_pct              := 0;        -- terminal statuses hold nothing
  pos.tp_hits                    := 0;
  pos.realized_gross_usd         := 0;
  pos.fees_usd                   := 0;
  pos.funding_usd                := 0;
  pos.realized_net_usd           := 0;
  pos.has_data_gap               := false;
  pos.created_at                 := now();

  -- ---- 1. global switch ---------------------------------------------
  IF NOT cfg.enabled THEN
    pos.status := 'SKIPPED'; pos.status_reason := 'PAPER_DISABLED';
    INSERT INTO public.paper_positions SELECT (pos).*;
    RETURN pos.id;
  END IF;

  -- ---- 2. validation -> REJECTED ------------------------------------
  IF pos.direction IS NULL THEN
    pos.status := 'REJECTED';
    pos.status_reason := format('INVALID_DIRECTION: %s', coalesce(p_sig.signal_direction, 'NULL'));
    INSERT INTO public.paper_positions SELECT (pos).*;
    RETURN pos.id;
  END IF;

  IF coalesce(p_sig.entry_price, 0) <= 0 OR coalesce(p_sig.stop_loss, 0) <= 0
     OR coalesce(p_sig.tp1, 0) <= 0 THEN
    pos.status := 'REJECTED';
    pos.status_reason := 'INVALID_LEVELS: entry_price, stop_loss and tp1 must be > 0';
    INSERT INTO public.paper_positions SELECT (pos).*;
    RETURN pos.id;
  END IF;

  -- a missing (or non-positive) TP2 / TP3 is replaced by the previous level
  v_tp1 := p_sig.tp1;
  v_tp2 := CASE WHEN coalesce(p_sig.tp2, 0) > 0 THEN p_sig.tp2 ELSE v_tp1 END;
  v_tp3 := CASE WHEN coalesce(p_sig.tp3, 0) > 0 THEN p_sig.tp3 ELSE v_tp2 END;
  pos.tp1 := v_tp1; pos.tp2 := v_tp2; pos.tp3 := v_tp3;

  IF (pos.direction = 'LONG'  AND NOT (p_sig.stop_loss < p_sig.entry_price
                                       AND p_sig.entry_price < v_tp1
                                       AND v_tp1 <= v_tp2 AND v_tp2 <= v_tp3))
  OR (pos.direction = 'SHORT' AND NOT (p_sig.stop_loss > p_sig.entry_price
                                       AND p_sig.entry_price > v_tp1
                                       AND v_tp1 >= v_tp2 AND v_tp2 >= v_tp3)) THEN
    pos.status := 'REJECTED';
    pos.status_reason := CASE pos.direction
      WHEN 'LONG'  THEN 'INVALID_LEVEL_ORDER: LONG requires SL < entry < TP1 <= TP2 <= TP3'
      ELSE              'INVALID_LEVEL_ORDER: SHORT requires SL > entry > TP1 >= TP2 >= TP3' END;
    INSERT INTO public.paper_positions SELECT (pos).*;
    RETURN pos.id;
  END IF;

  -- allocations: all missing -> 40/40/20 (DEFAULT_ALLOCATION);
  -- partially missing -> missing ones count as 0 and the sum check applies.
  IF p_sig.tp1_allocation IS NULL AND p_sig.tp2_allocation IS NULL
     AND p_sig.tp3_allocation IS NULL THEN
    v_a1 := 40; v_a2 := 40; v_a3 := 20;
    v_alloc_note := 'DEFAULT_ALLOCATION';
  ELSE
    v_a1 := coalesce(p_sig.tp1_allocation, 0);
    v_a2 := coalesce(p_sig.tp2_allocation, 0);
    v_a3 := coalesce(p_sig.tp3_allocation, 0);
  END IF;
  pos.alloc1 := v_a1; pos.alloc2 := v_a2; pos.alloc3 := v_a3;

  IF v_a1 < 0 OR v_a2 < 0 OR v_a3 < 0 OR abs(v_a1 + v_a2 + v_a3 - 100) > 0.5 THEN
    pos.status := 'REJECTED';
    pos.status_reason := format('INVALID_ALLOCATION: %s/%s/%s (sum %s, expected 100 +/- 0.5)',
                                v_a1, v_a2, v_a3, v_a1 + v_a2 + v_a3);
    INSERT INTO public.paper_positions SELECT (pos).*;
    RETURN pos.id;
  END IF;

  -- slippage for this tier must be configured (no guessing — rule 7)
  v_s_e := (cfg.entry_slippage_pct ->> p_sig.tier::text)::numeric / 100;
  IF v_s_e IS NULL OR (cfg.stop_slippage_pct ->> p_sig.tier::text) IS NULL THEN
    pos.status := 'REJECTED';
    pos.status_reason := format('NO_SLIPPAGE_FOR_TIER: %s', coalesce(p_sig.tier::text, 'NULL'));
    INSERT INTO public.paper_positions SELECT (pos).*;
    RETURN pos.id;
  END IF;

  -- ---- 3. stale signal -----------------------------------------------
  IF p_sig.cycle_timestamp IS NOT NULL THEN
    v_age_min := extract(epoch FROM (pos.opened_at - p_sig.cycle_timestamp)) / 60;
    IF v_age_min > cfg.max_signal_age_minutes THEN
      pos.status := 'REJECTED';
      pos.status_reason := format('STALE_SIGNAL: %s min old (max %s)',
                                  round(v_age_min, 1), cfg.max_signal_age_minutes);
      INSERT INTO public.paper_positions SELECT (pos).*;
      RETURN pos.id;
    END IF;
  END IF;

  -- ---- 4. duplicate OPEN position for the symbol (any direction) ------
  SELECT id INTO v_related FROM public.paper_positions
   WHERE symbol = p_sig.symbol AND status = 'OPEN' LIMIT 1;
  IF v_related IS NOT NULL THEN
    pos.status := 'SKIPPED'; pos.status_reason := 'DUPLICATE_OPEN_POSITION';
    pos.related_position_id := v_related;
    INSERT INTO public.paper_positions SELECT (pos).*;
    RETURN pos.id;
  END IF;

  -- ---- 5. cap on concurrent positions --------------------------------
  SELECT count(*) INTO v_open_count FROM public.paper_positions WHERE status = 'OPEN';
  IF v_open_count >= cfg.max_open_positions THEN
    pos.status := 'SKIPPED';
    pos.status_reason := format('MAX_OPEN_POSITIONS: %s open (max %s)', v_open_count, cfg.max_open_positions);
    INSERT INTO public.paper_positions SELECT (pos).*;
    RETURN pos.id;
  END IF;

  -- ---- 6. sizing (P-09) ------------------------------------------------
  SELECT cfg.initial_capital_usd + coalesce(sum(realized_net_usd) FILTER (WHERE status = 'CLOSED'), 0),
         coalesce(sum(margin_usd) FILTER (WHERE status = 'OPEN'), 0)
    INTO v_equity, v_used
    FROM public.paper_positions;
  v_free := v_equity - v_used;

  v_margin := CASE cfg.sizing_mode
                WHEN 'FIXED_MARGIN'   THEN cfg.fixed_margin_usd
                WHEN 'PERCENT_EQUITY' THEN v_equity * cfg.equity_pct / 100
              END;

  IF v_margin IS NULL OR v_margin <= 0 OR v_margin > v_free THEN
    pos.status := 'SKIPPED';
    pos.status_reason := format('INSUFFICIENT_VIRTUAL_BALANCE: margin %s, free %s (equity %s, used %s)',
                                round(v_margin, 2), round(v_free, 2), round(v_equity, 2), round(v_used, 2));
    INSERT INTO public.paper_positions SELECT (pos).*;
    RETURN pos.id;
  END IF;

  v_lev := greatest(1, least(cfg.max_leverage,
                             coalesce(cfg.leverage_override, p_sig.suggested_leverage, 1)));

  -- ---- 7. open-time calculations (P-10) ---------------------------------
  pos.leverage     := v_lev;
  pos.margin_usd   := v_margin;
  pos.notional_usd := v_margin * v_lev;

  IF pos.direction = 'LONG' THEN
    pos.entry_fill_price  := p_sig.entry_price * (1 + v_s_e);
    pos.liquidation_price := pos.entry_fill_price * (1 - 1.0 / v_lev + cfg.maintenance_margin_rate);
    pos.effective_stop    := greatest(p_sig.stop_loss, pos.liquidation_price);
    pos.stop_capped_by_liquidation := pos.liquidation_price > p_sig.stop_loss;
  ELSE
    pos.entry_fill_price  := p_sig.entry_price * (1 - v_s_e);
    pos.liquidation_price := pos.entry_fill_price * (1 + 1.0 / v_lev - cfg.maintenance_margin_rate);
    pos.effective_stop    := least(p_sig.stop_loss, pos.liquidation_price);
    pos.stop_capped_by_liquidation := pos.liquidation_price < p_sig.stop_loss;
  END IF;

  pos.quantity      := pos.notional_usd / pos.entry_fill_price;
  pos.remaining_pct := 100;
  -- first full UTC hour after the signal; the partial first hour is NOT evaluated
  pos.eval_start_open_time := (date_trunc('hour', pos.opened_at AT TIME ZONE 'UTC')
                               + interval '1 hour') AT TIME ZONE 'UTC';
  pos.status        := 'OPEN';
  pos.status_reason := v_alloc_note;

  BEGIN
    INSERT INTO public.paper_positions SELECT (pos).*;
  EXCEPTION WHEN unique_violation THEN
    -- last line of defence: uq_paper_positions_open_symbol (concurrent open)
    pos.status := 'SKIPPED'; pos.status_reason := 'DUPLICATE_OPEN_POSITION';
    pos.related_position_id := (SELECT id FROM public.paper_positions
                                 WHERE symbol = p_sig.symbol AND status = 'OPEN' LIMIT 1);
    pos.remaining_pct := 0;
    INSERT INTO public.paper_positions SELECT (pos).*;
    RETURN pos.id;
  END;

  INSERT INTO public.paper_position_events
    (position_id, event_type, tranche, candle_open_time, level_price, fill_price,
     qty, pct_of_position, details)
  VALUES
    (pos.id, 'OPENED', NULL, NULL, p_sig.entry_price, pos.entry_fill_price,
     pos.quantity, 100,
     jsonb_build_object(
       'entry_slippage_pct', v_s_e * 100,
       'leverage', v_lev,
       'leverage_source', CASE WHEN cfg.leverage_override IS NOT NULL THEN 'override'
                               WHEN p_sig.suggested_leverage IS NOT NULL THEN 'signal'
                               ELSE 'default' END,
       'margin_usd', v_margin,
       'equity_usd', v_equity,
       'used_margin_usd', v_used,
       'free_usd', v_free,
       'tranche_qty', jsonb_build_array(pos.quantity * v_a1 / 100,
                                        pos.quantity * v_a2 / 100,
                                        pos.quantity * v_a3 / 100),
       'config_version', cfg.config_version));

  RETURN pos.id;
END $$;

-- ---------------------------------------------------------------------
-- Trigger function — MUST NEVER fail the signal insert (P-08 step 8).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_on_signal_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_pid   bigint;
  v_msg   text;
  v_state text;
BEGIN
  BEGIN
    PERFORM public.paper_open_position(NEW);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    BEGIN
      INSERT INTO public.paper_positions
        (signal_id, scan_cycle_id, symbol, tier, direction, status, status_reason,
         opened_at, remaining_pct)
      VALUES
        (NEW.id, NEW.scan_cycle_id, NEW.symbol, NEW.tier,
         CASE WHEN NEW.signal_direction IN ('LONG','SHORT') THEN NEW.signal_direction END,
         'REJECTED', left('INTERNAL_ERROR: ' || v_msg, 500),
         coalesce(NEW.sent_at, now()), 0)
      RETURNING id INTO v_pid;

      INSERT INTO public.paper_position_events (position_id, event_type, details)
      VALUES (v_pid, 'ERROR',
              jsonb_build_object('stage', 'open', 'sqlstate', v_state, 'message', v_msg));
    EXCEPTION WHEN OTHERS THEN
      -- even the error record failed: keep the signal, leave a log line
      RAISE WARNING 'paper_on_signal_insert: could not record INTERNAL_ERROR for signal %: % / %',
                    NEW.id, v_msg, SQLERRM;
    END;
  END;
  RETURN NULL;  -- AFTER trigger: return value ignored
END $$;

DROP TRIGGER IF EXISTS paper_on_signal_insert ON public.telegram_signals;
CREATE TRIGGER paper_on_signal_insert
  AFTER INSERT ON public.telegram_signals
  FOR EACH ROW
  EXECUTE FUNCTION public.paper_on_signal_insert();

-- ---------------------------------------------------------------------
-- Privileges: these functions write data; they must not be callable
-- through PostgREST by anon/authenticated. (005_security.sql repeats this.)
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.paper_open_position(public.telegram_signals) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.paper_on_signal_insert() FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.paper_open_position(public.telegram_signals) FROM anon';
    EXECUTE 'REVOKE ALL ON FUNCTION public.paper_on_signal_insert() FROM anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.paper_open_position(public.telegram_signals) FROM authenticated';
    EXECUTE 'REVOKE ALL ON FUNCTION public.paper_on_signal_insert() FROM authenticated';
  END IF;
END $$;


-- #####################################################################
-- PART 4 — MONITORING AND EXIT SIMULATION          [P-12 P-13 P-14 P-15]
-- #####################################################################

-- ---------------------------------------------------------------------
-- P-12  paper_get_monitor_targets()
-- One entry per symbol with an OPEN position; start = earliest candle the
-- evaluator still needs. Returned as ONE json object so the N8N IF node
-- always receives exactly one item:  {"count": n, "targets": [{symbol, start_time_ms}]}
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_get_monitor_targets()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
           'count',   count(*),
           'targets', coalesce(jsonb_agg(jsonb_build_object('symbol', symbol,
                                                            'start_time_ms', start_ms)
                                         ORDER BY symbol), '[]'::jsonb))
    FROM (SELECT symbol,
                 (extract(epoch FROM min(greatest(eval_start_open_time,
                                                  coalesce(last_evaluated_open_time + interval '1 hour',
                                                           eval_start_open_time)))) * 1000)::bigint AS start_ms
            FROM public.paper_positions
           WHERE status = 'OPEN'
           GROUP BY symbol) t;
$$;

-- ---------------------------------------------------------------------
-- P-13  paper_ingest_candles(p_candles)
-- Upsert of closed 1h candles by (symbol, open_time). Invalid or not-yet-
-- closed candles are dropped (defence in depth; the normalizer drops them too).
-- Input: [{symbol, open_time, close_time, open, high, low, close, volume}]
--        timestamps ISO-8601, prices as numbers or numeric strings.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_ingest_candles(p_candles jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_received integer;
  v_valid    integer;
  v_inserted integer;
  v_updated  integer;
BEGIN
  IF p_candles IS NULL OR jsonb_typeof(p_candles) <> 'array' THEN
    RETURN jsonb_build_object('received', 0, 'valid', 0, 'inserted', 0, 'updated', 0,
                              'error', 'p_candles must be a json array');
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _paper_ingest (LIKE public.paper_candles) ON COMMIT DROP;
  TRUNCATE _paper_ingest;

  INSERT INTO _paper_ingest (symbol, open_time, close_time, open, high, low, close, volume, ingested_at)
  SELECT DISTINCT ON (upper(x.symbol), x.open_time)
         upper(x.symbol), x.open_time, x.close_time, x.open, x.high, x.low, x.close, x.volume, now()
    FROM jsonb_to_recordset(p_candles) AS x(symbol text, open_time timestamptz, close_time timestamptz,
                                            open numeric, high numeric, low numeric, close numeric,
                                            volume numeric)
   WHERE x.symbol IS NOT NULL AND x.open_time IS NOT NULL AND x.close_time IS NOT NULL
     AND x.close_time > x.open_time
     AND x.close_time < now()                       -- closed candles only
     AND x.low > 0 AND x.high >= x.low
     AND x.open  BETWEEN x.low AND x.high
     AND x.close BETWEEN x.low AND x.high
   ORDER BY upper(x.symbol), x.open_time;

  v_received := jsonb_array_length(p_candles);
  SELECT count(*) INTO v_valid FROM _paper_ingest;

  WITH up AS (
    INSERT INTO public.paper_candles AS pc
           (symbol, open_time, close_time, open, high, low, close, volume, ingested_at)
    SELECT symbol, open_time, close_time, open, high, low, close, volume, ingested_at FROM _paper_ingest
    ON CONFLICT (symbol, open_time) DO UPDATE
       SET close_time = EXCLUDED.close_time, open = EXCLUDED.open, high = EXCLUDED.high,
           low = EXCLUDED.low, close = EXCLUDED.close, volume = EXCLUDED.volume,
           ingested_at = EXCLUDED.ingested_at
     WHERE (pc.close_time, pc.open, pc.high, pc.low, pc.close, pc.volume)
           IS DISTINCT FROM
           (EXCLUDED.close_time, EXCLUDED.open, EXCLUDED.high, EXCLUDED.low, EXCLUDED.close, EXCLUDED.volume)
    RETURNING (xmax = 0) AS was_insert)
  SELECT count(*) FILTER (WHERE was_insert), count(*) FILTER (WHERE NOT was_insert)
    INTO v_inserted, v_updated FROM up;

  RETURN jsonb_build_object('received', v_received, 'valid', v_valid,
                            'inserted', v_inserted, 'updated', v_updated);
END $$;

-- ---------------------------------------------------------------------
-- P-15  exit amounts for one tranche / remainder
-- gross: LONG q*(exit-entry), SHORT q*(entry-exit)
-- fees : q*entry*F + q*exit*F   (entry fee charged proportionally per exit)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_exit_amounts(
  p_direction text, p_qty numeric, p_entry_fill numeric, p_exit_fill numeric, p_fee_rate numeric,
  OUT gross numeric, OUT fees numeric, OUT net numeric)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT g, f, g - f
    FROM (SELECT CASE WHEN p_direction = 'LONG' THEN p_qty * (p_exit_fill - p_entry_fill)
                      ELSE p_qty * (p_entry_fill - p_exit_fill) END AS g,
                 p_qty * p_entry_fill * p_fee_rate + p_qty * p_exit_fill * p_fee_rate AS f) t;
$$;

-- Lock wrapper: a separate function so T15 can simulate a held lock.
CREATE OR REPLACE FUNCTION public.paper_try_monitor_lock()
RETURNS boolean
LANGUAGE sql
VOLATILE
AS $$ SELECT pg_try_advisory_xact_lock(7272002); $$;

-- ---------------------------------------------------------------------
-- P-14  paper_evaluate_positions()
-- Deterministic exit simulation on CLOSED 1h candles with a per-position
-- cursor. Re-running never changes results (T11); missed hours are caught
-- up in one run (T14); a concurrent run backs off (T15).
--
-- Costs and rules come from the position's config_snapshot (frozen at open),
-- so a later config change never rewrites already-open positions.
--
-- p_now            : evaluation clock (default now()); tests only.
-- p_failed_symbols : symbols whose Binance fetch failed in this monitor run
--                    (from PAPER CANDLE NORMALIZER) -> run status PARTIAL.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_evaluate_positions(
  p_now            timestamptz DEFAULT now(),
  p_failed_symbols text[]      DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  cfg          public.paper_config%ROWTYPE;
  pos          public.paper_positions%ROWTYPE;
  c            public.paper_candles%ROWTYPE;
  v_started    timestamptz := clock_timestamp();
  v_status     text := 'OK';
  v_errors     text[] := '{}';
  v_evaluated  integer := 0;
  v_candles    integer := 0;
  v_events_n   integer := 0;
  v_closed_n   integer := 0;
  v_events     jsonb := '[]'::jsonb;
  v_run_id     bigint;
  v_msg        text;

  -- per position
  snap         jsonb;
  v_fee        numeric;
  v_s_x        numeric;   -- adverse stop / timeout slippage (fraction)
  v_s_tp       numeric;   -- tp slippage (fraction)
  v_hold       interval;
  v_be_rule    boolean;
  v_rem        numeric;
  v_hits       integer;
  v_be         boolean;
  v_gross      numeric;
  v_fees       numeric;
  v_net        numeric;
  v_summary    text;
  v_cursor     timestamptz;
  v_prev       timestamptz;
  v_gap        boolean;
  v_closed     boolean;
  v_reason     text;
  v_closed_at  timestamptz;
  v_stop       numeric;
  v_level      numeric;
  v_fill       numeric;
  v_pct        numeric;
  v_qty        numeric;
  v_gap_thru   boolean;
  v_tp1_now    boolean;
  v_last_close numeric;
  a            record;
BEGIN
  -- ---- concurrency guard ------------------------------------------------
  IF NOT public.paper_try_monitor_lock() THEN
    INSERT INTO public.paper_monitor_runs (started_at, finished_at, status)
    VALUES (v_started, clock_timestamp(), 'SKIPPED_LOCKED')
    RETURNING id INTO v_run_id;
    RETURN jsonb_build_object('status', 'SKIPPED_LOCKED', 'run_id', v_run_id,
                              'evaluated', 0, 'candles_used', 0, 'closed', 0,
                              'events', '[]'::jsonb, 'notify_telegram_on_exit', false);
  END IF;

  BEGIN  -- whole-run guard: a failure is recorded as an ERROR run, never raised to N8N
    SELECT * INTO cfg FROM public.paper_config WHERE id = 1;

    FOR pos IN
      SELECT * FROM public.paper_positions
       WHERE status = 'OPEN'
       ORDER BY opened_at, id
         FOR UPDATE
    LOOP
      v_evaluated := v_evaluated + 1;

      BEGIN  -- per-position guard: one broken position does not stop the others
        snap      := coalesce(pos.config_snapshot, to_jsonb(cfg));
        v_fee     := (snap ->> 'fee_rate')::numeric;
        v_s_x     := (snap -> 'stop_slippage_pct' ->> pos.tier::text)::numeric / 100;
        v_s_tp    := coalesce((snap ->> 'tp_slippage_pct')::numeric, 0) / 100;
        v_hold    := make_interval(hours => (snap ->> 'max_holding_hours')::int);
        v_be_rule := coalesce((snap ->> 'move_sl_to_breakeven_after_tp1')::boolean, false);
        IF v_fee IS NULL OR v_s_x IS NULL OR v_hold IS NULL THEN
          RAISE EXCEPTION 'config_snapshot incomplete for position % (fee/slippage/holding)', pos.id;
        END IF;

        v_rem       := pos.remaining_pct;
        v_hits      := pos.tp_hits;
        v_be        := pos.be_active;
        v_gross     := pos.realized_gross_usd;
        v_fees      := pos.fees_usd;
        v_net       := pos.realized_net_usd;
        v_summary   := pos.exit_summary;
        v_cursor    := pos.last_evaluated_open_time;
        v_gap       := pos.has_data_gap;
        v_closed    := false;
        v_reason    := NULL;
        v_closed_at := NULL;
        -- expected open_time of the next candle = cursor + 1h (or eval start)
        v_prev      := coalesce(v_cursor, pos.eval_start_open_time - interval '1 hour');

        FOR c IN
          SELECT * FROM public.paper_candles
           WHERE symbol = pos.symbol
             AND open_time >= pos.eval_start_open_time
             AND open_time > coalesce(v_cursor, '-infinity'::timestamptz)
             AND close_time < p_now
           ORDER BY open_time
        LOOP
          v_candles := v_candles + 1;
          v_tp1_now := false;

          -- 1. data gap (recorded once per position; processing continues)
          IF c.open_time - v_prev > interval '1 hour' THEN
            v_gap := true;
            INSERT INTO public.paper_position_events
              (position_id, event_type, candle_open_time, details)
            VALUES (pos.id, 'DATA_GAP', c.open_time,
                    jsonb_build_object('expected_open_time', v_prev + interval '1 hour',
                                       'actual_open_time', c.open_time,
                                       'missing_hours',
                                       extract(epoch FROM (c.open_time - v_prev)) / 3600 - 1))
            ON CONFLICT DO NOTHING;
            IF FOUND THEN v_events_n := v_events_n + 1; END IF;
          END IF;
          v_prev := c.open_time;

          -- 2. active stop (break-even only from the candle AFTER activation)
          IF v_be THEN
            v_stop := CASE WHEN pos.direction = 'LONG'
                           THEN greatest(pos.effective_stop, pos.entry_fill_price)
                           ELSE least(pos.effective_stop, pos.entry_fill_price) END;
          ELSE
            v_stop := pos.effective_stop;
          END IF;

          -- 3./4. stop touched -> priority over any TP in the same candle
          IF (pos.direction = 'LONG'  AND c.low  <= v_stop)
          OR (pos.direction = 'SHORT' AND c.high >= v_stop) THEN
            v_gap_thru := (pos.direction = 'LONG'  AND c.open <= v_stop)
                       OR (pos.direction = 'SHORT' AND c.open >= v_stop);
            v_fill := CASE WHEN v_gap_thru THEN c.open ELSE v_stop END;
            v_fill := CASE WHEN pos.direction = 'LONG' THEN v_fill * (1 - v_s_x)
                           ELSE v_fill * (1 + v_s_x) END;
            v_reason := CASE
              WHEN pos.stop_capped_by_liquidation AND v_stop = pos.liquidation_price THEN 'LIQUIDATION'
              WHEN v_be THEN 'BREAKEVEN_SL'
              ELSE 'SL' END;
            v_pct := v_rem;
            v_qty := pos.quantity * v_pct / 100;
            SELECT * INTO a FROM public.paper_exit_amounts(pos.direction, v_qty, pos.entry_fill_price,
                                                           v_fill, v_fee);
            IF v_reason = 'LIQUIDATION' THEN
              -- the whole margin of this share is lost; fees are inside the loss
              a.net   := -(pos.margin_usd * v_pct / 100);
              a.gross := a.net + a.fees;
            END IF;

            INSERT INTO public.paper_position_events
              (position_id, event_type, tranche, candle_open_time, level_price, fill_price,
               qty, pct_of_position, gross_usd, fees_usd, net_usd, details)
            VALUES (pos.id, v_reason, NULL, c.open_time, v_stop, v_fill,
                    v_qty, v_pct, a.gross, a.fees, a.net,
                    jsonb_build_object('gap_through', v_gap_thru, 'slippage_pct', v_s_x * 100,
                                       'candle', jsonb_build_object('o', c.open, 'h', c.high,
                                                                    'l', c.low, 'c', c.close)));
            v_events_n := v_events_n + 1;
            v_events := v_events || jsonb_build_object(
              'position_id', pos.id, 'symbol', pos.symbol, 'direction', pos.direction,
              'event_type', v_reason, 'fill_price', v_fill, 'net_usd', a.net,
              'candle_open_time', c.open_time);

            v_gross := v_gross + a.gross; v_fees := v_fees + a.fees; v_net := v_net + a.net;
            v_rem := 0;
            v_summary := concat_ws('+', v_summary, v_reason);
            v_closed := true; v_closed_at := c.close_time;
            v_cursor := c.open_time;
            EXIT;  -- candle processing stops
          END IF;

          -- 5. TP levels in order (only unfilled ones; stop at first unfilled)
          WHILE v_hits < 3 AND v_rem > 0 LOOP
            v_level := CASE v_hits WHEN 0 THEN pos.tp1 WHEN 1 THEN pos.tp2 ELSE pos.tp3 END;
            EXIT WHEN NOT ((pos.direction = 'LONG'  AND c.high >= v_level)
                        OR (pos.direction = 'SHORT' AND c.low  <= v_level));
            v_hits := v_hits + 1;
            -- TP3 closes the whole remainder (absorbs the +/-0.5 allocation tolerance)
            v_pct := CASE WHEN v_hits = 3 THEN v_rem
                          ELSE least(v_rem, CASE v_hits WHEN 1 THEN pos.alloc1 ELSE pos.alloc2 END) END;
            v_qty := pos.quantity * v_pct / 100;
            -- limit order: never better than the level, even on a gap
            v_fill := CASE WHEN pos.direction = 'LONG' THEN v_level * (1 - v_s_tp)
                           ELSE v_level * (1 + v_s_tp) END;
            SELECT * INTO a FROM public.paper_exit_amounts(pos.direction, v_qty, pos.entry_fill_price,
                                                           v_fill, v_fee);
            INSERT INTO public.paper_position_events
              (position_id, event_type, tranche, candle_open_time, level_price, fill_price,
               qty, pct_of_position, gross_usd, fees_usd, net_usd, details)
            VALUES (pos.id, 'TP' || v_hits, v_hits, c.open_time, v_level, v_fill,
                    v_qty, v_pct, a.gross, a.fees, a.net,
                    jsonb_build_object('candle', jsonb_build_object('o', c.open, 'h', c.high,
                                                                    'l', c.low, 'c', c.close)));
            v_events_n := v_events_n + 1;
            v_events := v_events || jsonb_build_object(
              'position_id', pos.id, 'symbol', pos.symbol, 'direction', pos.direction,
              'event_type', 'TP' || v_hits, 'fill_price', v_fill, 'net_usd', a.net,
              'candle_open_time', c.open_time);
            v_gross := v_gross + a.gross; v_fees := v_fees + a.fees; v_net := v_net + a.net;
            v_rem := v_rem - v_pct;
            v_summary := concat_ws('+', v_summary, 'TP' || v_hits);
            IF v_hits = 1 THEN v_tp1_now := true; END IF;
          END LOOP;

          -- 7. full close by take-profits
          IF v_rem <= 0 THEN
            v_rem := 0;
            v_reason := 'TP' || v_hits;   -- TP3 with normal allocations
            v_closed := true; v_closed_at := c.close_time;
            v_cursor := c.open_time;
            EXIT;
          END IF;

          -- 6. break-even activation (effective from the next candle)
          IF v_be_rule AND v_tp1_now AND NOT v_be THEN
            v_be := true;
            INSERT INTO public.paper_position_events
              (position_id, event_type, candle_open_time, level_price, details)
            VALUES (pos.id, 'BE_ACTIVATED', c.open_time, pos.entry_fill_price,
                    jsonb_build_object('effective_from', c.open_time + interval '1 hour'));
            v_events_n := v_events_n + 1;
          END IF;

          -- 8. time exit
          IF c.close_time >= pos.opened_at + v_hold THEN
            v_fill := CASE WHEN pos.direction = 'LONG' THEN c.close * (1 - v_s_x)
                           ELSE c.close * (1 + v_s_x) END;
            v_pct := v_rem;
            v_qty := pos.quantity * v_pct / 100;
            SELECT * INTO a FROM public.paper_exit_amounts(pos.direction, v_qty, pos.entry_fill_price,
                                                           v_fill, v_fee);
            INSERT INTO public.paper_position_events
              (position_id, event_type, tranche, candle_open_time, level_price, fill_price,
               qty, pct_of_position, gross_usd, fees_usd, net_usd, details)
            VALUES (pos.id, 'TIMEOUT', NULL, c.open_time, c.close, v_fill,
                    v_qty, v_pct, a.gross, a.fees, a.net,
                    jsonb_build_object('max_holding_hours', (snap ->> 'max_holding_hours')::int,
                                       'slippage_pct', v_s_x * 100));
            v_events_n := v_events_n + 1;
            v_events := v_events || jsonb_build_object(
              'position_id', pos.id, 'symbol', pos.symbol, 'direction', pos.direction,
              'event_type', 'TIMEOUT', 'fill_price', v_fill, 'net_usd', a.net,
              'candle_open_time', c.open_time);
            v_gross := v_gross + a.gross; v_fees := v_fees + a.fees; v_net := v_net + a.net;
            v_rem := 0;
            v_summary := concat_ws('+', v_summary, 'TIMEOUT');
            v_reason := 'TIMEOUT';
            v_closed := true; v_closed_at := c.close_time;
            v_cursor := c.open_time;
            EXIT;
          END IF;

          -- 9. advance the cursor
          v_cursor := c.open_time;
        END LOOP;

        -- after the candles: no data at all long after the holding period
        IF NOT v_closed
           AND p_now - pos.opened_at > v_hold + interval '24 hours'
           AND NOT EXISTS (SELECT 1 FROM public.paper_candles
                            WHERE symbol = pos.symbol AND open_time >= pos.eval_start_open_time) THEN
          SELECT close INTO v_last_close FROM public.paper_candles
           WHERE symbol = pos.symbol ORDER BY open_time DESC LIMIT 1;
          v_level := coalesce(v_last_close, pos.entry_fill_price);
          v_fill  := CASE WHEN pos.direction = 'LONG' THEN v_level * (1 - v_s_x)
                          ELSE v_level * (1 + v_s_x) END;
          v_pct := v_rem;
          v_qty := pos.quantity * v_pct / 100;
          SELECT * INTO a FROM public.paper_exit_amounts(pos.direction, v_qty, pos.entry_fill_price,
                                                         v_fill, v_fee);
          INSERT INTO public.paper_position_events
            (position_id, event_type, tranche, candle_open_time, level_price, fill_price,
             qty, pct_of_position, gross_usd, fees_usd, net_usd, details)
          VALUES (pos.id, 'DATA_UNAVAILABLE', NULL, NULL, v_level, v_fill,
                  v_qty, v_pct, a.gross, a.fees, a.net,
                  jsonb_build_object('price_source',
                                     CASE WHEN v_last_close IS NULL THEN 'entry_fill' ELSE 'last_known_close' END));
          v_events_n := v_events_n + 1;
          v_events := v_events || jsonb_build_object(
            'position_id', pos.id, 'symbol', pos.symbol, 'direction', pos.direction,
            'event_type', 'DATA_UNAVAILABLE', 'fill_price', v_fill, 'net_usd', a.net,
            'candle_open_time', NULL);
          v_gross := v_gross + a.gross; v_fees := v_fees + a.fees; v_net := v_net + a.net;
          v_rem := 0;
          v_summary := concat_ws('+', v_summary, 'DATA_UNAVAILABLE');
          v_reason := 'DATA_UNAVAILABLE';
          v_closed := true; v_closed_at := p_now;
        END IF;

        UPDATE public.paper_positions
           SET remaining_pct            = v_rem,
               tp_hits                  = v_hits,
               be_active                = v_be,
               realized_gross_usd       = v_gross,
               fees_usd                 = v_fees,
               realized_net_usd         = v_net,
               return_on_margin_pct     = CASE WHEN margin_usd > 0 THEN v_net / margin_usd * 100 END,
               exit_summary             = v_summary,
               last_evaluated_open_time = v_cursor,
               has_data_gap             = v_gap,
               status                   = CASE WHEN v_closed THEN 'CLOSED' ELSE 'OPEN' END,
               exit_reason              = CASE WHEN v_closed THEN v_reason END,
               closed_at                = CASE WHEN v_closed THEN v_closed_at END,
               duration_hours           = CASE WHEN v_closed
                                               THEN extract(epoch FROM (v_closed_at - opened_at)) / 3600 END
         WHERE id = pos.id;

        IF v_closed THEN v_closed_n := v_closed_n + 1; END IF;

      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_status := 'PARTIAL';
        v_errors := v_errors || format('position %s (%s): %s', pos.id, pos.symbol, v_msg);
        INSERT INTO public.paper_position_events (position_id, event_type, details)
        VALUES (pos.id, 'ERROR', jsonb_build_object('stage', 'evaluate', 'message', v_msg,
                                                     'at', clock_timestamp()))
        ON CONFLICT (position_id, event_type, (coalesce(tranche, 0)))
        DO UPDATE SET details = EXCLUDED.details, created_at = now();
      END;
    END LOOP;

    IF coalesce(cardinality(p_failed_symbols), 0) > 0 THEN
      v_status := 'PARTIAL';
      v_errors := v_errors || ('binance fetch failed: ' || array_to_string(p_failed_symbols, ', '));
    END IF;

  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    v_status := 'ERROR';
    v_errors := v_errors || v_msg;
    v_evaluated := 0; v_candles := 0; v_events_n := 0; v_closed_n := 0; v_events := '[]'::jsonb;
  END;

  INSERT INTO public.paper_monitor_runs
    (started_at, finished_at, status, positions_evaluated, candles_used,
     events_created, positions_closed, error)
  VALUES (v_started, clock_timestamp(), v_status, v_evaluated, v_candles,
          v_events_n, v_closed_n, nullif(array_to_string(v_errors, ' | '), ''))
  RETURNING id INTO v_run_id;

  RETURN jsonb_build_object(
    'status', v_status, 'run_id', v_run_id,
    'evaluated', v_evaluated, 'candles_used', v_candles,
    'events_created', v_events_n, 'closed', v_closed_n,
    'events', v_events,
    'notify_telegram_on_exit', coalesce(cfg.notify_telegram_on_exit, false),
    'errors', to_jsonb(v_errors));
END $$;

-- ---------------------------------------------------------------------
-- Privileges for Part 4: service_role only (N8N). 005_security.sql repeats this.
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.paper_get_monitor_targets()                       FROM PUBLIC;
REVOKE ALL ON FUNCTION public.paper_ingest_candles(jsonb)                       FROM PUBLIC;
REVOKE ALL ON FUNCTION public.paper_evaluate_positions(timestamptz, text[])     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.paper_try_monitor_lock()                          FROM PUBLIC;

DO $$
DECLARE
  r text;
  f text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH f IN ARRAY ARRAY['public.paper_get_monitor_targets()',
                               'public.paper_ingest_candles(jsonb)',
                               'public.paper_evaluate_positions(timestamptz, text[])',
                               'public.paper_try_monitor_lock()'] LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
      END LOOP;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT EXECUTE ON FUNCTION public.paper_get_monitor_targets()                   TO service_role;
    GRANT EXECUTE ON FUNCTION public.paper_ingest_candles(jsonb)                   TO service_role;
    GRANT EXECUTE ON FUNCTION public.paper_evaluate_positions(timestamptz, text[]) TO service_role;
  END IF;
END $$;
