// "Day" screen (spec P-24 #1, design tab "Daily Performance").
import { useState } from 'react';
import { getStats, listPositions } from '../lib/api';
import { isValidDay, shiftDay } from '../lib/calendar';
import { toRpcParams } from '../lib/filters';
import { formatLongDate, formatNumber, formatPct, formatUsd, sofiaDate, toneClass } from '../lib/format';
import { useAsync } from '../hooks/useAsync';
import { useFilters, useQueryParam } from '../hooks/useFilters';
import { PositionModal } from '../components/PositionModal';
import { TradesTable } from '../components/TradesTable';
import { AsyncBlock, Card, Empty, ErrorState, KpiCard, Loading } from '../components/ui';

export function DailyPage() {
  const [filters] = useFilters();
  const [dateParam, setDate] = useQueryParam('date');
  const today = sofiaDate();
  const day = isValidDay(dateParam) ? dateParam : today;
  const [openId, setOpenId] = useState<number | null>(null);
  const fkey = JSON.stringify(toRpcParams(filters));

  const stats = useAsync(() => getStats(day, day, filters), [day, fkey]);
  const trades = useAsync(() => listPositions({ filters, statuses: ['CLOSED'], closedDate: day, sort: 'closed_desc', limit: 500 }), [day, fkey]);

  const go = (d: string) => setDate(d === today ? null : d);

  return (
    <section className="space-y-6">
      <Card className="p-4 sm:p-5 flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h2 className="text-lg font-bold text-white">Daily Trading Performance</h2>
          <p className="text-xs text-slate-400 mt-0.5">Positions fully closed on <span className="text-slate-200">{formatLongDate(day)}</span> (Europe/Sofia).</p>
        </div>
        <div className="flex items-center gap-2">
          <button onClick={() => go(shiftDay(day, -1))} aria-label="Previous day" className="w-9 h-9 rounded-xl bg-obsidian border border-borderSubtle hover:border-slate-500 flex items-center justify-center text-slate-300 cursor-pointer">
            <i className="fa-solid fa-chevron-left text-xs" aria-hidden />
          </button>
          <label htmlFor="dailyDate" className="sr-only">Session date</label>
          <input id="dailyDate" type="date" value={day} max={today} onChange={(e) => isValidDay(e.target.value) && go(e.target.value)}
            className="bg-obsidian border border-borderSubtle focus:border-electricBlue rounded-xl px-3 py-2 text-xs sm:text-sm font-mono text-white focus:outline-none [color-scheme:dark]" />
          <button onClick={() => go(shiftDay(day, 1))} disabled={day >= today} aria-label="Next day" className="w-9 h-9 rounded-xl bg-obsidian border border-borderSubtle enabled:hover:border-slate-500 disabled:opacity-40 flex items-center justify-center text-slate-300 cursor-pointer disabled:cursor-default">
            <i className="fa-solid fa-chevron-right text-xs" aria-hidden />
          </button>
          {day !== today && <button onClick={() => go(today)} className="px-3 py-2 rounded-xl bg-obsidian border border-borderSubtle hover:border-electricBlue text-xs text-slate-200 cursor-pointer">Today</button>}
        </div>
      </Card>

      {stats.error ? <Card><ErrorState error={stats.error} onRetry={stats.reload} /></Card> : !stats.data ? <Card><Loading rows={2} /></Card> : (
        <>
          <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
            <KpiCard label="Total Trades" value={stats.data.trades} sub="Fully closed positions" />
            <KpiCard label="Winning Trades" value={stats.data.wins} valueClass="text-emeraldNeon" sub={`Breakeven: ${stats.data.breakeven}`} />
            <KpiCard label="Losing Trades" value={stats.data.losses} valueClass="text-crimsonNeon" sub="Net loss > $0.01" />
            <KpiCard label="Win Rate" value={formatPct(stats.data.win_rate_pct)} valueClass={stats.data.trades === 0 ? 'text-slate-300' : stats.data.win_rate_pct >= 50 ? 'text-emeraldNeon' : 'text-amberWarn'} sub="Wins / trades" />
            <KpiCard label="Net Result" value={formatUsd(stats.data.total_net_usd, { sign: true })} valueClass={toneClass(stats.data.total_net_usd)} sub="After fees & slippage" />
            <KpiCard label="Return" value={formatPct(stats.data.total_return_pct, { sign: true })} valueClass={toneClass(stats.data.total_return_pct)} sub={`On ${formatUsd(stats.data.initial_capital_usd)} initial capital`} />
            <KpiCard label="Avg Win" value={formatUsd(stats.data.avg_win_usd, { sign: true })} valueClass="text-emeraldNeon" sub="Mean winning trade" />
            <KpiCard label="Avg Loss" value={formatUsd(stats.data.avg_loss_usd, { sign: true })} valueClass="text-crimsonNeon" sub="Mean losing trade" />
          </div>
          {(stats.data.partially_realized_usd !== 0 || stats.data.open_positions > 0) && (
            <p className="text-[11px] text-slate-500 -mt-2">
              Not in the daily result: {stats.data.open_positions} open position(s) with {formatUsd(stats.data.partially_realized_usd, { sign: true })} partially realized
              and {formatUsd(stats.data.indicative_unrealized_usd, { sign: true })} indicative unrealized P&L.
              {stats.data.trades > 0 && ` Profit factor ${formatNumber(stats.data.profit_factor)}, expectancy ${formatUsd(stats.data.expectancy_usd, { sign: true })}.`}
            </p>
          )}
        </>
      )}

      <Card className="overflow-hidden shadow-xl">
        <div className="p-4 sm:p-5 border-b border-borderSubtle flex flex-col sm:flex-row sm:items-center justify-between gap-2">
          <div>
            <h3 className="text-base font-bold text-white">Executed & Closed Trades</h3>
            <p className="text-xs text-slate-400">Click a row to inspect the full trade anatomy and event timeline.</p>
          </div>
          {trades.data && <span className="self-start text-xs font-mono text-slate-400 bg-obsidian px-3 py-1 rounded-lg border border-borderSubtle">Showing {trades.data.rows.length} trades</span>}
        </div>
        <AsyncBlock state={trades} rows={4}>
          {(d) => d.rows.length ? <TradesTable rows={d.rows} onOpen={setOpenId} /> : <Empty />}
        </AsyncBlock>
      </Card>

      <PositionModal id={openId} onClose={() => setOpenId(null)} />
    </section>
  );
}
