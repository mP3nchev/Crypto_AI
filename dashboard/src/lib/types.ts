// Shapes returned by Supabase (see supabase/paper_trading/004_analytics.sql, 006_dashboard.sql).
// All money / percent values are computed in SQL; the browser only formats them.

export type Direction = 'LONG' | 'SHORT';
export type PositionStatus = 'OPEN' | 'CLOSED' | 'SKIPPED' | 'REJECTED';
export type Outcome = 'WIN' | 'LOSS' | 'BREAKEVEN';

export interface Position {
  id: number;
  signal_id: number;
  scan_cycle_id: string | null;
  symbol: string;
  tier: number | null;
  category: string | null;
  direction: Direction | null;
  status: PositionStatus;
  status_reason: string | null;
  related_position_id: number | null;
  signal_entry_price: number | null;
  entry_min: number | null;
  entry_max: number | null;
  stop_loss: number | null;
  tp1: number | null;
  tp2: number | null;
  tp3: number | null;
  alloc1: number | null;
  alloc2: number | null;
  alloc3: number | null;
  signal_leverage: number | null;
  total_score: number | null;
  market_condition: string | null;
  tp_strategy: string | null;
  fee_adjusted_rr: number | null;
  entry_fill_price: number | null;
  leverage: number | null;
  margin_usd: number | null;
  notional_usd: number | null;
  quantity: number | null;
  liquidation_price: number | null;
  effective_stop: number | null;
  stop_capped_by_liquidation: boolean;
  be_active: boolean;
  config_snapshot: Record<string, unknown> | null;
  opened_at: string | null;
  eval_start_open_time: string | null;
  last_evaluated_open_time: string | null;
  closed_at: string | null;
  remaining_pct: number;
  tp_hits: number;
  realized_gross_usd: number;
  fees_usd: number;
  funding_usd: number;
  realized_net_usd: number;
  return_on_margin_pct: number | null;
  exit_reason: string | null;
  exit_summary: string | null;
  duration_hours: number | null;
  has_data_gap: boolean;
  created_at: string;
  // view columns
  closed_date_local: string | null;
  opened_date_local: string | null;
  outcome: Outcome | null;
  avg_exit_price: number | null;
  price_move_pct: number | null;
  partially_realized_net_usd: number | null;
  last_price: number | null;
  last_price_candle: string | null;
  indicative_unrealized_usd: number | null;
  hours_open: number | null;
}

export interface PositionEvent {
  id: number;
  position_id: number;
  event_type: string;
  tranche: number | null;
  candle_open_time: string | null;
  level_price: number | null;
  fill_price: number | null;
  qty: number | null;
  pct_of_position: number | null;
  gross_usd: number | null;
  fees_usd: number | null;
  net_usd: number | null;
  details: Record<string, unknown> | null;
  created_at: string;
}

export interface Stats {
  from: string | null;
  to: string | null;
  trades: number;
  wins: number;
  losses: number;
  breakeven: number;
  win_rate_pct: number;
  total_net_usd: number;
  total_return_pct: number | null;
  avg_win_usd: number | null;
  avg_loss_usd: number | null;
  profit_factor: number | null;
  expectancy_usd: number | null;
  avg_duration_hours: number | null;
  open_positions: number;
  skipped: number;
  rejected: number;
  partially_realized_usd: number;
  indicative_unrealized_usd: number;
  max_drawdown_pct: number;
  initial_capital_usd: number;
}

export interface DailyRow {
  day: string;
  trades: number;
  wins: number;
  losses: number;
  net_usd: number;
  cumulative_net_usd: number;
}

export interface MonthOverview {
  month: string;
  stats: Stats;
  trading_days: number;
  green_days: number;
  red_days: number;
  best_day_net_usd: number | null;
  best_day: string | null;
  worst_day_net_usd: number | null;
  worst_day: string | null;
  max_abs_day_net_usd: number;
}

export interface PortfolioSummary {
  initial_capital_usd: number;
  realized_net_usd: number;
  equity_usd: number;
  equity_return_pct: number | null;
  open_positions: number;
  open_margin_usd: number;
  open_notional_usd: number;
  exposure_pct: number | null;
  partially_realized_usd: number;
  indicative_unrealized_usd: number;
  indicative_unrealized_pct: number | null;
  signals_24h: number;
  opened_24h: number;
  skipped_24h: number;
  rejected_24h: number;
  opened_24h_pct: number | null;
  last_signal_at: string | null;
}

export interface BreakdownRow {
  segment: string;
  stats: Stats;
  small_sample: boolean;
}

export type BreakdownDimension = 'symbol' | 'category' | 'direction' | 'tier';

export interface Health {
  last_ok_run_at: string | null;
  last_ok_run_age_hours: number | null;
  last_run_status: string | null;
  last_run_error: string | null;
  stale_open_position_ids: number[];
  data_gap_position_ids: number[];
  internal_error_position_ids_24h: number[];
  signals_without_position_24h: number;
  open_positions: number;
  warning: boolean;
}

export interface PaperConfig {
  enabled: boolean;
  initial_capital_usd: number;
  sizing_mode: 'FIXED_MARGIN' | 'PERCENT_EQUITY';
  fixed_margin_usd: number;
  equity_pct: number;
  leverage_override: number | null;
  max_leverage: number;
  fee_rate: number;
  entry_slippage_pct: Record<string, number>;
  stop_slippage_pct: Record<string, number>;
  tp_slippage_pct: number;
  maintenance_margin_rate: number;
  max_holding_hours: number;
  max_open_positions: number;
  max_signal_age_minutes: number;
  move_sl_to_breakeven_after_tp1: boolean;
  notify_telegram_on_exit: boolean;
  timezone: string;
  config_version: number;
  updated_at: string;
}

export interface SymbolRow {
  symbol: string;
  category: string | null;
  positions: number;
}

export interface SymbolCategory {
  symbol: string;
  category: string;
}
