import { useCallback, useContext, useEffect, useRef, useState, type DependencyList } from 'react';
import { RefreshContext } from './refresh';

export interface AsyncState<T> {
  data: T | undefined;
  error: Error | null;
  loading: boolean;
  reload: () => void;
}

/**
 * Runs `fn` when `deps` change and on every global refresh tick.
 * Keeps the previous data while reloading (no flicker), ignores stale responses.
 */
export function useAsync<T>(fn: () => Promise<T>, deps: DependencyList): AsyncState<T> {
  const { tick } = useContext(RefreshContext);
  const [data, setData] = useState<T>();
  const [error, setError] = useState<Error | null>(null);
  const [loading, setLoading] = useState(true);
  const [local, setLocal] = useState(0);
  const seq = useRef(0);

  useEffect(() => {
    const id = ++seq.current;
    setLoading(true);
    setError(null);
    fn()
      .then((d) => { if (id === seq.current) setData(d); })
      .catch((e: unknown) => { if (id === seq.current) setError(e instanceof Error ? e : new Error(String(e))); })
      .finally(() => { if (id === seq.current) setLoading(false); });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick, local]);

  const reload = useCallback(() => setLocal((n) => n + 1), []);
  return { data, error, loading, reload };
}
