-- =====================================================================
-- PAPER TRADING — 004_analytics.sql                  [P-17 … P-21, P-28]
-- History, statistics, daily P&L, health view and position recompute.
-- All money/percent calculations live here; the dashboard only formats.
--
-- Idempotent (CREATE OR REPLACE). Prerequisites: 001, 002, 003.
-- =====================================================================

DO $$
BEGIN
  IF to_regprocedure('public.paper_evaluate_positions(timestamptz, text[])') IS NULL THEN
    RAISE EXCEPTION 'PAPER-TRADING PREREQUISITE MISSING: run 003_engine.sql (incl. Part 4) first.';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- P-17  paper_positions_v — the single source for lists and details.
-- security_invoker: the caller's RLS applies (005_security.sql).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.paper_positions_v
WITH (security_invoker = true) AS
SELECT
  p.*,
  (p.closed_at AT TIME ZONE tz.timezone)::date AS closed_date_local,
  (p.opened_at AT TIME ZONE tz.timezone)::date AS opened_date_local,
  CASE WHEN p.status = 'CLOSED' THEN
    CASE WHEN p.realized_net_usd >  0.01 THEN 'WIN'
         WHEN p.realized_net_usd < -0.01 THEN 'LOSS'
         ELSE 'BREAKEVEN' END
  END AS outcome,
  x.avg_exit_price,
  -- unleveraged price move of the realised part (P-15), sign -1 for SHORT
  CASE WHEN x.avg_exit_price IS NOT NULL AND p.entry_fill_price > 0 THEN
    (x.avg_exit_price / p.entry_fill_price - 1) * 100
      * CASE WHEN p.direction = 'SHORT' THEN -1 ELSE 1 END
  END AS price_move_pct,
  -- P-20: profit already taken on a still-OPEN position (NOT in daily P&L)
  CASE WHEN p.status = 'OPEN' THEN p.realized_net_usd END AS partially_realized_net_usd,
  lc.close     AS last_price,
  lc.open_time AS last_price_candle,
  -- P-20: INDICATIVE only (latest close, fees at last price, no slippage); never in any metric
  CASE WHEN p.status = 'OPEN' AND lc.close IS NOT NULL THEN
    (p.quantity * p.remaining_pct / 100)
      * ( (lc.close - p.entry_fill_price) * CASE WHEN p.direction = 'SHORT' THEN -1 ELSE 1 END
          - (p.entry_fill_price + lc.close) * coalesce((p.config_snapshot ->> 'fee_rate')::numeric, 0) )
  END AS indicative_unrealized_usd,
  CASE WHEN p.status = 'OPEN' THEN extract(epoch FROM (now() - p.opened_at)) / 3600 END AS hours_open
FROM public.paper_positions p
CROSS JOIN LATERAL (SELECT coalesce((SELECT timezone FROM public.paper_config WHERE id = 1),
                                    'Europe/Sofia') AS timezone) tz
LEFT JOIN LATERAL (
  SELECT sum(e.fill_price * e.qty) / nullif(sum(e.qty), 0) AS avg_exit_price
    FROM public.paper_position_events e
   WHERE e.position_id = p.id
     AND e.event_type IN ('TP1','TP2','TP3','SL','BREAKEVEN_SL','TIMEOUT','LIQUIDATION','DATA_UNAVAILABLE')
) x ON true
LEFT JOIN LATERAL (
  SELECT c.close, c.open_time
    FROM public.paper_candles c
   WHERE c.symbol = p.symbol
   ORDER BY c.open_time DESC
   LIMIT 1
) lc ON p.status = 'OPEN';

-- ---------------------------------------------------------------------
-- Shared filter (NULL or empty array = all). Not a date filter.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_filtered_positions(
  p_symbols    text[] DEFAULT NULL,
  p_categories text[] DEFAULT NULL,
  p_direction  text   DEFAULT NULL,
  p_tiers      int[]  DEFAULT NULL)
