import { useCallback, useMemo } from 'react';
import { useSearchParams } from 'react-router-dom';
import { parseFilters, writeFilters, type Filters } from '../lib/filters';

/** Filters are kept in the URL so they survive reloads and apply to every screen. */
export function useFilters(): [Filters, (f: Filters) => void] {
  const [sp, setSp] = useSearchParams();
  const key = sp.toString();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const filters = useMemo(() => parseFilters(sp), [key]);
  const setFilters = useCallback(
    (f: Filters) => setSp((prev) => writeFilters(prev, f), { replace: true }),
    [setSp],
  );
  return [filters, setFilters];
}

/** One extra URL param (date, month, tab, …) next to the filters. */
export function useQueryParam(name: string): [string | null, (v: string | null) => void] {
  const [sp, setSp] = useSearchParams();
  const value = sp.get(name);
  const set = useCallback(
    (v: string | null) =>
      setSp((prev) => {
        const next = new URLSearchParams(prev);
        if (v === null || v === '') next.delete(name); else next.set(name, v);
        return next;
      }, { replace: true }),
    [name, setSp],
  );
  return [value, set];
}
