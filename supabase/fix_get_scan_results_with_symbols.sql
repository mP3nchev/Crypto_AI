-- =====================================================
-- FIX: get_scan_results_with_symbols
-- =====================================================
-- Проблем: старото RPC селектираше само 10 колони от scan_results/crypto_symbols.
-- В резултат Row 3 получаваше само rsi_2h, adx_2h, ema_200_2h — всички scoring
-- branches даваха 0 (current_atr_1h=0, momentum_score=0, volatility=UNKNOWN и т.н.)
--
-- Fix: JOIN latest_scan_results (всички TAAPI индикатори) +
--           latest_candles (close/high/low цени за entry zone / ATR%) +
--           crypto_symbols (rank_position за tier assignment)
--
-- Резултат: "Fetch Data AFTER TAAPI" вика този RPC с един GET и
-- получава всичко необходимо за Row 3 scoring без промени на canvas-а.
-- =====================================================

CREATE OR REPLACE FUNCTION get_scan_results_with_symbols(p_scan_cycle_id text)
RETURNS TABLE (
  -- ── Идентификация ──────────────────────────────────
  id                  integer,
  symbol_id           integer,
  symbol              character varying,
  scan_cycle_id       character varying,
  scan_time           timestamp with time zone,
  scan_date           date,
  cycle_timestamp     timestamp with time zone,

  -- ── Rank / Tier (от crypto_symbols) ────────────────
  rank_position       integer,

  -- ── 2h TAAPI индикатори ─────────────────────────────
  rsi_2h              numeric,
  macd_value_2h       numeric,
  macd_signal_2h      numeric,
  macd_histogram_2h   numeric,
  adx_2h              numeric,
  ema_200_2h          numeric,
  ema_20_2h           numeric,
  ema_50_2h           numeric,
  stochrsi_k_2h       numeric,
  stochrsi_d_2h       numeric,
  willr_2h            numeric,
  mfi_2h              numeric,

  -- ── 1h TAAPI индикатори ─────────────────────────────
  rsi_1h              numeric,
  macd_value_1h       numeric,
  macd_signal_1h      numeric,
  macd_histogram_1h   numeric,
  vwap_1h             numeric,
  obv_1h              numeric,
  atr_1h              numeric,
  bbw_1h              numeric,
  ema_20_1h           numeric,
  ema_50_1h           numeric,
  stochrsi_k_1h       numeric,
  stochrsi_d_1h       numeric,

  -- ── 15m TAAPI индикатори ────────────────────────────
  willr_15m           numeric,
  rsi_15m             numeric,

  -- ── SMA ─────────────────────────────────────────────
  sma_20              numeric,

  -- ── Цени от latest_candles (2h candle) ─────────────
  close_price         numeric,
  high_price          numeric,
  low_price           numeric,
  volume              numeric,

  -- ── Metadata ────────────────────────────────────────
  created_at          timestamp with time zone
)
LANGUAGE sql STABLE AS $$
  SELECT
    sr.id,
    sr.symbol_id,
    sr.symbol,
    sr.scan_cycle_id,
    sr.scan_time,
    sr.scan_date,
    sr.cycle_timestamp,

    -- rank_position от crypto_symbols (текущ цикъл)
    cs.rank_position,

    -- 2h индикатори
    sr.rsi_2h,
    sr.macd_value_2h,
    sr.macd_signal_2h,
    sr.macd_histogram_2h,
    sr.adx_2h,
    sr.ema_200_2h,
    sr.ema_20_2h,
    sr.ema_50_2h,
    sr.stochrsi_k_2h,
    sr.stochrsi_d_2h,
    sr.willr_2h,
    sr.mfi_2h,

    -- 1h индикатори
    sr.rsi_1h,
    sr.macd_value_1h,
    sr.macd_signal_1h,
    sr.macd_histogram_1h,
    sr.vwap_1h,
    sr.obv_1h,
    sr.atr_1h,
    sr.bbw_1h,
    sr.ema_20_1h,
    sr.ema_50_1h,
    sr.stochrsi_k_1h,
    sr.stochrsi_d_1h,

    -- 15m индикатори
    sr.willr_15m,
    sr.rsi_15m,

    -- SMA
    sr.sma_20,

    -- Цени (latest 2h candle за същия цикъл)
    lc.close_price,
    lc.high_price,
    lc.low_price,
    lc.volume,

    sr.created_at

  FROM latest_scan_results sr

  -- rank_position: JOIN по symbol (scan_cycle_id в crypto_symbols е last активен)
  LEFT JOIN crypto_symbols cs
    ON cs.symbol = sr.symbol
    AND cs.scan_cycle_id = p_scan_cycle_id

  -- Цени: latest 2h candle за същия цикъл
  LEFT JOIN latest_candles lc
    ON lc.symbol    = sr.symbol
    AND lc.interval = '2h'
    AND lc.scan_cycle_id = p_scan_cycle_id

  WHERE sr.scan_cycle_id = p_scan_cycle_id

  ORDER BY cs.rank_position ASC NULLS LAST;
$$;
