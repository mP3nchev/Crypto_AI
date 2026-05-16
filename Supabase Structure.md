| table_name          | column_name            | data_type                |
| ------------------- | ---------------------- | ------------------------ |
| asset_tiers         | id                     | integer                  |
| asset_tiers         | symbol_id              | integer                  |
| asset_tiers         | symbol                 | character varying        |
| asset_tiers         | tier                   | integer                  |
| asset_tiers         | tier_name              | character varying        |
| asset_tiers         | rank_position          | integer                  |
| asset_tiers         | atr_threshold_low      | numeric                  |
| asset_tiers         | atr_threshold_high     | numeric                  |
| asset_tiers         | current_atr_1h         | numeric                  |
| asset_tiers         | atr_percentage_1h      | numeric                  |
| asset_tiers         | volatility_status      | character varying        |
| asset_tiers         | volatility_score       | numeric                  |
| asset_tiers         | volatility_warning     | boolean                  |
| asset_tiers         | risk_level             | character varying        |
| asset_tiers         | max_suggested_leverage | numeric                  |
| asset_tiers         | cycle_timestamp        | timestamp with time zone |
| asset_tiers         | scan_cycle_id          | character varying        |
| asset_tiers         | processed_at           | timestamp with time zone |
| asset_tiers         | updated_at             | timestamp with time zone |
| crypto_symbols      | id                     | integer                  |
| crypto_symbols      | symbol                 | character varying        |
| crypto_symbols      | symbol_ticker          | character varying        |
| crypto_symbols      | base_asset             | character varying        |
| crypto_symbols      | quote_asset            | character varying        |
| crypto_symbols      | exchange               | character varying        |
| crypto_symbols      | volume                 | numeric                  |
| crypto_symbols      | quote_volume           | numeric                  |
| crypto_symbols      | rank_position          | integer                  |
| crypto_symbols      | cycle_timestamp        | timestamp with time zone |
| crypto_symbols      | scan_cycle_id          | character varying        |
| crypto_symbols      | date_added             | date                     |
| crypto_symbols      | is_active              | boolean                  |
| crypto_symbols      | processed_at           | timestamp with time zone |
| crypto_symbols      | created_at             | timestamp with time zone |
| crypto_symbols      | first_seen_at          | timestamp with time zone |
| crypto_symbols      | last_seen_at           | timestamp with time zone |
| crypto_symbols      | consecutive_absences   | integer                  |
| latest_candles      | symbol                 | character varying        |
| latest_candles      | interval               | character varying        |
| latest_candles      | open_time              | bigint                   |
| latest_candles      | close_time             | bigint                   |
| latest_candles      | open_price             | numeric                  |
| latest_candles      | high_price             | numeric                  |
| latest_candles      | low_price              | numeric                  |
| latest_candles      | close_price            | numeric                  |
| latest_candles      | volume                 | numeric                  |
| latest_candles      | cycle_timestamp        | timestamp with time zone |
| latest_candles      | scan_cycle_id          | character varying        |
| latest_scan_results | id                     | integer                  |
| latest_scan_results | symbol_id              | integer                  |
| latest_scan_results | symbol                 | character varying        |
| latest_scan_results | cycle_timestamp        | timestamp with time zone |
| latest_scan_results | scan_cycle_id          | character varying        |
| latest_scan_results | scan_time              | timestamp with time zone |
| latest_scan_results | scan_date              | date                     |
| latest_scan_results | rsi_2h                 | numeric                  |
| latest_scan_results | macd_value_2h          | numeric                  |
| latest_scan_results | macd_signal_2h         | numeric                  |
| latest_scan_results | macd_histogram_2h      | numeric                  |
| latest_scan_results | adx_2h                 | numeric                  |
| latest_scan_results | ema_200_2h             | numeric                  |
| latest_scan_results | stochrsi_k_2h          | numeric                  |
| latest_scan_results | stochrsi_d_2h          | numeric                  |
| latest_scan_results | willr_2h               | numeric                  |
| latest_scan_results | mfi_2h                 | numeric                  |
| latest_scan_results | ema_20_2h              | numeric                  |
| latest_scan_results | ema_50_2h              | numeric                  |
| latest_scan_results | sma_20                 | numeric                  |
| latest_scan_results | rsi_1h                 | numeric                  |
| latest_scan_results | macd_value_1h          | numeric                  |
| latest_scan_results | macd_signal_1h         | numeric                  |
| latest_scan_results | macd_histogram_1h      | numeric                  |
| latest_scan_results | vwap_1h                | numeric                  |
| latest_scan_results | obv_1h                 | numeric                  |
| latest_scan_results | atr_1h                 | numeric                  |
| latest_scan_results | bbw_1h                 | numeric                  |
| latest_scan_results | ema_20_1h              | numeric                  |
| latest_scan_results | ema_50_1h              | numeric                  |
| latest_scan_results | stochrsi_k_1h          | numeric                  |
| latest_scan_results | stochrsi_d_1h          | numeric                  |
| latest_scan_results | willr_15m              | numeric                  |
| latest_scan_results | rsi_15m                | numeric                  |
| latest_scan_results | momentum_score         | numeric                  |
| latest_scan_results | trend_score            | numeric                  |
| latest_scan_results | volatility_score       | numeric                  |
| latest_scan_results | volume_score           | numeric                  |
| latest_scan_results | total_score            | numeric                  |
| latest_scan_results | signal_strength        | character varying        |
| latest_scan_results | signal_direction       | character varying        |
| latest_scan_results | confidence_level       | character varying        |
| latest_scan_results | suggested_leverage     | numeric                  |
| latest_scan_results | entry_price            | numeric                  |
| latest_scan_results | stop_loss              | numeric                  |
| latest_scan_results | take_profit            | numeric                  |
| latest_scan_results | risk_reward_ratio      | numeric                  |
| latest_scan_results | scan_duration_ms       | integer                  |
| latest_scan_results | created_at             | timestamp with time zone |
| latest_scan_results | price_action_score     | numeric                  |
| latest_scan_results | risk_reward_score      | numeric                  |
| latest_symbols      | id                     | integer                  |
| latest_symbols      | symbol                 | character varying        |
| latest_symbols      | symbol_ticker          | character varying        |
| latest_symbols      | base_asset             | character varying        |
| latest_symbols      | quote_asset            | character varying        |
| latest_symbols      | exchange               | character varying        |
| latest_symbols      | volume                 | numeric                  |
| latest_symbols      | quote_volume           | numeric                  |
| latest_symbols      | rank_position          | integer                  |
| latest_symbols      | cycle_timestamp        | timestamp with time zone |
| latest_symbols      | scan_cycle_id          | character varying        |
| latest_symbols      | date_added             | date                     |
| latest_symbols      | is_active              | boolean                  |
| latest_symbols      | processed_at           | timestamp with time zone |
| latest_symbols      | created_at             | timestamp with time zone |
| latest_symbols      | first_seen_at          | timestamp with time zone |
| latest_symbols      | last_seen_at           | timestamp with time zone |
| latest_symbols      | consecutive_absences   | integer                  |
| raw_candles_data    | id                     | integer                  |
| raw_candles_data    | symbol_id              | integer                  |
| raw_candles_data    | symbol                 | character varying        |
| raw_candles_data    | interval               | character varying        |
| raw_candles_data    | cycle_timestamp        | timestamp with time zone |
| raw_candles_data    | scan_cycle_id          | character varying        |
| raw_candles_data    | timestamp              | timestamp with time zone |
| raw_candles_data    | open_time              | bigint                   |
| raw_candles_data    | close_time             | bigint                   |
| raw_candles_data    | open_price             | numeric                  |
| raw_candles_data    | high_price             | numeric                  |
| raw_candles_data    | low_price              | numeric                  |
| raw_candles_data    | close_price            | numeric                  |
| raw_candles_data    | volume                 | numeric                  |
| raw_candles_data    | processed_at           | timestamp with time zone |
| raw_candles_data    | median_volume_1h       | numeric                  |
| raw_candles_data    | median_volume_2h       | numeric                  |
| raw_candles_data    | latest_1m_price        | numeric                  |
| scan_results        | id                     | integer                  |
| scan_results        | symbol_id              | integer                  |
| scan_results        | symbol                 | character varying        |
| scan_results        | cycle_timestamp        | timestamp with time zone |
| scan_results        | scan_cycle_id          | character varying        |
| scan_results        | scan_time              | timestamp with time zone |
| scan_results        | scan_date              | date                     |
| scan_results        | rsi_2h                 | numeric                  |
| scan_results        | macd_value_2h          | numeric                  |
| scan_results        | macd_signal_2h         | numeric                  |
| scan_results        | macd_histogram_2h      | numeric                  |
| scan_results        | adx_2h                 | numeric                  |
| scan_results        | ema_200_2h             | numeric                  |
| scan_results        | stochrsi_k_2h          | numeric                  |
| scan_results        | stochrsi_d_2h          | numeric                  |
| scan_results        | willr_2h               | numeric                  |
| scan_results        | mfi_2h                 | numeric                  |
| scan_results        | ema_20_2h              | numeric                  |
| scan_results        | ema_50_2h              | numeric                  |
| scan_results        | sma_20                 | numeric                  |
| scan_results        | rsi_1h                 | numeric                  |
| scan_results        | macd_value_1h          | numeric                  |
| scan_results        | macd_signal_1h         | numeric                  |
| scan_results        | macd_histogram_1h      | numeric                  |
| scan_results        | vwap_1h                | numeric                  |
| scan_results        | obv_1h                 | numeric                  |
| scan_results        | atr_1h                 | numeric                  |
| scan_results        | bbw_1h                 | numeric                  |
| scan_results        | ema_20_1h              | numeric                  |
| scan_results        | ema_50_1h              | numeric                  |
| scan_results        | stochrsi_k_1h          | numeric                  |
| scan_results        | stochrsi_d_1h          | numeric                  |
| scan_results        | willr_15m              | numeric                  |
| scan_results        | rsi_15m                | numeric                  |
| scan_results        | momentum_score         | numeric                  |
| scan_results        | trend_score            | numeric                  |
| scan_results        | volatility_score       | numeric                  |
| scan_results        | volume_score           | numeric                  |
| scan_results        | total_score            | numeric                  |
| scan_results        | signal_strength        | character varying        |
| scan_results        | signal_direction       | character varying        |
| scan_results        | confidence_level       | character varying        |
| scan_results        | suggested_leverage     | numeric                  |
| scan_results        | entry_price            | numeric                  |
| scan_results        | stop_loss              | numeric                  |
| scan_results        | take_profit            | numeric                  |
| scan_results        | risk_reward_ratio      | numeric                  |
| scan_results        | scan_duration_ms       | integer                  |
| scan_results        | created_at             | timestamp with time zone |
| scan_results        | price_action_score     | numeric                  |
| scan_results        | risk_reward_score      | numeric                  |
| telegram_signals    | id                     | integer                  |
| telegram_signals    | scan_cycle_id          | character varying        |
| telegram_signals    | symbol                 | character varying        |
| telegram_signals    | tier                   | integer                  |
| telegram_signals    | signal_direction       | character varying        |
| telegram_signals    | final_rank             | integer                  |
| telegram_signals    | entry_price            | numeric                  |
| telegram_signals    | stop_loss              | numeric                  |
| telegram_signals    | tp1                    | numeric                  |
| telegram_signals    | tp2                    | numeric                  |
| telegram_signals    | tp3                    | numeric                  |
| telegram_signals    | suggested_leverage     | integer                  |
| telegram_signals    | market_condition       | character varying        |
| telegram_signals    | fee_adjusted_rr        | numeric                  |
| telegram_signals    | atr_percentage_1h      | numeric                  |
| telegram_signals    | score_snapshot         | jsonb                    |
| telegram_signals    | tp_strategy            | character varying        |
| telegram_signals    | entry_quality          | character varying        |
| telegram_signals    | signal_strength        | character varying        |
| telegram_signals    | confidence_level       | character varying        |
| telegram_signals    | sent_at                | timestamp with time zone |
| telegram_signals    | created_at             | timestamp with time zone |
| v_last_20_candles   | id                     | integer                  |
| v_last_20_candles   | symbol_id              | integer                  |
| v_last_20_candles   | symbol                 | character varying        |
| v_last_20_candles   | interval               | character varying        |
| v_last_20_candles   | cycle_timestamp        | timestamp with time zone |
| v_last_20_candles   | scan_cycle_id          | character varying        |
| v_last_20_candles   | timestamp              | timestamp with time zone |
| v_last_20_candles   | open_time              | bigint                   |
| v_last_20_candles   | close_time             | bigint                   |
| v_last_20_candles   | open_price             | numeric                  |
| v_last_20_candles   | high_price             | numeric                  |
| v_last_20_candles   | low_price              | numeric                  |
| v_last_20_candles   | close_price            | numeric                  |
| v_last_20_candles   | volume                 | numeric                  |
| v_last_20_candles   | processed_at           | timestamp with time zone |
| v_last_20_candles   | rn                     | bigint                   |