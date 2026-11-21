// "Calendar" screen (spec P-24 #2, design tab "Monthly Calendar").
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { getDailyPnl, getMonthOverview, listPositions } from '../lib/api';
import { dayStyle, dayTone, isValidDay, isValidMonth, monthGrid, monthOf, monthStart, shiftMonth } from '../lib/calendar';
import { filterQuery, toRpcParams } from '../lib/filters';
import { formatLongDate, formatMonth, formatPct, formatUsd, sofiaDate, toneClass } from '../lib/format';
import type { DailyRow } from '../lib/types';
import { useAsync } from '../hooks/useAsync';
import { useFilters, useQueryParam } from '../hooks/useFilters';
import { PositionModal } from '../components/PositionModal';
import { TradesTable } from '../components/TradesTable';
import { AsyncBlock, Card, Empty, ErrorState, Loading } from '../components/ui';

const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

function Tile({ label, value, cls = 'text-white' }: { label: string; value: React.ReactNode; cls?: string }) {
  return (
    <div className="bg-obsidian/70 border border-borderSubtle rounded-xl p-3 min-w-0">
      <p className="text-[11px] text-slate-400 uppercase truncate">{label}</p>
      <p className={`mt-1 text-base sm:text-lg font-bold font-mono truncate ${cls}`}>{value}</p>
    </div>
  );
}

function DayCell({ row, maxAbs, selected, isToday, onSelect }: { row: DailyRow; maxAbs: number; selected: boolean; isToday: boolean; onSelect: () => void }) {
  const tone = dayTone(row.net_usd, row.trades, maxAbs);
  const dayNum = Number(row.day.slice(8));
  const base = tone.kind === 'win' || tone.kind === 'loss' ? '' : 'bg-obsidian/70 border-borderSubtle hover:border-slate-600';
  return (
    <button onClick={onSelect} style={dayStyle(tone)} aria-pressed={selected}
      aria-label={`${row.day}: ${row.trades} trades, net ${formatUsd(row.net_usd, { sign: true })}`}
      className={`min-h-[92px] lg:min-h-[104px] rounded-xl border p-2 sm:p-2.5 flex flex-col justify-between text-left transition-all cursor-pointer hover:brightness-125 ${base} ${selected ? 'ring-2 ring-electricBlue' : ''}`}>
      <div className="flex items-center justify-between w-full">
        <span className={`font-mono text-xs font-bold ${selected ? 'text-electricBlue' : isToday ? 'text-white underline' : 'text-slate-300'}`}>{dayNum}</span>
        {row.trades > 0 && <span className="text-[10px] font-mono px-1.5 rounded bg-obsidian/80 text-slate-400">{row.trades}t</span>}
      </div>
      {row.trades > 0 ? (
        <div className="mt-2 min-w-0">
          <div className={`font-mono text-xs lg:text-sm font-bold truncate ${toneClass(row.net_usd)}`}>{formatUsd(row.net_usd, { sign: true })}</div>
          <div className="font-mono text-[10px] text-slate-500 truncate" title="Cumulative net since the 1st of the month">Σ {formatUsd(row.cumulative_net_usd, { sign: true })}</div>
        </div>
      ) : (
        <div className="text-[10px] text-slate-600 font-mono">No trades</div>
      )}
    </button>
  );
}

