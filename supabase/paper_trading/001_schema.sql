-- =====================================================================
-- PAPER TRADING — 001_schema.sql                                  [P-02]
-- Persistent structures: configuration, positions, events, candles,
-- symbol categories and monitor run log.
--
-- Idempotent: safe to run repeatedly in Supabase -> SQL Editor.
-- Prerequisite: table public.telegram_signals (supabase/telegram_signals.sql).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Prerequisite check (stops with a clear error, spec rule 7)
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.telegram_signals') IS NULL THEN
    RAISE EXCEPTION
      'PAPER-TRADING PREREQUISITE MISSING: table public.telegram_signals does not exist. '
      'Run supabase/telegram_signals.sql first, then re-run this migration.';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 1. paper_config — single row (id = 1)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.paper_config (
  id                              integer      PRIMARY KEY DEFAULT 1,
  enabled                         boolean      NOT NULL DEFAULT true,
  initial_capital_usd             numeric      NOT NULL DEFAULT 1000,
  sizing_mode                     text         NOT NULL DEFAULT 'FIXED_MARGIN',
  fixed_margin_usd                numeric      NOT NULL DEFAULT 50,
  equity_pct                      numeric      NOT NULL DEFAULT 5,
  leverage_override               integer,
  max_leverage                    integer      NOT NULL DEFAULT 10,
  fee_rate                        numeric      NOT NULL DEFAULT 0.00055,
  entry_slippage_pct              jsonb        NOT NULL DEFAULT '{"1":0.05,"2":0.10,"3":0.20}'::jsonb,
  stop_slippage_pct               jsonb        NOT NULL DEFAULT '{"1":0.05,"2":0.10,"3":0.20}'::jsonb,
  tp_slippage_pct                 numeric      NOT NULL DEFAULT 0,
  maintenance_margin_rate         numeric      NOT NULL DEFAULT 0.005,
  max_holding_hours               integer      NOT NULL DEFAULT 72,
  max_open_positions              integer      NOT NULL DEFAULT 10,
  max_signal_age_minutes          integer      NOT NULL DEFAULT 45,
  move_sl_to_breakeven_after_tp1  boolean      NOT NULL DEFAULT false,
  notify_telegram_on_exit         boolean      NOT NULL DEFAULT false,
  timezone                        text         NOT NULL DEFAULT 'Europe/Sofia',
  config_version                  integer      NOT NULL DEFAULT 1,
  updated_at                      timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT paper_config_single_row   CHECK (id = 1),
  CONSTRAINT paper_config_sizing_mode  CHECK (sizing_mode IN ('FIXED_MARGIN','PERCENT_EQUITY')),
  CONSTRAINT paper_config_capital_pos  CHECK (initial_capital_usd > 0),
  CONSTRAINT paper_config_margin_pos   CHECK (fixed_margin_usd > 0),
  CONSTRAINT paper_config_pct_range    CHECK (equity_pct > 0 AND equity_pct <= 100),
  CONSTRAINT paper_config_leverage     CHECK (max_leverage >= 1
                                              AND (leverage_override IS NULL OR leverage_override >= 1)),
  CONSTRAINT paper_config_fee_range    CHECK (fee_rate >= 0 AND fee_rate < 0.01),
  CONSTRAINT paper_config_hold_pos     CHECK (max_holding_hours > 0),
  CONSTRAINT paper_config_caps_pos     CHECK (max_open_positions > 0 AND max_signal_age_minutes > 0)
);

-- Exactly one row, created with defaults on first run, never overwritten on re-run.
INSERT INTO public.paper_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- config_version is incremented on every change; updated_at maintained.
CREATE OR REPLACE FUNCTION public.paper_config_touch()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.config_version := OLD.config_version + 1;
  NEW.updated_at     := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS paper_config_touch ON public.paper_config;
CREATE TRIGGER paper_config_touch
  BEFORE UPDATE ON public.paper_config
  FOR EACH ROW
  WHEN (OLD.* IS DISTINCT FROM NEW.*)
  EXECUTE FUNCTION public.paper_config_touch();

-- ---------------------------------------------------------------------
-- 2. paper_symbol_categories
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.paper_symbol_categories (
  symbol    text PRIMARY KEY,
  category  text NOT NULL
);

INSERT INTO public.paper_symbol_categories (symbol, category) VALUES
  ('BTCUSDT', 'BTC'),
  ('ETHUSDT', 'ETH'),
  ('SOLUSDT', 'SOL')
ON CONFLICT (symbol) DO NOTHING;
-- A symbol with no entry gets category 'OTHER' when the position is opened.

