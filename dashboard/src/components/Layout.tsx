// App shell from the design: sticky header, status pills, tab navigation, health warning bar.
import { useContext } from 'react';
import { NavLink, Outlet } from 'react-router-dom';
import { getConfig, getHealth } from '../lib/api';
import { filterQuery } from '../lib/filters';
import { formatDateTime, formatNumber, formatTime } from '../lib/format';
import { supabase, usingDevToken } from '../lib/supabase';
import { useAsync } from '../hooks/useAsync';
import { useFilters } from '../hooks/useFilters';
import { RefreshContext } from '../hooks/refresh';
import { FilterBar } from './FilterBar';
import type { Health } from '../lib/types';

function MonitorPill({ health }: { health: Health | undefined | null }) {
  if (!health) {
    return (
      <div className="flex items-center gap-2 px-3 py-1.5 rounded-xl bg-surface border border-borderSubtle text-xs">
        <span className="h-2 w-2 rounded-full bg-slate-500" />
        <span className="text-slate-300 font-medium">Monitor</span>
        <span className="font-mono text-[11px] text-slate-500">…</span>
      </div>
    );
  }
  const age = health.last_ok_run_age_hours;
  const ok = !health.warning;
  const label = age === null ? 'NO RUN YET' : age < 1 ? `${Math.max(1, Math.round(age * 60))}m ago` : `${formatNumber(age, 1)}h ago`;
  return (
    <div className="flex items-center gap-2 px-3 py-1.5 rounded-xl bg-surface border border-borderSubtle text-xs" title={health.last_ok_run_at ? `Last OK run: ${formatDateTime(health.last_ok_run_at)}` : 'No successful monitor run yet'}>
      <span className="relative flex h-2 w-2">
        {ok && <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-emeraldNeon opacity-75" />}
        <span className={`relative inline-flex rounded-full h-2 w-2 ${ok ? 'bg-emeraldNeon' : 'bg-amberWarn'}`} />
      </span>
      <span className="text-slate-300 font-medium">Monitor</span>
      <span className={`font-mono text-[11px] ${ok ? 'text-emeraldNeon' : 'text-amberWarn'}`}>{ok ? 'OK' : 'CHECK'} · {label}</span>
    </div>
  );
}

function HealthBanner({ health }: { health: Health }) {
  const issues: string[] = [];
  if (health.last_ok_run_age_hours === null && health.open_positions > 0) issues.push('the paper monitor has not completed a successful run yet');
  else if (health.last_ok_run_age_hours !== null && health.last_ok_run_age_hours > 3) issues.push(`last successful monitor run was ${formatNumber(health.last_ok_run_age_hours, 1)} h ago`);
  if (health.stale_open_position_ids.length) issues.push(`${health.stale_open_position_ids.length} open position(s) not evaluated for > 3 h`);
  if (health.internal_error_position_ids_24h.length) issues.push(`${health.internal_error_position_ids_24h.length} signal(s) rejected with INTERNAL_ERROR in the last 24 h`);
  if (health.signals_without_position_24h > 0) issues.push(`${health.signals_without_position_24h} signal(s) without a paper position in the last 24 h`);
  if (!issues.length) return null;
  return (
    <div className="max-w-[1600px] mx-auto px-4 sm:px-6 lg:px-8 pt-4">
      <div className="rounded-xl border border-amberWarn/40 bg-amberWarn/10 px-4 py-3 text-xs text-amberWarn flex items-start gap-2.5" role="alert">
        <i className="fa-solid fa-triangle-exclamation mt-0.5" aria-hidden />
        <div>
          <p className="font-semibold">Paper trading needs attention</p>
          <ul className="list-disc ml-4 mt-0.5 text-amberWarn/90">{issues.map((i) => <li key={i}>{i}</li>)}</ul>
          {health.last_run_status && health.last_run_status !== 'OK' && (
            <p className="mt-1 font-mono text-[11px] text-amberWarn/80 break-words">Last run: {health.last_run_status}{health.last_run_error ? ` — ${health.last_run_error}` : ''}</p>
          )}
        </div>
      </div>
    </div>
  );
}

const TABS = [
  { to: '/positions', label: 'Live Signals & Open Positions', short: 'Positions', icon: 'fa-solid fa-satellite-dish', hover: 'group-hover:text-electricBlue' },
  { to: '/', label: 'Daily Performance', short: 'Daily', icon: 'fa-solid fa-chart-line', hover: 'group-hover:text-emeraldNeon' },
  { to: '/calendar', label: 'Monthly Calendar', short: 'Calendar', icon: 'fa-regular fa-calendar-days', hover: 'group-hover:text-electricBlue' },
  { to: '/analytics', label: 'Analytics & Segmentation', short: 'Analytics', icon: 'fa-solid fa-layer-group', hover: 'group-hover:text-purple-400' },
];

export function Layout({ email }: { email: string | null }) {
  const [filters] = useFilters();
  const { refresh, lastRefresh } = useContext(RefreshContext);
  const health = useAsync(getHealth, []);
  const config = useAsync(getConfig, []);
  const q = filterQuery(filters);

  return (
    <div className="min-h-screen flex flex-col">
      <header className="sticky top-0 z-30 bg-[#0B0E14]/90 backdrop-blur-md border-b border-borderSubtle">
        <div className="max-w-[1600px] mx-auto px-4 sm:px-6 lg:px-8">
          <div className="flex flex-wrap items-center justify-between py-3.5 gap-3">
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-electricBlue to-indigo-600 flex items-center justify-center shadow-lg shadow-electricBlue/20">
                <i className="fa-solid fa-wave-square text-white text-lg" aria-hidden />
              </div>
              <div>
                <div className="flex items-center gap-2">
                  <h1 className="text-base sm:text-lg font-bold tracking-tight text-white">Crypto AI</h1>
                  <span className="text-[10px] font-mono uppercase tracking-wider px-2 py-0.5 rounded-full bg-electricBlue/15 text-electricBlue border border-electricBlue/30">
                    Paper Trading{config.data ? ` · cfg v${config.data.config_version}` : ''}
                  </span>
                </div>
                <p className="text-xs text-slate-400 hidden sm:block">Virtual 30-day test of the live signal pipeline</p>
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2 sm:gap-3">
              <MonitorPill health={health.data} />
              {config.data && (
                <div className="hidden md:flex items-center gap-2 px-3 py-1.5 rounded-xl bg-surface border border-borderSubtle text-xs" title="Telegram messages for paper exits (paper_config.notify_telegram_on_exit). Change it in Supabase.">
                  <i className="fa-brands fa-telegram text-sky-400 text-sm" aria-hidden />
                  <span className="text-slate-300 font-medium">Exit Alerts</span>
                  <span className={`font-mono text-[11px] font-semibold ${config.data.notify_telegram_on_exit ? 'text-sky-400' : 'text-slate-500'}`}>{config.data.notify_telegram_on_exit ? 'ON' : 'OFF'}</span>
                </div>
              )}
              {config.data && !config.data.enabled && (
                <span className="px-3 py-1.5 rounded-xl bg-amberWarn/10 border border-amberWarn/30 text-amberWarn text-xs font-mono">ENGINE DISABLED</span>
              )}
              <button onClick={refresh} title={`Last refresh ${formatTime(lastRefresh.toISOString())}`}
                className="flex items-center gap-2 px-3.5 py-2 rounded-xl bg-electricBlue hover:bg-blue-600 active:scale-[0.98] text-white text-xs font-semibold shadow-lg shadow-electricBlue/25 transition-all cursor-pointer">
                <i className="fa-solid fa-rotate-right" aria-hidden /><span className="hidden sm:inline">Refresh</span>
              </button>
              {!usingDevToken && supabase && (
                <button onClick={() => supabase!.auth.signOut()} title={email ? `Signed in as ${email}` : 'Sign out'}
                  className="w-9 h-9 rounded-xl bg-surface border border-borderSubtle hover:border-slate-500 text-slate-300 flex items-center justify-center cursor-pointer" aria-label="Sign out">
                  <i className="fa-solid fa-right-from-bracket text-xs" aria-hidden />
                </button>
              )}
            </div>
          </div>

          <nav className="flex items-center gap-1 sm:gap-2 overflow-x-auto pt-1 -mb-px" aria-label="Dashboard sections">
            {TABS.map((t) => (
              <NavLink key={t.to} to={{ pathname: t.to, search: q }} end
                className={({ isActive }) =>
                  `group flex items-center gap-2 px-3 sm:px-4 py-3 text-xs sm:text-sm border-b-2 whitespace-nowrap transition-all ${
                    isActive ? 'border-electricBlue text-white font-semibold' : 'border-transparent text-slate-400 hover:text-slate-200 font-medium'
                  }`}>
                {({ isActive }) => (
                  <>
                    <i className={`${t.icon} ${isActive ? 'text-electricBlue' : `text-slate-400 ${t.hover}`} transition-colors`} aria-hidden />
                    <span className="hidden md:inline">{t.label}</span>
                    <span className="md:hidden">{t.short}</span>
                    {t.to === '/positions' && health.data && (
                      <span className="ml-1 px-2 py-0.5 text-[11px] font-mono rounded-full bg-electricBlue/20 text-electricBlue">{health.data.open_positions}</span>
                    )}
                  </>
                )}
              </NavLink>
            ))}
          </nav>
        </div>
      </header>

      {health.data && <HealthBanner health={health.data} />}

      <main className="flex-1 max-w-[1600px] w-full mx-auto px-4 sm:px-6 lg:px-8 py-6 space-y-6">
        <FilterBar />
        <Outlet />
      </main>

      <footer className="max-w-[1600px] w-full mx-auto px-4 sm:px-6 lg:px-8 pb-6 text-[11px] text-slate-600 flex flex-wrap gap-x-4 gap-y-1">
        <span>All figures are computed in Supabase · times in Europe/Sofia</span>
        <span>Exits are simulated on closed 1h candles (stop first on ambiguous candles)</span>
        <span>Last refresh {formatTime(lastRefresh.toISOString())}</span>
      </footer>
    </div>
  );
}
