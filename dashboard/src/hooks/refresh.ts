import { createContext } from 'react';

/** Incremented by the header "Refresh" button and every 5 minutes. */
export const RefreshContext = createContext<{ tick: number; refresh: () => void; lastRefresh: Date }>({
  tick: 0,
  refresh: () => undefined,
  lastRefresh: new Date(),
});
