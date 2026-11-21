-- =====================================================================
-- PAPER TRADING — 006_dashboard.sql                        [P-22, P-24]
-- Read-only aggregates the dashboard design needs beyond 004, so that the
-- browser does no financial calculation (P-22):
--   * paper_portfolio_summary  — header KPI strip (equity, exposure, …)
--   * paper_month_overview     — calendar banner (month stats, green/red days, best/worst)
--   * paper_symbols            — options for the symbol filter
--
-- Idempotent. Prerequisites: 001 … 005. SECURITY INVOKER: RLS applies.
-- =====================================================================

DO $$
BEGIN
  IF to_regprocedure('public.paper_stats(date, date, text[], text[], text, int[])') IS NULL THEN
    RAISE EXCEPTION 'PAPER-TRADING PREREQUISITE MISSING: run 004_analytics.sql first.';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Header KPIs. Equity is ACCOUNT level (all CLOSED trades, unfiltered);
-- open-position and 24h figures respect the filters.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_portfolio_summary(
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
acct AS (
  SELECT coalesce(sum(realized_net_usd) FILTER (WHERE status = 'CLOSED'), 0) AS realized
    FROM public.paper_positions_v
),
f AS (
  SELECT * FROM public.paper_filtered_positions(p_symbols, p_categories, p_direction, p_tiers)
),
op AS (
  SELECT count(*)                                         AS n,
         coalesce(sum(margin_usd), 0)                     AS margin,
         coalesce(sum(notional_usd), 0)                   AS notional,
         coalesce(sum(partially_realized_net_usd), 0)     AS partial,
         coalesce(sum(indicative_unrealized_usd), 0)      AS unreal
    FROM f WHERE status = 'OPEN'
),
d24 AS (
  SELECT count(*)                                                  AS signals,
         count(*) FILTER (WHERE status IN ('OPEN', 'CLOSED'))      AS opened,
         count(*) FILTER (WHERE status = 'SKIPPED')                AS skipped,
         count(*) FILTER (WHERE status = 'REJECTED')               AS rejected,
         max(opened_at)                                            AS last_signal_at
    FROM f WHERE created_at > now() - interval '24 hours'
)
SELECT jsonb_build_object(
  'initial_capital_usd',        c.initial,
  'realized_net_usd',           a.realized,
  'equity_usd',                 c.initial + a.realized,
  'equity_return_pct',          CASE WHEN c.initial > 0 THEN a.realized / c.initial * 100 END,
  'open_positions',             o.n,
  'open_margin_usd',            o.margin,
  'open_notional_usd',          o.notional,
  'exposure_pct',               CASE WHEN c.initial + a.realized > 0
                                     THEN o.margin / (c.initial + a.realized) * 100 END,
  'partially_realized_usd',     o.partial,
  'indicative_unrealized_usd',  o.unreal,
  'indicative_unrealized_pct',  CASE WHEN o.margin > 0 THEN o.unreal / o.margin * 100 END,
  'signals_24h',                d.signals,
  'opened_24h',                 d.opened,
  'skipped_24h',                d.skipped,
  'rejected_24h',               d.rejected,
  'opened_24h_pct',             CASE WHEN d.signals > 0 THEN d.opened::numeric / d.signals * 100 END,
  'last_signal_at',             d.last_signal_at)
FROM cfg c, acct a, op o, d24 d;
$$;

-- ---------------------------------------------------------------------
-- Calendar banner for one month (local timezone), filters as everywhere.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_month_overview(
  p_month      date,
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
WITH b AS (
  SELECT date_trunc('month', p_month)::date AS first_day,
         (date_trunc('month', p_month) + interval '1 month' - interval '1 day')::date AS last_day
),
d AS (
  SELECT * FROM public.paper_daily_pnl(p_month, p_symbols, p_categories, p_direction, p_tiers)
   WHERE trades > 0
)
SELECT jsonb_build_object(
  'month',               (SELECT first_day FROM b),
  'stats',               public.paper_stats((SELECT first_day FROM b), (SELECT last_day FROM b),
                                            p_symbols, p_categories, p_direction, p_tiers),
  'trading_days',        (SELECT count(*) FROM d),
  'green_days',          (SELECT count(*) FROM d WHERE net_usd > 0),
  'red_days',            (SELECT count(*) FROM d WHERE net_usd < 0),
  'best_day_net_usd',    (SELECT max(net_usd) FROM d),
  'best_day',            (SELECT day FROM d ORDER BY net_usd DESC, day LIMIT 1),
  'worst_day_net_usd',   (SELECT min(net_usd) FROM d),
  'worst_day',           (SELECT day FROM d ORDER BY net_usd, day LIMIT 1),
  'max_abs_day_net_usd', coalesce((SELECT max(abs(net_usd)) FROM d), 0));
$$;

-- ---------------------------------------------------------------------
-- Symbols seen by the engine (for the filter), with their category.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.paper_symbols()
RETURNS TABLE (symbol text, category text, positions bigint)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  SELECT symbol, max(category), count(*)
    FROM public.paper_positions_v
   GROUP BY symbol
   ORDER BY symbol;
$$;

-- ---------------------------------------------------------------------
-- Privileges: authenticated + service_role, never anon
-- ---------------------------------------------------------------------
DO $$
DECLARE
  f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.paper_portfolio_summary(text[], text[], text, int[])',
                           'public.paper_month_overview(date, text[], text[], text, int[])',
                           'public.paper_symbols()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', f);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
    END IF;
  END LOOP;
END $$;
