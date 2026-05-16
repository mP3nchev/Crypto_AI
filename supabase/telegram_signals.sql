-- =====================================================
-- TABLE: telegram_signals
-- Записва всеки сигнал, изпратен към Telegram.
-- Използва се за performance tracking и backtest correlation.
-- Изпълни в Supabase → SQL Editor преди активиране на SIGNAL LOGGER.
-- =====================================================

CREATE TABLE telegram_signals (
  id                  SERIAL PRIMARY KEY,
  scan_cycle_id       VARCHAR        NOT NULL,
  symbol              VARCHAR        NOT NULL,
  tier                INTEGER        NOT NULL,
  signal_direction    VARCHAR        NOT NULL,   -- LONG / SHORT
  final_rank          INTEGER,

  -- Core trade levels
  entry_price         NUMERIC(18,8)  NOT NULL,
  stop_loss           NUMERIC(18,8)  NOT NULL,
  tp1                 NUMERIC(18,8),
  tp2                 NUMERIC(18,8),
  tp3                 NUMERIC(18,8),
  suggested_leverage  INTEGER,

  -- Analytics
  market_condition    VARCHAR,                   -- STRONG_TREND / NEUTRAL / RANGING
  fee_adjusted_rr     NUMERIC(6,3),
  atr_percentage_1h   NUMERIC(6,3),
  score_snapshot      JSONB,                     -- scores + weights snapshot

  -- Signal classification
  tp_strategy         VARCHAR,                   -- STRONG_TREND / MODERATE_TREND / WEAK_RANGING
  entry_quality       VARCHAR,                   -- EXCELLENT / GOOD / FAIR
  signal_strength     VARCHAR,                   -- VERY_STRONG / STRONG / MEDIUM / WEAK
  confidence_level    VARCHAR,                   -- VERY_HIGH / HIGH / MEDIUM / LOW

  sent_at             TIMESTAMPTZ    DEFAULT NOW(),
  created_at          TIMESTAMPTZ    DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_ts_symbol      ON telegram_signals(symbol);
CREATE INDEX idx_ts_cycle       ON telegram_signals(scan_cycle_id);
CREATE INDEX idx_ts_condition   ON telegram_signals(market_condition);
CREATE INDEX idx_ts_sent_at     ON telegram_signals(sent_at DESC);
CREATE INDEX idx_ts_direction   ON telegram_signals(signal_direction);

-- Полезни queries за бъдещ performance tracking:
--
-- Колко сигнала на цикъл средно:
--   SELECT scan_cycle_id, COUNT(*) FROM telegram_signals GROUP BY 1 ORDER BY 1 DESC LIMIT 20;
--
-- R/R разпределение по пазарен режим:
--   SELECT market_condition, AVG(fee_adjusted_rr), COUNT(*) FROM telegram_signals GROUP BY 1;
--
-- Score snapshot за конкретен сигнал:
--   SELECT symbol, score_snapshot->'total' AS total, score_snapshot->'weights' AS weights
--   FROM telegram_signals WHERE scan_cycle_id = '<id>';