RETURNS SETOF public.paper_positions_v
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  SELECT *
    FROM public.paper_positions_v v
   WHERE (coalesce(cardinality(p_symbols), 0)    = 0 OR v.symbol    = ANY (p_symbols))
     AND (coalesce(cardinality(p_categories), 0) = 0 OR v.category  = ANY (p_categories))
     AND (nullif(p_direction, '') IS NULL         OR v.direction = upper(p_direction))
     AND (coalesce(cardinality(p_tiers), 0)      = 0 OR v.tier      = ANY (p_tiers));
$$;

-- ---------------------------------------------------------------------
-- P-18  paper_stats(...) -> one jsonb object
-- Only CLOSED positions whose closed_date_local is in [p_from, p_to].
-- NULL dates = unbounded. Extra fields beyond the spec table are marked.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_stats(
  p_from       date   DEFAULT NULL,
  p_to         date   DEFAULT NULL,
  p_symbols    text[] DEFAULT NULL,
  p_categories text[] DEFAULT NULL,
  p_direction  text   DEFAULT NULL,
  p_tiers      int[]  DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
WITH cfg AS (
  SELECT coalesce((SELECT initial_capital_usd FROM public.paper_config WHERE id = 1), 0) AS initial
),
f AS (
  SELECT * FROM public.paper_filtered_positions(p_symbols, p_categories, p_direction, p_tiers)
),
closed AS (
  SELECT * FROM f
   WHERE status = 'CLOSED'
     AND (p_from IS NULL OR closed_date_local >= p_from)
     AND (p_to   IS NULL OR closed_date_local <= p_to)
),
agg AS (
  SELECT count(*)                                            AS trades,
         count(*) FILTER (WHERE outcome = 'WIN')             AS wins,
         count(*) FILTER (WHERE outcome = 'LOSS')            AS losses,
         count(*) FILTER (WHERE outcome = 'BREAKEVEN')       AS breakeven,
         coalesce(sum(realized_net_usd), 0)                  AS total_net,
         avg(realized_net_usd) FILTER (WHERE outcome = 'WIN')  AS avg_win,
         avg(realized_net_usd) FILTER (WHERE outcome = 'LOSS') AS avg_loss,
         sum(realized_net_usd) FILTER (WHERE outcome = 'WIN')  AS sum_win,
         sum(realized_net_usd) FILTER (WHERE outcome = 'LOSS') AS sum_loss,
         avg(duration_hours)                                 AS avg_duration
    FROM closed
),
-- extra: max drawdown of the (filtered) equity curve inside the range,
-- starting from initial capital + filtered net closed before p_from
base AS (
  SELECT (SELECT initial FROM cfg)
         + coalesce((SELECT sum(realized_net_usd) FROM f
                      WHERE status = 'CLOSED' AND p_from IS NOT NULL
                        AND closed_date_local < p_from), 0) AS start_equity
),
curve AS (
  SELECT row_number() OVER (ORDER BY closed_at, id) AS rn,
         (SELECT start_equity FROM base)
         + sum(realized_net_usd) OVER (ORDER BY closed_at, id) AS equity
    FROM closed
),
dd AS (
  SELECT max((peak - equity) / nullif(peak, 0) * 100) AS max_dd
    FROM (SELECT equity,
                 greatest((SELECT start_equity FROM base),
                          max(equity) OVER (ORDER BY rn)) AS peak
            FROM curve) c1
)
SELECT jsonb_build_object(
  'from', p_from, 'to', p_to,
  'trades',             a.trades,
  'wins',               a.wins,
  'losses',             a.losses,
  'breakeven',          a.breakeven,
  'win_rate_pct',       CASE WHEN a.trades = 0 THEN 0 ELSE a.wins::numeric / a.trades * 100 END,
  'total_net_usd',      a.total_net,
  'total_return_pct',   CASE WHEN (SELECT initial FROM cfg) > 0
                             THEN a.total_net / (SELECT initial FROM cfg) * 100 END,
  'avg_win_usd',        a.avg_win,
  'avg_loss_usd',       a.avg_loss,
  'profit_factor',      CASE WHEN coalesce(a.sum_loss, 0) = 0 THEN NULL
                             ELSE coalesce(a.sum_win, 0) / abs(a.sum_loss) END,
  'expectancy_usd',     CASE WHEN a.trades = 0 THEN NULL ELSE a.total_net / a.trades END,
  'avg_duration_hours', a.avg_duration,
  'open_positions',     (SELECT count(*) FROM f WHERE status = 'OPEN'),          -- ignores dates
  'skipped',            (SELECT count(*) FROM f WHERE status = 'SKIPPED'
                           AND (p_from IS NULL OR opened_date_local >= p_from)
                           AND (p_to   IS NULL OR opened_date_local <= p_to)),
  'rejected',           (SELECT count(*) FROM f WHERE status = 'REJECTED'
                           AND (p_from IS NULL OR opened_date_local >= p_from)
                           AND (p_to   IS NULL OR opened_date_local <= p_to)),
  -- extras (not part of the metrics above)
  'partially_realized_usd',    (SELECT coalesce(sum(partially_realized_net_usd), 0) FROM f WHERE status = 'OPEN'),
  'indicative_unrealized_usd', (SELECT coalesce(sum(indicative_unrealized_usd), 0) FROM f WHERE status = 'OPEN'),
  'max_drawdown_pct',          coalesce((SELECT max_dd FROM dd), 0),
  'initial_capital_usd',       (SELECT initial FROM cfg)
)
FROM agg a;
$$;

-- ---------------------------------------------------------------------
-- P-19  paper_daily_pnl(month, filters) — a row for EVERY day of the month.
-- A trade's day = the day it was fully closed (local timezone, P-20).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_daily_pnl(
  p_month      date,
  p_symbols    text[] DEFAULT NULL,
  p_categories text[] DEFAULT NULL,
  p_direction  text   DEFAULT NULL,
  p_tiers      int[]  DEFAULT NULL)
