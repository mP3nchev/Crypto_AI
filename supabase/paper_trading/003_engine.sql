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
