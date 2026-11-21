-- =====================================================================
-- T00 — structure check for 001_schema.sql                        [P-02]
-- Read-only. Aborts with RAISE EXCEPTION on any mismatch.
-- Run in a TEST project/branch (see tests/README.md), after 001_schema.sql.
-- =====================================================================
BEGIN;

DO $$
DECLARE
  t text;
  n integer;
  expected jsonb := '{
    "paper_config": 21,
    "paper_positions": 51,
    "paper_position_events": 14,
    "paper_candles": 9,
    "paper_symbol_categories": 2,
    "paper_monitor_runs": 9
  }'::jsonb;
BEGIN
  -- 1. tables exist with the expected column count
  FOR t IN SELECT jsonb_object_keys(expected) LOOP
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = t;
    IF n = 0 THEN
      RAISE EXCEPTION 'T00: table % is missing', t;
    ELSIF n <> (expected ->> t)::int THEN
      RAISE EXCEPTION 'T00: table % has % columns, expected %', t, n, expected ->> t;
    END IF;
  END LOOP;

  -- 2. paper_config: exactly one row, id = 1, defaults per spec
  SELECT count(*) INTO n FROM public.paper_config;
  IF n <> 1 THEN RAISE EXCEPTION 'T00: paper_config has % rows, expected 1', n; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.paper_config
                  WHERE id = 1 AND fee_rate = 0.00055 AND max_holding_hours = 72
                    AND sizing_mode = 'FIXED_MARGIN' AND fixed_margin_usd = 50
                    AND initial_capital_usd = 1000 AND timezone = 'Europe/Sofia'
                    AND entry_slippage_pct = '{"1":0.05,"2":0.10,"3":0.20}'::jsonb) THEN
    RAISE EXCEPTION 'T00: paper_config defaults do not match the spec';
  END IF;

  -- 3. second config row is impossible
  BEGIN
    INSERT INTO public.paper_config (id) VALUES (2);
    RAISE EXCEPTION 'T00: second paper_config row was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- 4. required indexes
  FOREACH t IN ARRAY ARRAY[
    'uq_paper_positions_open_symbol',
    'idx_paper_positions_closed_at',
    'idx_paper_positions_status',
    'idx_paper_positions_symbol_closed',
    'uq_paper_events_position_type_tranche'] LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      RAISE EXCEPTION 'T00: index % is missing', t;
    END IF;
  END LOOP;

  -- the open-symbol index must be UNIQUE and PARTIAL
  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                  WHERE indexname = 'uq_paper_positions_open_symbol'
                    AND indexdef ILIKE 'CREATE UNIQUE%'
                    AND indexdef ILIKE '%WHERE%OPEN%') THEN
    RAISE EXCEPTION 'T00: uq_paper_positions_open_symbol is not a unique partial index on status=OPEN';
  END IF;

  -- 5. signal_id is UNIQUE with an FK to telegram_signals
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.paper_positions'::regclass AND contype = 'u'
                    AND conkey = ARRAY[(SELECT attnum FROM pg_attribute
                                         WHERE attrelid = 'public.paper_positions'::regclass
                                           AND attname = 'signal_id')]) THEN
    RAISE EXCEPTION 'T00: paper_positions.signal_id is not UNIQUE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.paper_positions'::regclass AND contype = 'f'
                    AND confrelid = 'public.telegram_signals'::regclass) THEN
    RAISE EXCEPTION 'T00: paper_positions has no FK to telegram_signals';
  END IF;

  -- 6. category seeds
  SELECT count(*) INTO n FROM public.paper_symbol_categories
   WHERE (symbol, category) IN (('BTCUSDT','BTC'),('ETHUSDT','ETH'),('SOLUSDT','SOL'));
  IF n <> 3 THEN RAISE EXCEPTION 'T00: category seeds missing (found %/3)', n; END IF;

  -- 7. config_version increments on change, not on no-op
  UPDATE public.paper_config SET fixed_margin_usd = fixed_margin_usd WHERE id = 1;
  IF (SELECT config_version FROM public.paper_config) <> 1 THEN
    RAISE EXCEPTION 'T00: config_version changed on a no-op update';
  END IF;
  UPDATE public.paper_config SET fixed_margin_usd = 60 WHERE id = 1;
  IF (SELECT config_version FROM public.paper_config) <> 2 THEN
    RAISE EXCEPTION 'T00: config_version did not increment on change';
  END IF;

  -- 8. events: duplicate (position, type, NULL tranche) is rejected
  INSERT INTO public.telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss)
    VALUES ('T00', 'T00USDT', 1, 'LONG', 100, 95);
  INSERT INTO public.paper_positions (signal_id, symbol, status)
    SELECT id, symbol, 'OPEN' FROM public.telegram_signals WHERE scan_cycle_id = 'T00';
  INSERT INTO public.paper_position_events (position_id, event_type)
    SELECT id, 'OPENED' FROM public.paper_positions WHERE symbol = 'T00USDT';
  BEGIN
    INSERT INTO public.paper_position_events (position_id, event_type)
      SELECT id, 'OPENED' FROM public.paper_positions WHERE symbol = 'T00USDT';
    RAISE EXCEPTION 'T00: duplicate OPENED event was accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  -- 9. only one OPEN position per symbol
  INSERT INTO public.telegram_signals (scan_cycle_id, symbol, tier, signal_direction, entry_price, stop_loss)
    VALUES ('T00b', 'T00USDT', 1, 'LONG', 100, 95);
  BEGIN
    INSERT INTO public.paper_positions (signal_id, symbol, status)
      SELECT id, symbol, 'OPEN' FROM public.telegram_signals WHERE scan_cycle_id = 'T00b';
    RAISE EXCEPTION 'T00: second OPEN position for the same symbol was accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  RAISE NOTICE 'T00 PASSED: schema structure OK';
END $$;

ROLLBACK;