RETURNS TABLE (day date, trades integer, wins integer, losses integer,
               net_usd numeric, cumulative_net_usd numeric)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  WITH days AS (
    SELECT d::date AS day
      FROM generate_series(date_trunc('month', p_month)::date,
                           (date_trunc('month', p_month) + interval '1 month' - interval '1 day')::date,
                           interval '1 day') d
  ),
  t AS (
    SELECT closed_date_local, outcome, realized_net_usd
      FROM public.paper_filtered_positions(p_symbols, p_categories, p_direction, p_tiers)
     WHERE status = 'CLOSED'
  ),
  per_day AS (
    SELECT d.day,
           count(t.closed_date_local)::int                   AS trades,
           count(*) FILTER (WHERE t.outcome = 'WIN')::int    AS wins,
           count(*) FILTER (WHERE t.outcome = 'LOSS')::int   AS losses,
           coalesce(sum(t.realized_net_usd), 0)              AS net_usd
      FROM days d
      LEFT JOIN t ON t.closed_date_local = d.day
     GROUP BY d.day
  )
  SELECT day, trades, wins, losses, net_usd,
         sum(net_usd) OVER (ORDER BY day) AS cumulative_net_usd
    FROM per_day
   ORDER BY day;
$$;

-- ---------------------------------------------------------------------
-- Comparison helper for the dashboard (P-24 "Comparison"): paper_stats per
-- segment of one dimension. small_sample = fewer than 20 trades.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_stats_breakdown(
  p_dimension  text,              -- 'symbol' | 'category' | 'direction' | 'tier'
  p_from       date   DEFAULT NULL,
  p_to         date   DEFAULT NULL,
  p_symbols    text[] DEFAULT NULL,
  p_categories text[] DEFAULT NULL,
  p_direction  text   DEFAULT NULL,
  p_tiers      int[]  DEFAULT NULL)
RETURNS TABLE (segment text, stats jsonb, small_sample boolean)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  s text;
  st jsonb;