-- ---------------------------------------------------------------------
-- 3. paper_positions — one row for EVERY signal (1:1)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.paper_positions (
  -- Identity
  id                          bigserial    PRIMARY KEY,
  signal_id                   integer      NOT NULL UNIQUE
                                           REFERENCES public.telegram_signals(id),
  scan_cycle_id               text,
  symbol                      text         NOT NULL,
  tier                        integer,
  category                    text,
  direction                   text,

  -- Status
  status                      text         NOT NULL,
  status_reason               text,
  related_position_id         bigint       REFERENCES public.paper_positions(id),

  -- Input levels (snapshot of the signal)
  signal_entry_price          numeric,
  entry_min                   numeric,
  entry_max                   numeric,
  stop_loss                   numeric,
  tp1                         numeric,
  tp2                         numeric,
  tp3                         numeric,
  alloc1                      numeric,      -- percent
  alloc2                      numeric,
  alloc3                      numeric,
  signal_leverage             integer,
  total_score                 numeric,
  market_condition            text,
  tp_strategy                 text,
  fee_adjusted_rr             numeric,

  -- Simulation
  entry_fill_price            numeric,
  leverage                    integer,
  margin_usd                  numeric,
  notional_usd                numeric,
  quantity                    numeric,
  liquidation_price           numeric,
  effective_stop              numeric,      -- SL after the liquidation check
  stop_capped_by_liquidation  boolean      NOT NULL DEFAULT false,
  be_active                   boolean      NOT NULL DEFAULT false,
  config_snapshot             jsonb,

  -- Time
  opened_at                   timestamptz,  -- = telegram_signals.sent_at
  eval_start_open_time        timestamptz,  -- start of the next full hour
  last_evaluated_open_time    timestamptz,  -- cursor, NULL initially
  closed_at                   timestamptz,

  -- Result (maintained by the evaluator)
  remaining_pct               numeric      NOT NULL DEFAULT 100,
  tp_hits                     integer      NOT NULL DEFAULT 0,
  realized_gross_usd          numeric      NOT NULL DEFAULT 0,
  fees_usd                    numeric      NOT NULL DEFAULT 0,
  funding_usd                 numeric      NOT NULL DEFAULT 0,  -- reserved
  realized_net_usd            numeric      NOT NULL DEFAULT 0,
  return_on_margin_pct        numeric,
  exit_reason                 text,
  exit_summary                text,         -- e.g. 'TP1+SL'
  duration_hours              numeric,
  has_data_gap                boolean      NOT NULL DEFAULT false,

  created_at                  timestamptz  NOT NULL DEFAULT now(),

  CONSTRAINT paper_positions_status_chk
    CHECK (status IN ('OPEN','CLOSED','SKIPPED','REJECTED')),
  CONSTRAINT paper_positions_direction_chk
    CHECK (direction IS NULL OR direction IN ('LONG','SHORT')),
  CONSTRAINT paper_positions_tp_hits_chk
    CHECK (tp_hits BETWEEN 0 AND 3),
  CONSTRAINT paper_positions_remaining_chk
    CHECK (remaining_pct >= 0 AND remaining_pct <= 100)
);

-- At most one OPEN position per symbol (last line of defence, P-08)
CREATE UNIQUE INDEX IF NOT EXISTS uq_paper_positions_open_symbol
  ON public.paper_positions (symbol) WHERE status = 'OPEN';

CREATE INDEX IF NOT EXISTS idx_paper_positions_closed_at
  ON public.paper_positions (closed_at);
CREATE INDEX IF NOT EXISTS idx_paper_positions_status
  ON public.paper_positions (status);
CREATE INDEX IF NOT EXISTS idx_paper_positions_symbol_closed
  ON public.paper_positions (symbol, closed_at);

-- ---------------------------------------------------------------------
-- 4. paper_position_events — one event per fill or state change
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.paper_position_events (
  id               bigserial    PRIMARY KEY,
  position_id      bigint       NOT NULL
                                REFERENCES public.paper_positions(id) ON DELETE CASCADE,
  event_type       text         NOT NULL,
  tranche          integer,
  candle_open_time timestamptz,
  level_price      numeric,
  fill_price       numeric,
  qty              numeric,
  pct_of_position  numeric,
  gross_usd        numeric,
  fees_usd         numeric,
  net_usd          numeric,
  details          jsonb,
  created_at       timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT paper_events_type_chk CHECK (event_type IN (
    'OPENED','TP1','TP2','TP3','SL','BREAKEVEN_SL','TIMEOUT','LIQUIDATION',
    'DATA_UNAVAILABLE','BE_ACTIVATED','DATA_GAP','ERROR')),
  CONSTRAINT paper_events_tranche_chk CHECK (tranche IS NULL OR tranche BETWEEN 1 AND 3)
);

-- UNIQUE(position_id, event_type, tranche): nothing is executed twice.
-- coalesce() makes NULL tranches (OPENED, SL, ...) unique too, which a plain
-- UNIQUE constraint would not (NULLs are distinct).
CREATE UNIQUE INDEX IF NOT EXISTS uq_paper_events_position_type_tranche
  ON public.paper_position_events (position_id, event_type, (coalesce(tranche, 0)));

CREATE INDEX IF NOT EXISTS idx_paper_events_position
  ON public.paper_position_events (position_id, created_at);

-- ---------------------------------------------------------------------
-- 5. paper_candles — 1h only
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.paper_candles (
  symbol       text         NOT NULL,
  open_time    timestamptz  NOT NULL,
  close_time   timestamptz  NOT NULL,
  open         numeric      NOT NULL,
  high         numeric      NOT NULL,
  low          numeric      NOT NULL,
  close        numeric      NOT NULL,
  volume       numeric,
  ingested_at  timestamptz  NOT NULL DEFAULT now(),
  PRIMARY KEY (symbol, open_time)
);

-- ---------------------------------------------------------------------
-- 6. paper_monitor_runs
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.paper_monitor_runs (
  id                   bigserial    PRIMARY KEY,
  started_at           timestamptz  NOT NULL DEFAULT now(),
  finished_at          timestamptz,
  status               text         NOT NULL,
  positions_evaluated  integer      NOT NULL DEFAULT 0,
  candles_used         integer      NOT NULL DEFAULT 0,
  events_created       integer      NOT NULL DEFAULT 0,
  positions_closed     integer      NOT NULL DEFAULT 0,
  error                text,
  CONSTRAINT paper_monitor_runs_status_chk
    CHECK (status IN ('OK','PARTIAL','ERROR','SKIPPED_LOCKED'))
);

CREATE INDEX IF NOT EXISTS idx_paper_monitor_runs_started
  ON public.paper_monitor_runs (started_at DESC);
