// Analytics & Segmentation (design tab) + spec P-24 #4 "Comparison" (small sample < 20 trades).
import { useState } from 'react';
import { getBreakdown, getStats } from '../lib/api';
import { isValidDay, monthOf } from '../lib/calendar';
import { toRpcParams } from '../lib/filters';
import { formatDuration, formatLongDate, formatNumber, formatPair, formatPct, formatUsd, sofiaDate, toneClass } from '../lib/format';
import type { BreakdownDimension, BreakdownRow } from '../lib/types';
import { useAsync } from '../hooks/useAsync';
import { useFilters, useQueryParam } from '../hooks/useFilters';
import { HBarChart, VBarPair } from '../components/Charts';
import { AsyncBlock, Card, Empty, ErrorState, KpiCard, Loading, Segmented, THEAD_ROW, TH } from '../components/ui';

type Preset = 'month' | '30d' | 'all' | 'custom';

function usePeriod() {
  const [fromP, setFrom] = useQueryParam('from');
  const [toP, setTo] = useQueryParam('to');
  const [presetP, setPreset] = useQueryParam('period');
  const today = sofiaDate();
  const preset: Preset = presetP === '30d' || presetP === 'all' || presetP === 'custom' ? presetP : 'month';
  let from: string | null; let to: string | null;
  if (preset === 'all') { from = null; to = null; }
  else if (preset === '30d') { const d = new Date(); d.setUTCDate(d.getUTCDate() - 29); from = sofiaDate(d); to = today; }
  else if (preset === 'custom') { from = isValidDay(fromP) ? fromP : `${monthOf(today)}-01`; to = isValidDay(toP) ? toP : today; }
  else { from = `${monthOf(today)}-01`; to = today; }
  const choose = (p: Preset) => { setPreset(p === 'month' ? null : p); if (p !== 'custom') { setFrom(null); setTo(null); } };
  return { from, to, preset, choose, setFrom, setTo, today };
}