BEGIN
  IF p_dimension NOT IN ('symbol','category','direction','tier') THEN
    RAISE EXCEPTION 'p_dimension must be symbol, category, direction or tier (got %)', p_dimension;
  END IF;

  FOR s IN
    SELECT DISTINCT CASE p_dimension WHEN 'symbol'    THEN v.symbol
                                     WHEN 'category'  THEN v.category
                                     WHEN 'direction' THEN v.direction
                                     ELSE v.tier::text END
      FROM public.paper_filtered_positions(p_symbols, p_categories, p_direction, p_tiers) v
     WHERE v.status = 'CLOSED'
       AND (p_from IS NULL OR v.closed_date_local >= p_from)
       AND (p_to   IS NULL OR v.closed_date_local <= p_to)
     ORDER BY 1
  LOOP
    st := public.paper_stats(
            p_from, p_to,
            CASE WHEN p_dimension = 'symbol'    THEN ARRAY[s]        ELSE p_symbols END,
            CASE WHEN p_dimension = 'category'  THEN ARRAY[s]        ELSE p_categories END,
            CASE WHEN p_dimension = 'direction' THEN s               ELSE p_direction END,
            CASE WHEN p_dimension = 'tier'      THEN ARRAY[s::int]   ELSE p_tiers END);
    segment := s; stats := st; small_sample := (st ->> 'trades')::int < 20;
    RETURN NEXT;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- P-28  paper_health_v — one row; the dashboard shows a warning bar when
