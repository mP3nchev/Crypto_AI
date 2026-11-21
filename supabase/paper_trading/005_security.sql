-- =====================================================================
-- PAPER TRADING — 005_security.sql                                [P-23]
-- Row Level Security and privileges.
--   * RLS ON for every paper_* table and telegram_signals
--   * SELECT-only policies for `authenticated` (the single dashboard user)
--   * NO insert/update/delete policies: only service_role (N8N) writes
--     (service_role bypasses RLS; the engine trigger runs SECURITY DEFINER)
--   * anon: no table, view or function access at all
--   * any old anon/public policy on these tables is dropped
--
-- !! APPLY ONLY AFTER the N8N "Supabase Signal Insert" node uses the
-- !! service_role credential (Part 2, row4/SUPABASE SIGNAL INSERT — N8N CONFIG).
-- !! With the old anon key the signal insert would be refused from now on.
--
-- Idempotent. Prerequisites: 001 … 004.
-- =====================================================================

DO $$
BEGIN
  IF to_regclass('public.paper_positions_v') IS NULL THEN
    RAISE EXCEPTION 'PAPER-TRADING PREREQUISITE MISSING: run 004_analytics.sql first.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    RAISE EXCEPTION 'Supabase roles anon / authenticated / service_role not found — is this a Supabase database?';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 1. Drop old policies on these tables that grant anything to anon/public
--    (e.g. the documented "service_insert ... FOR INSERT TO anon").
--    Each dropped policy is reported with a NOTICE.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  pol record;
BEGIN
  FOR pol IN
    SELECT schemaname, tablename, policyname, cmd, roles
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename IN ('telegram_signals', 'paper_config', 'paper_positions',
                         'paper_position_events', 'paper_candles',
                         'paper_symbol_categories', 'paper_monitor_runs')
       AND (roles && ARRAY['anon', 'public']::name[]
            OR (cmd <> 'SELECT' AND policyname NOT LIKE 'paper_read_%'))
  LOOP
    EXECUTE format('DROP POLICY %I ON %I.%I', pol.policyname, pol.schemaname, pol.tablename);
    RAISE NOTICE 'dropped policy "%" on % (cmd %, roles %)',
                 pol.policyname, pol.tablename, pol.cmd, pol.roles;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 2. RLS on + one SELECT policy for authenticated per table
-- ---------------------------------------------------------------------
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['telegram_signals', 'paper_config', 'paper_positions',
                           'paper_position_events', 'paper_candles',
                           'paper_symbol_categories', 'paper_monitor_runs'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);

    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'paper_read_' || t, t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)',
                   'paper_read_' || t, t);

    -- table privileges (defence in depth on top of RLS)
    EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM authenticated', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
  END LOOP;
END $$;

-- sequences: only service_role inserts
REVOKE ALL ON SEQUENCE public.telegram_signals_id_seq,
                       public.paper_positions_id_seq,
                       public.paper_position_events_id_seq,
                       public.paper_monitor_runs_id_seq
  FROM anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.telegram_signals_id_seq,
                                public.paper_positions_id_seq,
                                public.paper_position_events_id_seq,
                                public.paper_monitor_runs_id_seq
  TO service_role;

-- ---------------------------------------------------------------------
-- 3. Views (security_invoker -> the caller's RLS applies)
-- ---------------------------------------------------------------------
REVOKE ALL ON public.paper_positions_v, public.paper_health_v FROM anon, authenticated;
GRANT SELECT ON public.paper_positions_v, public.paper_health_v TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. Functions
--    read-only statistics (SECURITY INVOKER): authenticated + service_role
--    writers / engine internals:              service_role only (or nobody)
-- ---------------------------------------------------------------------
DO $$
DECLARE
  f text;
  read_only text[] := ARRAY[
    'public.paper_filtered_positions(text[], text[], text, int[])',
    'public.paper_stats(date, date, text[], text[], text, int[])',
    'public.paper_daily_pnl(date, text[], text[], text, int[])',
    'public.paper_stats_breakdown(text, date, date, text[], text[], text, int[])'];
  service_only text[] := ARRAY[
    'public.paper_get_monitor_targets()',
    'public.paper_ingest_candles(jsonb)',
    'public.paper_evaluate_positions(timestamptz, text[])',
    'public.paper_recompute_position(bigint, text)'];
  internal text[] := ARRAY[
    'public.paper_open_position(public.telegram_signals)',
    'public.paper_on_signal_insert()',
    'public.paper_try_monitor_lock()',
    'public.paper_exit_amounts(text, numeric, numeric, numeric, numeric)',
    'public.paper_config_touch()'];
BEGIN
  FOREACH f IN ARRAY read_only || service_only || internal LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY read_only LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
  END LOOP;
  FOREACH f IN ARRAY service_only LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 5. Self-check: fail loudly if anything is still open
-- ---------------------------------------------------------------------
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['telegram_signals', 'paper_config', 'paper_positions',
                           'paper_position_events', 'paper_candles',
                           'paper_symbol_categories', 'paper_monitor_runs'] LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass) THEN
      RAISE EXCEPTION 'SECURITY CHECK: RLS is not enabled on %', t;
    END IF;
    IF has_table_privilege('anon', 'public.' || t, 'SELECT')
       OR has_table_privilege('anon', 'public.' || t, 'INSERT')
       OR has_table_privilege('authenticated', 'public.' || t, 'INSERT')
       OR has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       OR has_table_privilege('authenticated', 'public.' || t, 'DELETE') THEN
      RAISE EXCEPTION 'SECURITY CHECK: unexpected privilege left on %', t;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_policies
              WHERE schemaname = 'public' AND cmd <> 'SELECT'
                AND tablename IN ('telegram_signals', 'paper_config', 'paper_positions',
                                  'paper_position_events', 'paper_candles',
                                  'paper_symbol_categories', 'paper_monitor_runs')) THEN
    RAISE EXCEPTION 'SECURITY CHECK: a write policy still exists on a paper table';
  END IF;
  IF has_function_privilege('anon', 'public.paper_stats(date, date, text[], text[], text, int[])', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.paper_evaluate_positions(timestamptz, text[])', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.paper_recompute_position(bigint, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'SECURITY CHECK: function privileges are too open';
  END IF;
  RAISE NOTICE '005_security: OK — RLS on, read-only for authenticated, no anon access';
END $$;