function ComparisonTable({ rows }: { rows: BreakdownRow[] }) {
  if (!rows.length) return <Empty />;
  const sorted = [...rows].sort((a, b) => b.stats.total_net_usd - a.stats.total_net_usd);
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-left border-collapse">
        <thead>
          <tr className={THEAD_ROW}>
            <th className={`${TH} px-4`}>Segment</th>
            <th className={`${TH} text-right`}>Trades</th>
            <th className={`${TH} text-right`}>Win Rate</th>
            <th className={`${TH} text-right`}>Net</th>
            <th className={`${TH} text-right`}>Profit Factor</th>
            <th className={`${TH} text-right`}>Expectancy</th>
            <th className={`${TH} text-right`}>Avg Duration</th>
            <th className={`${TH} px-4 text-right`}>Max DD</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-borderSubtle/60 text-sm">
          {sorted.map((r) => (
            <tr key={r.segment} className="hover:bg-surfaceHover/60">
              <td className="py-3 px-4 whitespace-nowrap">
                <span className="font-mono font-bold text-white">{r.segment.endsWith('USDT') ? formatPair(r.segment) : /^\d+$/.test(r.segment) ? `Tier ${r.segment}` : r.segment}</span>
                {r.small_sample && <span className="ml-2 px-1.5 py-0.5 rounded text-[10px] font-mono bg-amberWarn/10 text-amberWarn border border-amberWarn/25" title="Fewer than 20 trades: not statistically meaningful">small sample</span>}
              </td>
              <td className="py-3 px-3 text-right font-mono text-slate-200">{r.stats.trades}</td>
              <td className="py-3 px-3 text-right font-mono text-slate-200">{formatPct(r.stats.win_rate_pct, { digits: 1 })}</td>
              <td className={`py-3 px-3 text-right font-mono font-bold whitespace-nowrap ${toneClass(r.stats.total_net_usd)}`}>{formatUsd(r.stats.total_net_usd, { sign: true })}</td>
              <td className="py-3 px-3 text-right font-mono text-electricBlue">{r.stats.profit_factor === null ? (r.stats.wins ? '∞' : '—') : formatNumber(r.stats.profit_factor)}</td>
              <td className={`py-3 px-3 text-right font-mono whitespace-nowrap ${toneClass(r.stats.expectancy_usd)}`}>{formatUsd(r.stats.expectancy_usd, { sign: true })}</td>
              <td className="py-3 px-3 text-right font-mono text-xs text-slate-400 whitespace-nowrap">{formatDuration(r.stats.avg_duration_hours)}</td>
              <td className="py-3 px-4 text-right font-mono text-xs text-slate-400">{formatPct(r.stats.max_drawdown_pct)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function PairList({ rows, tone }: { rows: BreakdownRow[]; tone: 'win' | 'loss' }) {
  if (!rows.length) return <p className="text-xs text-slate-500 py-3">{tone === 'win' ? 'No profitable pairs in this period.' : 'No losing pairs in this period.'}</p>;
  const c = tone === 'win' ? 'bg-emeraldNeon/15 text-emeraldNeon' : 'bg-crimsonNeon/15 text-crimsonNeon';
  return (
    <div className="space-y-2.5">
      {rows.map((r, i) => (
        <div key={r.segment} className="flex items-center justify-between bg-obsidian border border-borderSubtle rounded-xl px-4 py-3">
          <div className="flex items-center gap-3 min-w-0">
            <span className={`w-6 h-6 shrink-0 rounded-full font-mono text-xs font-bold flex items-center justify-center ${c}`}>#{i + 1}</span>
            <div className="min-w-0">
              <p className="font-mono font-bold text-white text-sm">{formatPair(r.segment)}</p>
              <p className="text-[11px] text-slate-400">{r.stats.trades} trades · {formatPct(r.stats.win_rate_pct, { digits: 0 })} win rate{r.small_sample ? ' · small sample' : ''}</p>
            </div>
          </div>
          <span className={`font-mono font-bold ${toneClass(r.stats.total_net_usd)}`}>{formatUsd(r.stats.total_net_usd, { sign: true })}</span>
        </div>
      ))}
    </div>
  );
}

export function AnalyticsPage() {
  const [filters] = useFilters();
  const period = usePeriod();
  const [dim, setDim] = useState<BreakdownDimension>('symbol');
  const fkey = JSON.stringify(toRpcParams(filters));
  const pk = `${period.from}|${period.to}`;

  const stats = useAsync(() => getStats(period.from, period.to, filters), [pk, fkey]);
  const byDir = useAsync(() => getBreakdown('direction', period.from, period.to, filters), [pk, fkey]);
  const byCat = useAsync(() => getBreakdown('category', period.from, period.to, filters), [pk, fkey]);
  const bySym = useAsync(() => getBreakdown('symbol', period.from, period.to, filters), [pk, fkey]);
  const byDim = useAsync(() => getBreakdown(dim, period.from, period.to, filters), [pk, fkey, dim]);

  const dir = (d: string) => byDir.data?.find((r) => r.segment === d)?.stats;
  const symSorted = [...(bySym.data ?? [])].sort((a, b) => b.stats.total_net_usd - a.stats.total_net_usd);
  const top = symSorted.filter((r) => r.stats.total_net_usd > 0).slice(0, 3);
  const worst = [...symSorted].reverse().filter((r) => r.stats.total_net_usd < 0).slice(0, 3);

  return (
    <section className="space-y-6">
      <Card className="p-4 sm:p-5 flex flex-col lg:flex-row lg:items-center justify-between gap-4">
        <div>
          <h2 className="text-lg font-bold text-white">Performance Segmentation</h2>
          <p className="text-xs text-slate-400 mt-0.5">
            Closed positions {period.from ? <>from <span className="text-slate-200">{formatLongDate(period.from)}</span> to <span className="text-slate-200">{formatLongDate(period.to!)}</span></> : 'since the start of the test'}. Global filters apply.
          </p>
        </div>
        <div className="flex flex-col sm:flex-row gap-2 sm:items-center">
          <div className="w-full sm:w-80">
            <Segmented<Preset> ariaLabel="Period" value={period.preset} onChange={period.choose}
              options={[{ value: 'month', label: 'This month' }, { value: '30d', label: '30 days' }, { value: 'all', label: 'All' }, { value: 'custom', label: 'Custom' }]} />
          </div>
          {period.preset === 'custom' && (
            <div className="flex items-center gap-2">
              <input type="date" aria-label="From" value={period.from ?? ''} max={period.to ?? period.today} onChange={(e) => isValidDay(e.target.value) && period.setFrom(e.target.value)}
                className="bg-obsidian border border-borderSubtle rounded-xl px-2.5 py-1.5 text-xs font-mono text-white [color-scheme:dark]" />
              <span className="text-slate-500 text-xs">→</span>
              <input type="date" aria-label="To" value={period.to ?? ''} min={period.from ?? undefined} max={period.today} onChange={(e) => isValidDay(e.target.value) && period.setTo(e.target.value)}
                className="bg-obsidian border border-borderSubtle rounded-xl px-2.5 py-1.5 text-xs font-mono text-white [color-scheme:dark]" />
            </div>
          )}
        </div>
      </Card>

      {stats.error ? <Card><ErrorState error={stats.error} onRetry={stats.reload} /></Card> : !stats.data ? <Card><Loading rows={1} /></Card> : (
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
          <KpiCard label="Filtered Sample Size" value={<>{stats.data.trades} <span className="text-xs font-normal text-slate-500">trades</span></>}
            sub={stats.data.trades < 20 ? <span className="text-amberWarn">small sample (&lt; 20)</span> : `${stats.data.skipped} skipped · ${stats.data.rejected} rejected`} />
          <KpiCard label="Segmented Net P&L" value={formatUsd(stats.data.total_net_usd, { sign: true })} valueClass={toneClass(stats.data.total_net_usd)}
            sub={`${formatPct(stats.data.total_return_pct, { sign: true })} of capital · max DD ${formatPct(stats.data.max_drawdown_pct)}`} />
          <KpiCard label="Segmented Win Rate" value={formatPct(stats.data.win_rate_pct, { digits: 1 })} sub={`${stats.data.wins}W / ${stats.data.losses}L / ${stats.data.breakeven} BE`} />
          <KpiCard label="Profit Factor" value={stats.data.profit_factor === null ? (stats.data.wins ? '∞' : '—') : formatNumber(stats.data.profit_factor)} valueClass="text-electricBlue"
            sub={`Expectancy ${formatUsd(stats.data.expectancy_usd, { sign: true })} / trade`} />
        </div>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <Card className="p-4 sm:p-5 flex flex-col justify-between">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h3 className="text-base font-bold text-white">LONG vs SHORT Performance</h3>
              <p className="text-xs text-slate-400">Directional edge, win rate and net P&L</p>
            </div>
            <span className="text-xs font-mono text-slate-500 hidden sm:inline">Directional Split</span>
          </div>
          {byDir.error ? <ErrorState error={byDir.error} onRetry={byDir.reload} /> : !byDir.data ? <Loading rows={2} /> : (
            <>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 mb-5">
                {(['LONG', 'SHORT'] as const).map((d) => {
                  const s = dir(d);
                  return (
                    <div key={d} className={`bg-obsidian border rounded-xl p-3.5 ${d === 'LONG' ? 'border-emeraldNeon/30' : 'border-crimsonNeon/30'}`}>
                      <div className="flex items-center justify-between">
                        <span className={`font-mono text-xs font-bold ${d === 'LONG' ? 'text-emeraldNeon' : 'text-crimsonNeon'}`}>{d} POSITIONS</span>
                        <span className="font-mono text-xs text-slate-400">{s?.trades ?? 0} trades</span>
                      </div>
                      <p className={`mt-2 text-lg font-bold font-mono ${toneClass(s?.total_net_usd ?? 0)}`}>{formatUsd(s?.total_net_usd ?? 0, { sign: true })}</p>
                      <p className="text-[11px] text-slate-400 mt-0.5">Win rate: <strong className="text-white font-mono">{formatPct(s?.win_rate_pct ?? 0, { digits: 1 })}</strong> · PF <span className="font-mono text-slate-200">{s?.profit_factor == null ? '—' : formatNumber(s.profit_factor)}</span></p>
                    </div>
                  );
                })}
              </div>
              <VBarPair bars={[{ label: 'LONG', value: dir('LONG')?.total_net_usd ?? 0 }, { label: 'SHORT', value: dir('SHORT')?.total_net_usd ?? 0 }]} />
            </>
          )}
        </Card>

        <Card className="p-4 sm:p-5">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h3 className="text-base font-bold text-white">Performance by Asset Category</h3>
              <p className="text-xs text-slate-400">Net realized P&L and win rate per category</p>
            </div>
            <span className="text-xs font-mono text-electricBlue hidden sm:inline">Class Alpha</span>
          </div>
          <AsyncBlock state={byCat} rows={4}>
            {(rows) => rows.length ? (
              <HBarChart bars={[...rows].sort((a, b) => b.stats.total_net_usd - a.stats.total_net_usd).map((r) => ({
                label: r.segment, value: r.stats.total_net_usd, sub: `${r.stats.trades} trades · ${formatPct(r.stats.win_rate_pct, { digits: 0 })} WR`,
              }))} />
            ) : <Empty />}
          </AsyncBlock>
        </Card>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <Card className="p-4 sm:p-5">
          <div className="flex items-center gap-2 mb-4">
            <div className="w-8 h-8 rounded-lg bg-emeraldNeon/10 border border-emeraldNeon/25 flex items-center justify-center text-emeraldNeon"><i className="fa-solid fa-trophy text-sm" aria-hidden /></div>
            <div><h3 className="text-sm font-bold text-white">Top Performing Assets</h3><p className="text-xs text-slate-400">Highest net profit contributors</p></div>
          </div>
          <AsyncBlock state={bySym} rows={3}>{() => <PairList rows={top} tone="win" />}</AsyncBlock>
        </Card>
        <Card className="p-4 sm:p-5">
          <div className="flex items-center gap-2 mb-4">
            <div className="w-8 h-8 rounded-lg bg-crimsonNeon/10 border border-crimsonNeon/25 flex items-center justify-center text-crimsonNeon"><i className="fa-solid fa-triangle-exclamation text-sm" aria-hidden /></div>
            <div><h3 className="text-sm font-bold text-white">Underperforming Assets</h3><p className="text-xs text-slate-400">Pairs with a net loss</p></div>
          </div>
          <AsyncBlock state={bySym} rows={3}>{() => <PairList rows={worst} tone="loss" />}</AsyncBlock>
        </Card>
      </div>

      <Card className="overflow-hidden">
        <div className="p-4 sm:p-5 border-b border-borderSubtle flex flex-col md:flex-row md:items-center justify-between gap-3">
          <div>
            <h3 className="text-base font-bold text-white">Segment Comparison</h3>
            <p className="text-xs text-slate-400">Conclusions only for segments with 20+ trades (spec P-32).</p>
          </div>
          <div className="w-full md:w-96">
            <Segmented<BreakdownDimension> ariaLabel="Dimension" value={dim} onChange={setDim}
              options={[{ value: 'symbol', label: 'Symbol' }, { value: 'category', label: 'Category' }, { value: 'direction', label: 'Direction' }, { value: 'tier', label: 'Tier' }]} />
          </div>
        </div>
        <AsyncBlock state={byDim} rows={4}>{(rows) => <ComparisonTable rows={rows} />}</AsyncBlock>
      </Card>
    </section>
  );
}