export function CalendarPage() {
  const [filters] = useFilters();
  const [monthParam, setMonth] = useQueryParam('month');
  const [dayParam, setDay] = useQueryParam('day');
  const navigate = useNavigate();
  const today = sofiaDate();
  const month = isValidMonth(monthParam) ? monthParam : monthOf(today);
  const selected = isValidDay(dayParam) && monthOf(dayParam) === month ? dayParam : monthOf(today) === month ? today : null;
  const [openId, setOpenId] = useState<number | null>(null);
  const fkey = JSON.stringify(toRpcParams(filters));

  const overview = useAsync(() => getMonthOverview(monthStart(month), filters), [month, fkey]);
  const daily = useAsync(() => getDailyPnl(monthStart(month), filters), [month, fkey]);
  const dayTrades = useAsync(
    () => (selected ? listPositions({ filters, statuses: ['CLOSED'], closedDate: selected, sort: 'closed_desc', limit: 500 }) : Promise.resolve({ rows: [], count: 0 })),
    [selected, fkey],
  );

  const changeMonth = (delta: number) => { setDay(null); setMonth(shiftMonth(month, delta) === monthOf(today) ? null : shiftMonth(month, delta)); };
  const maxAbs = overview.data?.max_abs_day_net_usd ?? 0;
  const { leading } = monthGrid(month);
  const selRow = daily.data?.find((d) => d.day === selected);

  return (
    <section className="space-y-6">
      <Card className="p-4 sm:p-5 space-y-5">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <button onClick={() => changeMonth(-1)} aria-label="Previous month" className="w-9 h-9 rounded-xl bg-obsidian border border-borderSubtle hover:border-slate-500 flex items-center justify-center text-slate-300 cursor-pointer">
              <i className="fa-solid fa-chevron-left text-xs" aria-hidden />
            </button>
            <div className="min-w-[170px] text-center">
              <h2 className="text-lg font-bold text-white">{formatMonth(month)}</h2>
              <p className="text-[11px] text-slate-400">Click a day to inspect its closed trades</p>
            </div>
            <button onClick={() => changeMonth(1)} aria-label="Next month" className="w-9 h-9 rounded-xl bg-obsidian border border-borderSubtle hover:border-slate-500 flex items-center justify-center text-slate-300 cursor-pointer">
              <i className="fa-solid fa-chevron-right text-xs" aria-hidden />
            </button>
          </div>
          <div className="flex flex-wrap items-center gap-4 text-xs">
            <span className="flex items-center gap-1.5"><span className="w-3 h-3 rounded bg-emeraldNeon/30 border border-emeraldNeon" />Profitable day</span>
            <span className="flex items-center gap-1.5"><span className="w-3 h-3 rounded bg-crimsonNeon/30 border border-crimsonNeon" />Loss day</span>
            <span className="flex items-center gap-1.5 text-slate-400"><span className="w-3 h-3 rounded bg-obsidian border border-borderSubtle" />No trades / flat</span>
          </div>
        </div>

        {overview.error ? <ErrorState error={overview.error} onRetry={overview.reload} /> : !overview.data ? <Loading rows={1} /> : (
          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3 pt-3 border-t border-borderSubtle">
            <Tile label="Monthly Net" value={formatUsd(overview.data.stats.total_net_usd, { sign: true })} cls={toneClass(overview.data.stats.total_net_usd)} />
            <Tile label="Monthly Return" value={formatPct(overview.data.stats.total_return_pct, { sign: true })} cls={toneClass(overview.data.stats.total_return_pct)} />
            <Tile label="Trades · Win Rate" value={<>{overview.data.stats.trades} <span className="text-slate-500">·</span> {formatPct(overview.data.stats.win_rate_pct, { digits: 1 })}</>} />
            <Tile label="Green vs Red Days" value={<><span className="text-emeraldNeon">{overview.data.green_days}W</span> / <span className="text-crimsonNeon">{overview.data.red_days}L</span></>} />
            <Tile label="Best Session" value={formatUsd(overview.data.best_day_net_usd ?? 0, { sign: true })} cls="text-emeraldNeon" />
            <Tile label="Worst Session" value={formatUsd(overview.data.worst_day_net_usd ?? 0, { sign: true })} cls="text-crimsonNeon" />
          </div>
        )}
      </Card>

      <Card className="p-3 sm:p-5">
        <AsyncBlock state={daily} rows={5}>
          {(rows) => (
            <>
              {/* desktop / tablet: 7-column grid */}
              <div className="hidden sm:block">
                <div className="grid grid-cols-7 gap-2 mb-2 text-center text-[11px] font-semibold uppercase tracking-wider text-slate-400">
                  {WEEKDAYS.map((d) => <div key={d}>{d}</div>)}
                </div>
                <div className="grid grid-cols-7 gap-2">
                  {Array.from({ length: leading }).map((_, i) => <div key={`e${i}`} className="min-h-[92px] lg:min-h-[104px] rounded-xl bg-obsidian/30 border border-borderSubtle/30" />)}
                  {rows.map((r) => (
                    <DayCell key={r.day} row={r} maxAbs={maxAbs} selected={r.day === selected} isToday={r.day === today} onSelect={() => setDay(r.day)} />
                  ))}
                </div>
              </div>
              {/* mobile: list by day (spec P-24 responsive) */}
              <div className="sm:hidden">
                {rows.filter((r) => r.trades > 0).length === 0 ? <Empty text="No trades in this month" /> : (
                  <ul className="divide-y divide-borderSubtle/60">
                    {rows.filter((r) => r.trades > 0).map((r) => {
                      const tone = dayTone(r.net_usd, r.trades, maxAbs);
                      return (
                        <li key={r.day}>
                          <button onClick={() => setDay(r.day)} className={`w-full flex items-center justify-between gap-3 py-3 px-2 text-left rounded-lg cursor-pointer ${r.day === selected ? 'bg-electricBlue/10' : ''}`}>
                            <span className="flex items-center gap-2.5 min-w-0">
                              <span className={`w-1.5 h-8 rounded-full ${tone.kind === 'win' ? 'bg-emeraldNeon' : tone.kind === 'loss' ? 'bg-crimsonNeon' : 'bg-slate-600'}`} style={{ opacity: Math.max(0.35, tone.intensity) }} />
                              <span className="min-w-0">
                                <span className="block text-sm text-white font-medium">{formatLongDate(r.day)}</span>
                                <span className="block text-[11px] text-slate-500 font-mono">{r.trades} trades · {r.wins}W/{r.losses}L</span>
                              </span>
                            </span>
                            <span className="text-right">
                              <span className={`block font-mono text-sm font-bold ${toneClass(r.net_usd)}`}>{formatUsd(r.net_usd, { sign: true })}</span>
                              <span className="block font-mono text-[10px] text-slate-500">Σ {formatUsd(r.cumulative_net_usd, { sign: true })}</span>
                            </span>
                          </button>
                        </li>
                      );
                    })}
                  </ul>
                )}
              </div>
            </>
          )}
        </AsyncBlock>
      </Card>

      {selected && (
        <Card className="border-electricBlue/40 p-4 sm:p-5 shadow-xl">
          <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 pb-4 border-b border-borderSubtle">
            <div>
              <div className="flex items-center gap-2 flex-wrap">
                <span className="px-2 py-0.5 rounded bg-electricBlue/20 text-electricBlue font-mono text-xs font-semibold">SELECTED DAY</span>
                <h3 className="text-base font-bold text-white">{formatLongDate(selected)}</h3>
              </div>
              <p className="text-xs text-slate-400 mt-1">{selRow ? `${selRow.trades} closed positions · ${selRow.wins}W / ${selRow.losses}L` : '…'}</p>
            </div>
            <div className="flex items-center gap-4">
              {selRow && (
                <div className="text-right font-mono">
                  <span className="block text-[10px] uppercase text-slate-400">Session Net</span>
                  <span className={`text-base font-bold ${toneClass(selRow.net_usd)}`}>{formatUsd(selRow.net_usd, { sign: true })}</span>
                </div>
              )}
              <button onClick={() => navigate(`/${filterQuery(filters, { date: selected })}`)}
                className="px-3.5 py-2 rounded-xl bg-electricBlue hover:bg-blue-600 text-white text-xs font-semibold cursor-pointer whitespace-nowrap">
                Open day <i className="fa-solid fa-arrow-right ml-1" aria-hidden />
              </button>
            </div>
          </div>
          <div className="mt-2">
            <AsyncBlock state={dayTrades} rows={2}>
              {(d) => d.rows.length ? <TradesTable rows={d.rows} onOpen={setOpenId} compact /> : <Empty text={`No positions were closed on ${selected}.`} />}
            </AsyncBlock>
          </div>
        </Card>
      )}

      <PositionModal id={openId} onClose={() => setOpenId(null)} />
    </section>
  );
}
