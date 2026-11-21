-- =====================================================================
-- T00b — checks for 002_signal_ingest.sql                         [P-04]
-- Run in a TEST project/branch, after 001 + 002. Ends with ROLLBACK.
-- =====================================================================
BEGIN;

DO $$
DECLARE
  c text;
  n integer;
BEGIN
  -- 1. new columns exist and are nullable
  FOREACH c IN ARRAY ARRAY['entry_min','entry_max','tp1_allocation','tp2_allocation',
                           'tp3_allocation','sl_distance_pct','total_score','cycle_timestamp'] LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='telegram_signals'
                      AND column_name=c AND is_nullable='YES') THEN
      RAISE EXCEPTION 'T00b: telegram_signals.% is missing or NOT NULL', c;
    END IF;
  END LOOP;

  -- 2. unique index on (scan_cycle_id, symbol)
  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                  WHERE indexname='uq_telegram_signals_cycle_symbol'
                    AND indexdef ILIKE 'CREATE UNIQUE%(scan_cycle_id, symbol)%') THEN
    RAISE EXCEPTION 'T00b: unique index on (scan_cycle_id, symbol) is missing';
  END IF;

  -- 3. re-inserting the same (cycle, symbol) with ON CONFLICT DO NOTHING adds nothing
  --    (this is what PostgREST resolution=ignore-duplicates does)
  INSERT INTO public.telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss)
    VALUES ('T00b-cycle', 'T00BUSDT', 1, 'LONG', 100, 95);
  INSERT INTO public.telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss)
    VALUES ('T00b-cycle', 'T00BUSDT', 1, 'LONG', 100, 95)
    ON CONFLICT (scan_cycle_id, symbol) DO NOTHING;
  SELECT count(*) INTO n FROM public.telegram_signals WHERE scan_cycle_id='T00b-cycle';
  IF n <> 1 THEN RAISE EXCEPTION 'T00b: re-run created % rows, expected 1', n; END IF;

  -- 4. a plain duplicate insert is rejected
  BEGIN
    INSERT INTO public.telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss)
      VALUES ('T00b-cycle', 'T00BUSDT', 1, 'LONG', 100, 95);
    RAISE EXCEPTION 'T00b: duplicate (cycle, symbol) was accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  -- 5. new fields accept the logger payload (percent allocations, ISO timestamp)
  INSERT INTO public.telegram_signals
    (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss,
     entry_min, entry_max, tp1_allocation, tp2_allocation, tp3_allocation,
     sl_distance_pct, total_score, cycle_timestamp)
  VALUES ('T00b-cycle', 'T00CUSDT', 2, 'SHORT', 100, 105,
          99.5, 100.5, 40, 40, 20, 1.234, 78.5, '2026-11-21T08:00:03.123Z');

  RAISE NOTICE 'T00b PASSED: signal ingest OK';
END $$;

ROLLBACK;
