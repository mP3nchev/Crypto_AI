import { useCallback, useEffect, useMemo, useState } from 'react';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { Layout } from './components/Layout';
import { Login } from './components/Login';
import { RefreshContext } from './hooks/refresh';
import { useSession } from './hooks/useSession';
import { AnalyticsPage } from './pages/AnalyticsPage';
import { CalendarPage } from './pages/CalendarPage';
import { DailyPage } from './pages/DailyPage';
import { PositionsPage } from './pages/PositionsPage';

const AUTO_REFRESH_MS = 5 * 60 * 1000; // the monitor runs hourly; 5 min is plenty

export function App() {
  const session = useSession();
  const [tick, setTick] = useState(0);
  const [lastRefresh, setLastRefresh] = useState(new Date());
  const refresh = useCallback(() => { setTick((t) => t + 1); setLastRefresh(new Date()); }, []);

  useEffect(() => {
    if (session.status !== 'signed-in') return;
    const id = window.setInterval(() => { if (!document.hidden) refresh(); }, AUTO_REFRESH_MS);
    return () => window.clearInterval(id);
  }, [session.status, refresh]);

  const ctx = useMemo(() => ({ tick, refresh, lastRefresh }), [tick, refresh, lastRefresh]);

  if (session.status === 'loading') {
    return (
      <div className="min-h-screen flex items-center justify-center text-slate-400 text-sm" role="status">
        <i className="fa-solid fa-circle-notch fa-spin mr-2" aria-hidden />Loading…
      </div>
    );
  }
  if (session.status === 'signed-out') return <Login expired={session.expired} />;

  return (
    <RefreshContext.Provider value={ctx}>
      <BrowserRouter>
        <Routes>
          <Route element={<Layout email={session.email} />}>
            <Route index element={<DailyPage />} />
            <Route path="calendar" element={<CalendarPage />} />
            <Route path="positions" element={<PositionsPage />} />
            <Route path="analytics" element={<AnalyticsPage />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Route>
        </Routes>
      </BrowserRouter>
    </RefreshContext.Provider>
  );
}
