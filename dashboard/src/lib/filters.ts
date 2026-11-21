// Global filters live in the URL query (spec P-24) and map 1:1 to RPC params.
import type { Direction } from './types';

export interface Filters {
  symbols: string[];
  categories: string[];
  direction: Direction | null;
  tiers: number[];
}

export const EMPTY_FILTERS: Filters = { symbols: [], categories: [], direction: null, tiers: [] };

const KEYS = { symbols: 'symbols', categories: 'cat', direction: 'dir', tiers: 'tier' } as const;

function uniq<T>(xs: T[]): T[] {
  return [...new Set(xs)];
}

function list(v: string | null): string[] {
  if (!v) return [];
  return [...new Set(v.split(',').map((s) => s.trim()).filter(Boolean))];
}

export function parseFilters(sp: URLSearchParams): Filters {
  const symbols = uniq(list(sp.get(KEYS.symbols)).map((s) => s.toUpperCase()))
    .filter((s) => /^[A-Z0-9]{2,20}$/.test(s));
  const categories = uniq(list(sp.get(KEYS.categories)).map((s) => s.toUpperCase()))
    .filter((s) => /^[A-Z0-9_]{1,30}$/.test(s));
  const dirRaw = (sp.get(KEYS.direction) ?? '').toUpperCase();
  const direction = dirRaw === 'LONG' || dirRaw === 'SHORT' ? dirRaw : null;
  const tiers = uniq(list(sp.get(KEYS.tiers)).map(Number))
    .filter((n) => Number.isInteger(n) && n >= 1 && n <= 9)
    .sort((a, b) => a - b);
  return { symbols: symbols.sort(), categories: categories.sort(), direction, tiers };
}

/** Writes filters into a copy of `base`, keeping unrelated params (date, month, …). */
export function writeFilters(base: URLSearchParams, f: Filters): URLSearchParams {
  const sp = new URLSearchParams(base);
  const set = (k: string, v: string) => (v ? sp.set(k, v) : sp.delete(k));
  set(KEYS.symbols, [...f.symbols].sort().join(','));
  set(KEYS.categories, [...f.categories].sort().join(','));
  set(KEYS.direction, f.direction ?? '');
  set(KEYS.tiers, [...f.tiers].sort((a, b) => a - b).join(','));
  return sp;
}

export interface RpcFilterParams {
  p_symbols: string[] | null;
  p_categories: string[] | null;
  p_direction: Direction | null;
  p_tiers: number[] | null;
}

/** Empty selections become NULL (= all), exactly as the SQL functions expect. */
export function toRpcParams(f: Filters): RpcFilterParams {
  return {
    p_symbols: f.symbols.length ? f.symbols : null,
    p_categories: f.categories.length ? f.categories : null,
    p_direction: f.direction,
    p_tiers: f.tiers.length ? f.tiers : null,
  };
}

export function hasActiveFilters(f: Filters): boolean {
  return f.symbols.length > 0 || f.categories.length > 0 || f.direction !== null || f.tiers.length > 0;
}

/** Only the filter part of the query string, for links between screens. */
export function filterQuery(f: Filters, extra: Record<string, string> = {}): string {
  const sp = writeFilters(new URLSearchParams(), f);
  for (const [k, v] of Object.entries(extra)) sp.set(k, v);
  const s = sp.toString();
  return s ? `?${s}` : '';
}
