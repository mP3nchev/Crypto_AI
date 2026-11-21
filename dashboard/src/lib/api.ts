// All data access. Every number shown in the UI comes from these calls;
// the browser never computes money or percentages (spec P-22).
import type { PostgrestError } from '@supabase/supabase-js';
import { requireClient } from './supabase';
import { toRpcParams, type Filters } from './filters';
import type {
  BreakdownDimension, BreakdownRow, DailyRow, Health, MonthOverview, PaperConfig,
  PortfolioSummary, Position, PositionEvent, PositionStatus, Stats, SymbolCategory, SymbolRow,
} from './types';

export const SESSION_EXPIRED_EVENT = 'paper:session-expired';

export class ApiError extends Error {
  constructor(message: string, public code?: string, public isAuth = false) {
    super(message);
  }
}

function fail(error: PostgrestError | { message: string; code?: string }): never {
  const code = error.code ?? '';
  const msg = error.message ?? 'Unknown error';
  const isAuth = code === 'PGRST301' || code === 'PGRST302' || /jwt|expired|not authenticated/i.test(msg);
  if (isAuth) window.dispatchEvent(new Event(SESSION_EXPIRED_EVENT));
  throw new ApiError(msg, code, isAuth);
}

async function rpc<T>(fn: string, params: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await requireClient().rpc(fn, params);
  if (error) fail(error);
  return data as T;
}

// Supabase query builders are deeply generic; a narrow structural type is enough here.
interface Filterable<Q> {
  in(column: string, values: readonly unknown[]): Q;
  eq(column: string, value: unknown): Q;
}

function applyFilters<Q extends Filterable<Q>>(q: Q, f: Filters): Q {
  let out = q;
  if (f.symbols.length) out = out.in('symbol', f.symbols);
  if (f.categories.length) out = out.in('category', f.categories);
  if (f.direction) out = out.eq('direction', f.direction);
  if (f.tiers.length) out = out.in('tier', f.tiers);
  return out;
}

// ---- configuration / health ------------------------------------------------
export async function getConfig(): Promise<PaperConfig | null> {
  const { data, error } = await requireClient().from('paper_config').select('*').eq('id', 1).maybeSingle();
  if (error) fail(error);
  return data as PaperConfig | null;
}

export async function getHealth(): Promise<Health | null> {
  const { data, error } = await requireClient().from('paper_health_v').select('*').maybeSingle();
  if (error) fail(error);
  return data as Health | null;
}

export async function getSymbols(): Promise<SymbolRow[]> {
  return (await rpc<SymbolRow[]>('paper_symbols')) ?? [];
}

export async function getCategoryMap(): Promise<SymbolCategory[]> {
  const { data, error } = await requireClient().from('paper_symbol_categories').select('*').order('symbol');
  if (error) fail(error);
  return (data ?? []) as SymbolCategory[];
}

// ---- aggregates (SQL) ----------------------------------------------------------
export function getSummary(f: Filters): Promise<PortfolioSummary> {
  return rpc<PortfolioSummary>('paper_portfolio_summary', { ...toRpcParams(f) });
}

export function getStats(from: string | null, to: string | null, f: Filters): Promise<Stats> {
  return rpc<Stats>('paper_stats', { p_from: from, p_to: to, ...toRpcParams(f) });
}

export async function getDailyPnl(monthStart: string, f: Filters): Promise<DailyRow[]> {
  return (await rpc<DailyRow[]>('paper_daily_pnl', { p_month: monthStart, ...toRpcParams(f) })) ?? [];
}

export function getMonthOverview(monthStart: string, f: Filters): Promise<MonthOverview> {
  return rpc<MonthOverview>('paper_month_overview', { p_month: monthStart, ...toRpcParams(f) });
}

export async function getBreakdown(
  dimension: BreakdownDimension, from: string | null, to: string | null, f: Filters,
): Promise<BreakdownRow[]> {
  return (await rpc<BreakdownRow[]>('paper_stats_breakdown', {
    p_dimension: dimension, p_from: from, p_to: to, ...toRpcParams(f),
  })) ?? [];
}

// ---- positions (paper_positions_v) ----------------------------------------------
export type PositionSort = 'opened_desc' | 'opened_asc' | 'closed_desc' | 'net_desc' | 'net_asc';

const SORTS: Record<PositionSort, { column: string; ascending: boolean }> = {
  opened_desc: { column: 'opened_at', ascending: false },
  opened_asc: { column: 'opened_at', ascending: true },
  closed_desc: { column: 'closed_at', ascending: false },
  net_desc: { column: 'realized_net_usd', ascending: false },
  net_asc: { column: 'realized_net_usd', ascending: true },
};

export interface PositionQuery {
  filters: Filters;
  statuses?: PositionStatus[];
  closedDate?: string;
  sort?: PositionSort;
  offset?: number;
  limit?: number;
  withCount?: boolean;
}

export async function listPositions(q: PositionQuery): Promise<{ rows: Position[]; count: number | null }> {
  const sort = SORTS[q.sort ?? 'opened_desc'];
  let query = requireClient()
    .from('paper_positions_v')
    .select('*', q.withCount ? { count: 'exact' } : undefined);
  query = applyFilters(query, q.filters);
  if (q.statuses?.length) query = query.in('status', q.statuses);
  if (q.closedDate) query = query.eq('closed_date_local', q.closedDate);
  query = query.order(sort.column, { ascending: sort.ascending, nullsFirst: false }).order('id', { ascending: false });
  const offset = q.offset ?? 0;
  const limit = q.limit ?? 50;
  const { data, error, count } = await query.range(offset, offset + limit - 1);
  if (error) fail(error);
  return { rows: (data ?? []) as Position[], count: count ?? null };
}

export async function getPosition(id: number): Promise<Position | null> {
  const { data, error } = await requireClient().from('paper_positions_v').select('*').eq('id', id).maybeSingle();
  if (error) fail(error);
  return data as Position | null;
}

export async function getEvents(positionId: number): Promise<PositionEvent[]> {
  const { data, error } = await requireClient()
    .from('paper_position_events')
    .select('*')
    .eq('position_id', positionId)
    .order('id', { ascending: true });
  if (error) fail(error);
  return (data ?? []) as PositionEvent[];
}