-- warning = true (last successful run older than 3 hours, etc.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.paper_health_v
WITH (security_invoker = true) AS
WITH last_ok AS (
  SELECT max(finished_at) AS at FROM public.paper_monitor_runs WHERE status = 'OK'
),
last_run AS (
  SELECT status, finished_at, error FROM public.paper_monitor_runs ORDER BY id DESC LIMIT 1
),
stale AS (
  SELECT coalesce(array_agg(id ORDER BY id), '{}') AS ids
    FROM public.paper_positions
   WHERE status = 'OPEN'
     AND now() - coalesce(last_evaluated_open_time + interval '1 hour', eval_start_open_time)
         > interval '3 hours'
),
gaps AS (
  SELECT coalesce(array_agg(id ORDER BY id), '{}') AS ids
    FROM public.paper_positions WHERE has_data_gap
),
errs AS (
  SELECT coalesce(array_agg(id ORDER BY id), '{}') AS ids
    FROM public.paper_positions
   WHERE status = 'REJECTED' AND status_reason LIKE 'INTERNAL_ERROR%'
     AND created_at > now() - interval '24 hours'
),
missing AS (
  SELECT count(*) AS n
    FROM public.telegram_signals s
   WHERE s.created_at > now() - interval '24 hours'
     AND NOT EXISTS (SELECT 1 FROM public.paper_positions p WHERE p.signal_id = s.id)
)
SELECT
  (SELECT at FROM last_ok)                                                    AS last_ok_run_at,
  extract(epoch FROM (now() - (SELECT at FROM last_ok))) / 3600               AS last_ok_run_age_hours,
  (SELECT status FROM last_run)                                               AS last_run_status,
  (SELECT error  FROM last_run)                                               AS last_run_error,
  (SELECT ids FROM stale)                                                     AS stale_open_position_ids,
  (SELECT ids FROM gaps)                                                      AS data_gap_position_ids,
  (SELECT ids FROM errs)                                                      AS internal_error_position_ids_24h,
  (SELECT n FROM missing)                                                     AS signals_without_position_24h,
  (SELECT count(*) FROM public.paper_positions WHERE status = 'OPEN')         AS open_positions,
  (   (SELECT at FROM last_ok) IS NULL AND EXISTS (SELECT 1 FROM public.paper_positions WHERE status = 'OPEN')
   OR coalesce(now() - (SELECT at FROM last_ok) > interval '3 hours', false)
   OR cardinality((SELECT ids FROM stale)) > 0
   OR cardinality((SELECT ids FROM errs))  > 0
   OR (SELECT n FROM missing) > 0 )                                           AS warning;

-- ---------------------------------------------------------------------
-- P-21  paper_recompute_position(p_id) — service role only.
-- Deletes all events except OPENED, resets aggregates and cursor and
-- returns the position to OPEN; the next paper_evaluate_positions()
-- re-evaluates it from scratch.
-- The audit trail is kept in the OPENED event's details -> 'recompute_log'
-- (a separate event would be deleted by the next recompute, and the
--  UNIQUE(position, type, tranche) key allows only one per type anyway).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_recompute_position(
  p_id     bigint,
  p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  pos      public.paper_positions%ROWTYPE;
  v_other  bigint;
  v_del    integer;
BEGIN
  -- do not race with a running monitor
  IF NOT public.paper_try_monitor_lock() THEN
    RAISE EXCEPTION 'paper monitor is running — retry in a minute';
  END IF;

  SELECT * INTO pos FROM public.paper_positions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'paper position % not found', p_id;
  END IF;
  IF pos.status NOT IN ('OPEN', 'CLOSED') THEN
    RAISE EXCEPTION 'position % is %, only OPEN or CLOSED positions can be recomputed', p_id, pos.status;
  END IF;

  SELECT id INTO v_other FROM public.paper_positions
   WHERE symbol = pos.symbol AND status = 'OPEN' AND id <> pos.id LIMIT 1;
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'cannot reopen position %: % already has OPEN position %', p_id, pos.symbol, v_other;
  END IF;

  DELETE FROM public.paper_position_events
   WHERE position_id = p_id AND event_type <> 'OPENED';
  GET DIAGNOSTICS v_del = ROW_COUNT;

  UPDATE public.paper_position_events
     SET details = jsonb_set(coalesce(details, '{}'::jsonb), '{recompute_log}',
                             coalesce(details -> 'recompute_log', '[]'::jsonb)
                             || jsonb_build_array(jsonb_build_object(
                                  'at', now(),
                                  'by', current_user,
                                  'reason', p_reason,
                                  'deleted_events', v_del,
                                  'previous', jsonb_build_object(
                                     'status', pos.status, 'exit_reason', pos.exit_reason,
                                     'exit_summary', pos.exit_summary,
                                     'realized_net_usd', pos.realized_net_usd,
                                     'closed_at', pos.closed_at,
                                     'last_evaluated_open_time', pos.last_evaluated_open_time))))
   WHERE position_id = p_id AND event_type = 'OPENED';

  UPDATE public.paper_positions
     SET status = 'OPEN', remaining_pct = 100, tp_hits = 0, be_active = false,
         realized_gross_usd = 0, fees_usd = 0, funding_usd = 0, realized_net_usd = 0,
         return_on_margin_pct = NULL, exit_reason = NULL, exit_summary = NULL,
         duration_hours = NULL, closed_at = NULL, last_evaluated_open_time = NULL,
         has_data_gap = false
   WHERE id = p_id;

  RETURN jsonb_build_object('position_id', p_id, 'deleted_events', v_del,
                            'previous_status', pos.status,
                            'previous_net_usd', pos.realized_net_usd);
END $$;

-- ---------------------------------------------------------------------
-- Privileges. Read-only analytics: authenticated (+ service_role).
-- Recompute: service_role only. (005_security.sql adds RLS and repeats this.)
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.paper_filtered_positions(text[], text[], text, int[])                    FROM PUBLIC;
REVOKE ALL ON FUNCTION public.paper_stats(date, date, text[], text[], text, int[])                     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.paper_daily_pnl(date, text[], text[], text, int[])                       FROM PUBLIC;
REVOKE ALL ON FUNCTION public.paper_stats_breakdown(text, date, date, text[], text[], text, int[])     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.paper_recompute_position(bigint, text)                                   FROM PUBLIC;

DO $$
DECLARE
  f text;
  ro text[] := ARRAY['public.paper_filtered_positions(text[], text[], text, int[])',
                     'public.paper_stats(date, date, text[], text[], text, int[])',
                     'public.paper_daily_pnl(date, text[], text[], text, int[])',
                     'public.paper_stats_breakdown(text, date, date, text[], text[], text, int[])'];
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    FOREACH f IN ARRAY ro || ARRAY['public.paper_recompute_position(bigint, text)'] LOOP
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', f);
    END LOOP;
    EXECUTE 'REVOKE ALL ON public.paper_positions_v, public.paper_health_v FROM anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    FOREACH f IN ARRAY ro LOOP
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
    END LOOP;
    EXECUTE 'REVOKE ALL ON FUNCTION public.paper_recompute_position(bigint, text) FROM authenticated';
    EXECUTE 'GRANT SELECT ON public.paper_positions_v, public.paper_health_v TO authenticated';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    FOREACH f IN ARRAY ro || ARRAY['public.paper_recompute_position(bigint, text)'] LOOP
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
    END LOOP;
    EXECUTE 'GRANT SELECT ON public.paper_positions_v, public.paper_health_v TO service_role';
  END IF;
END $$;
