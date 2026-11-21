import { describe, expect, it } from 'vitest';
import { EMPTY_FILTERS, filterQuery, hasActiveFilters, parseFilters, toRpcParams, writeFilters } from '../src/lib/filters';

describe('URL filters -> RPC params', () => {
  it('empty URL means "all" (NULL params)', () => {
    const f = parseFilters(new URLSearchParams(''));
    expect(f).toEqual(EMPTY_FILTERS);
    expect(toRpcParams(f)).toEqual({ p_symbols: null, p_categories: null, p_direction: null, p_tiers: null });
    expect(hasActiveFilters(f)).toBe(false);
  });

  it('parses, normalises and de-duplicates', () => {
    const f = parseFilters(new URLSearchParams('symbols=ethusdt,BTCUSDT,ETHUSDT&cat=btc&dir=short&tier=3,1,x,1'));
    expect(f).toEqual({ symbols: ['BTCUSDT', 'ETHUSDT'], categories: ['BTC'], direction: 'SHORT', tiers: [1, 3] });
    expect(toRpcParams(f)).toEqual({
      p_symbols: ['BTCUSDT', 'ETHUSDT'], p_categories: ['BTC'], p_direction: 'SHORT', p_tiers: [1, 3],
    });
  });

  it('drops invalid values instead of sending them to SQL', () => {
    const f = parseFilters(new URLSearchParams("symbols=BTC'USDT,OK1&dir=UP&tier=0,99"));
    expect(f.symbols).toEqual(['OK1']);
    expect(f.direction).toBeNull();
    expect(f.tiers).toEqual([]);
  });

  it('round-trips through the URL and keeps unrelated params', () => {
    const f = { symbols: ['SOLUSDT'], categories: [], direction: 'LONG' as const, tiers: [2] };
    const sp = writeFilters(new URLSearchParams('date=2026-11-05&dir=SHORT'), f);
    expect(sp.get('date')).toBe('2026-11-05');
    expect(parseFilters(sp)).toEqual(f);
    expect(sp.has('cat')).toBe(false);
  });

  it('builds a link query with extra params', () => {
    expect(filterQuery(EMPTY_FILTERS)).toBe('');
    expect(filterQuery({ ...EMPTY_FILTERS, tiers: [1] }, { date: '2026-11-05' })).toBe('?tier=1&date=2026-11-05');
  });
});
