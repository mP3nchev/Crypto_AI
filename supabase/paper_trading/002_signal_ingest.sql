-- =====================================================================
-- PAPER TRADING — 002_signal_ingest.sql                           [P-04]
-- Extends public.telegram_signals with the fields the paper engine needs
-- and makes inserts idempotent per (scan_cycle_id, symbol).
--
-- Idempotent. Existing rows are never modified or deleted.
-- Prerequisite: 001_schema.sql (and the base telegram_signals table).
-- =====================================================================

DO $$
BEGIN
  IF to_regclass('public.telegram_signals') IS NULL THEN
    RAISE EXCEPTION
      'PAPER-TRADING PREREQUISITE MISSING: table public.telegram_signals does not exist.';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 1. New nullable columns (old rows simply keep NULL)
-- ---------------------------------------------------------------------
ALTER TABLE public.telegram_signals
  ADD COLUMN IF NOT EXISTS entry_min       numeric(18,8),
  ADD COLUMN IF NOT EXISTS entry_max       numeric(18,8),
  ADD COLUMN IF NOT EXISTS tp1_allocation  numeric(6,2),   -- percent, e.g. 40
  ADD COLUMN IF NOT EXISTS tp2_allocation  numeric(6,2),
  ADD COLUMN IF NOT EXISTS tp3_allocation  numeric(6,2),
  ADD COLUMN IF NOT EXISTS sl_distance_pct numeric(8,3),
  ADD COLUMN IF NOT EXISTS total_score     numeric(6,2),
  ADD COLUMN IF NOT EXISTS cycle_timestamp timestamptz;   -- start of the scan cycle

-- ---------------------------------------------------------------------
-- 2. Unique (scan_cycle_id, symbol): re-running a cycle must not duplicate.
--    If duplicates already exist we do NOT delete them (spec rule 7):
--    stop and list them so the user can decide.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  dup_count integer;
  dup_list  text;
BEGIN
  IF to_regclass('public.uq_telegram_signals_cycle_symbol') IS NOT NULL THEN
    RETURN;  -- already applied
  END IF;

  SELECT count(*),
         string_agg(format('%s / %s  (x%s, ids: %s)', scan_cycle_id, symbol, n, ids), E'\n')
    INTO dup_count, dup_list
    FROM (SELECT scan_cycle_id, symbol, count(*) AS n, string_agg(id::text, ',' ORDER BY id) AS ids
            FROM public.telegram_signals
           GROUP BY scan_cycle_id, symbol
          HAVING count(*) > 1) d;

  IF dup_count > 0 THEN
    RAISE EXCEPTION 'DUPLICATES FOUND in telegram_signals: % (scan_cycle_id, symbol) pair(s) occur more than once. Nothing was deleted and the unique index was NOT created. Review and remove the unwanted rows manually, then re-run this file. Duplicates: %',
      dup_count, replace(dup_list, E'\n', ' | ');
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_telegram_signals_cycle_symbol
  ON public.telegram_signals (scan_cycle_id, symbol);
