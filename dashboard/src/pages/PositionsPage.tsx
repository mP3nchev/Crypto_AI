// "Positions" screen (spec P-24 #3) styled as the design's "Live Signals & Open Positions" tab.
import { useState } from 'react';
import { getConfig, getSummary, listPositions, type PositionSort } from '../lib/api';
import { toRpcParams } from '../lib/filters';
import {
  formatDateTime, formatDuration, formatNumber, formatPair, formatPct, formatPrice, formatTime, formatUsd, toneClass,
} from '../lib/format';
import type { PaperConfig, Position, PositionStatus } from '../lib/types';
import { useAsync } from '../hooks/useAsync';
import { useFilters, useQueryParam } from '../hooks/useFilters';
import { PositionModal } from '../components/PositionModal';
import {
  AsyncBlock, Card, Empty, ErrorState, ExitBadge, KpiCard, Loading, Segmented, SideBadge, StatusBadge, THEAD_ROW, TH, TierBadge,
} from '../components/ui';

const PAGE = 50;

function RulesPanel({ cfg }: { cfg: PaperConfig }) {
  const lev = cfg.leverage_override ? `${cfg.leverage_override}x fixed` : `signal (max ${cfg.max_leverage}x)`;
  const slip = (o: Record<string, number>) => ['1', '2', '3'].map((t) => `${formatNumber(o[t], 2)}%`).join(' / ');
  const box = 'bg-obsidian/80 border border-borderSubtle rounded-xl p-3.5';
  const lbl = 'block text-[11px] font-semibold uppercase tracking-wider text-slate-400 mb-1.5';
  return (
    <Card className="p-4 sm:p-5">
      <div className="flex flex-col lg:flex-row lg:items-start justify-between gap-5">
        <div className="space-y-1 max-w-md">
          <div className="flex items-center gap-2">
            <i className="fa-solid fa-sliders text-electricBlue" aria-hidden />
            <h2 className="text-sm font-bold text-white uppercase tracking-wide">Automated Execution & Risk Engine</h2>
          </div>
          <p className="text-xs text-slate-400 leading-relaxed">
            Every signal saved by the pipeline opens one virtual position in <code className="font-mono text-slate-300 bg-obsidian px-1.5 py-0.5 rounded">paper_positions</code> with these rules.
            The configuration is frozen for the test (version <span className="font-mono text-slate-200">v{cfg.config_version}</span>) and is changed only in Supabase.
          </p>
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 sm:gap-4 flex-1">
          <div className={box}>
            <span className={lbl}>Position Sizing</span>
            <p className="font-mono text-sm text-white">{cfg.sizing_mode === 'FIXED_MARGIN' ? `${formatUsd(cfg.fixed_margin_usd)} margin` : `${formatNumber(cfg.equity_pct, 2)}% of equity`}</p>
            <p className="mt-1.5 text-[11px] text-slate-500">Leverage: {lev} · capital {formatUsd(cfg.initial_capital_usd)} · max {cfg.max_open_positions} open</p>
          </div>
          <div className={box}>
            <span className={lbl}>Costs (per side)</span>
            <p className="font-mono text-sm text-white">fee {formatNumber(cfg.fee_rate * 100, 3)}%</p>
            <p className="mt-1.5 text-[11px] text-slate-500">Slippage T1/T2/T3 entry {slip(cfg.entry_slippage_pct)} · stop {slip(cfg.stop_slippage_pct)} · TP {formatNumber(cfg.tp_slippage_pct, 2)}%</p>
          </div>
          <div className={box}>
            <div className="flex items-center justify-between mb-1.5">
              <span className="text-[11px] font-semibold uppercase tracking-wider text-slate-400">Same-Candle TP/SL Conflict</span>
              <span className="text-[10px] font-mono text-amberWarn bg-amberWarn/10 px-1.5 py-0.5 rounded border border-amberWarn/20">Anti-Bias</span>
            </div>
            <p className="text-xs text-slate-200">Conservative: Stop Loss First (worst case)</p>
            <p className="mt-1.5 text-[11px] text-slate-500">Max hold {cfg.max_holding_hours}h · break-even after TP1 {cfg.move_sl_to_breakeven_after_tp1 ? 'ON' : 'OFF'} · stale &gt; {cfg.max_signal_age_minutes} min rejected</p>
          </div>
        </div>
      </div>
    </Card>
  );
}

function TpCell({ p }: { p: Position }) {
  return (
    <div className="font-mono text-[11px] tabular-nums leading-relaxed">
      {[p.tp1, p.tp2, p.tp3].map((v, i) => {
        const hit = p.tp_hits > i;
        return (
          <div key={i} className={hit ? 'text-emeraldNeon' : i === p.tp_hits ? 'text-slate-200' : 'text-slate-500'}>
            {hit ? <i className="fa-solid fa-check text-[9px] mr-1" aria-label="filled" /> : <span className="inline-block w-[13px]" />}${formatPrice(v)}
          </div>
        );
      })}
    </div>
  );
}

function OpenTable({ rows, onOpen }: { rows: Position[]; onOpen: (id: number) => void }) {
  if (!rows.length) return <Empty text="No open virtual positions" hint="New signals from the pipeline open positions automatically." />;
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-left border-collapse">
        <thead>
          <tr className={THEAD_ROW}>
            <th className={`${TH} px-4`}>Pair / Strategy</th>
            <th className={TH}>Side</th>
            <th className={`${TH} text-right`}>Entry (fill)</th>
            <th className={`${TH} text-right`} title="Close of the latest 1h candle stored by the monitor">Last 1h Close</th>
            <th className={`${TH} text-right`}>Targets TP1/2/3</th>
            <th className={`${TH} text-right`}>Stop</th>
            <th className={`${TH} text-right`}>Size</th>
            <th className={`${TH} text-center`}>Remaining</th>
            <th className={`${TH} text-center`}>R:R</th>
            <th className={`${TH} text-right`} title="Indicative: latest 1h close, fees included, no slippage. Not part of any metric.">Indicative P&L</th>
            <th className={`${TH} px-4`}>Opened</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-borderSubtle/60 text-sm">
          {rows.map((p) => (
            <tr key={p.id} onClick={() => onOpen(p.id)} onKeyDown={(e) => e.key === 'Enter' && onOpen(p.id)} tabIndex={0}
              className="hover:bg-surfaceHover/60 transition-colors cursor-pointer focus:outline-none focus:bg-surfaceHover">
              <td className="py-3 px-4">
                <div className="font-mono font-bold text-white whitespace-nowrap">{formatPair(p.symbol)} <TierBadge tier={p.tier} /></div>
                <div className="text-[11px] text-slate-400 whitespace-nowrap">{p.tp_strategy ?? p.market_condition ?? '—'}</div>
              </td>
              <td className="py-3 px-3"><SideBadge direction={p.direction} /></td>
              <td className="py-3 px-3 text-right font-mono text-slate-300 tabular-nums whitespace-nowrap">${formatPrice(p.entry_fill_price)}</td>
              <td className="py-3 px-3 text-right font-mono font-semibold text-white tabular-nums whitespace-nowrap">${formatPrice(p.last_price)}</td>
              <td className="py-3 px-3 text-right"><TpCell p={p} /></td>
              <td className="py-3 px-3 text-right font-mono text-xs text-crimsonNeon tabular-nums whitespace-nowrap">
                ${formatPrice(p.effective_stop)}
                {p.be_active && <div className="text-[10px] text-electricBlue">BE ${formatPrice(p.entry_fill_price)}</div>}
                {p.stop_capped_by_liquidation && <div className="text-[10px] text-amberWarn">liq. cap</div>}
              </td>
              <td className="py-3 px-3 text-right font-mono tabular-nums whitespace-nowrap">
                <div className="text-slate-200">{formatUsd(p.margin_usd)}</div>
                <div className="text-[10px] text-slate-500">{p.leverage}x · {formatUsd(p.notional_usd)}</div>
              </td>
              <td className="py-3 px-3 text-center font-mono text-xs text-slate-300">{formatNumber(p.remaining_pct, 0)}%</td>
              <td className="py-3 px-3 text-center">
                <span className="px-2 py-0.5 rounded bg-obsidian border border-borderSubtle font-mono text-[11px] text-slate-300 whitespace-nowrap">1 : {formatNumber(p.fee_adjusted_rr, 2)}</span>
              </td>
              <td className="py-3 px-3 text-right font-mono tabular-nums whitespace-nowrap">
                <div className={`font-bold ${toneClass(p.indicative_unrealized_usd)}`}>{formatUsd(p.indicative_unrealized_usd, { sign: true })}</div>
                {p.partially_realized_net_usd !== null && p.tp_hits > 0 && (
                  <div className="text-[10px] text-slate-500">realized {formatUsd(p.partially_realized_net_usd, { sign: true })}</div>
                )}
              </td>
              <td className="py-3 px-4 font-mono text-[11px] text-slate-400 whitespace-nowrap">
                {formatDateTime(p.opened_at)}<div className="text-slate-500">{formatDuration(p.hours_open)} ago</div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function SignalStream({ rows }: { rows: Position[] }) {
  if (!rows.length) return <p className="text-xs text-slate-500 py-2">No signals yet.</p>;
  return (
    <div className="space-y-2 max-h-72 overflow-y-auto pr-1 font-mono text-xs">
      {rows.map((p) => (
        <div key={p.id} className="flex flex-wrap items-center justify-between gap-2 bg-obsidian/70 border border-borderSubtle/70 rounded-lg px-3 py-2">
          <div className="flex items-center gap-2.5 min-w-0">
            <span className="text-slate-500">[{formatTime(p.opened_at)}]</span>
            <span className="text-white font-bold">{formatPair(p.symbol)}</span>
            <span className={`${p.direction === 'LONG' ? 'text-emeraldNeon' : p.direction === 'SHORT' ? 'text-crimsonNeon' : 'text-slate-400'} font-semibold`}>{p.direction ?? '—'}</span>
            <span className="text-slate-400 hidden sm:inline">@ ${formatPrice(p.signal_entry_price)}</span>
          </div>
          <div className="flex items-center gap-3 min-w-0">
            {p.status === 'OPEN' || p.status === 'CLOSED'
              ? <span className="text-emeraldNeon">OPENED ({formatUsd(p.margin_usd)} × {p.leverage}x){p.status === 'CLOSED' ? ' · closed' : ''}</span>
              : <StatusBadge status={p.status} reason={p.status_reason} />}
          </div>
        </div>
      ))}
    </div>
  );
}

function HistoryTab({ onOpen }: { onOpen: (id: number) => void }) {
  const [filters] = useFilters();
  const [status, setStatus] = useState<'ALL' | Exclude<PositionStatus, 'OPEN'>>('ALL');
  const [sort, setSort] = useState<PositionSort>('opened_desc');
  const [page, setPage] = useState(0);
  const fkey = JSON.stringify(toRpcParams(filters));
  const statuses: PositionStatus[] = status === 'ALL' ? ['CLOSED', 'SKIPPED', 'REJECTED'] : [status];
  const data = useAsync(
    () => listPositions({ filters, statuses, sort, offset: page * PAGE, limit: PAGE, withCount: true }),
    [fkey, status, sort, page],
  );
  const total = data.data?.count ?? 0;
  const pages = Math.max(1, Math.ceil(total / PAGE));

  return (
    <>
      <div className="p-4 sm:p-5 border-b border-borderSubtle flex flex-col md:flex-row md:items-center justify-between gap-3">
        <div className="w-full md:w-96">
          <Segmented ariaLabel="Status" value={status} onChange={(v) => { setStatus(v); setPage(0); }}
            options={[{ value: 'ALL', label: 'All' }, { value: 'CLOSED', label: 'Closed' }, { value: 'SKIPPED', label: 'Skipped' }, { value: 'REJECTED', label: 'Rejected' }]} />
        </div>
        <div className="flex items-center gap-2">
          <label htmlFor="sort" className="text-xs text-slate-400">Sort</label>
          <select id="sort" value={sort} onChange={(e) => { setSort(e.target.value as PositionSort); setPage(0); }}
            className="bg-obsidian border border-borderSubtle focus:border-electricBlue rounded-xl px-3 py-2 text-xs text-white focus:outline-none cursor-pointer">
            <option value="opened_desc">Newest signal</option>
            <option value="opened_asc">Oldest signal</option>
            <option value="closed_desc">Recently closed</option>
            <option value="net_desc">Best result</option>
            <option value="net_asc">Worst result</option>
          </select>
        </div>
      </div>
      <AsyncBlock state={data} rows={6}>
        {(d) => !d.rows.length ? <Empty text="No positions for these filters" /> : (
          <>
            <div className="overflow-x-auto">
              <table className="w-full text-left border-collapse">
                <thead>
                  <tr className={THEAD_ROW}>
                    <th className={`${TH} px-4`}>Pair</th>
                    <th className={TH}>Side</th>
                    <th className={TH}>Status</th>
                    <th className={`${TH} text-right`}>Entry</th>
                    <th className={`${TH} text-right`}>Exit (avg)</th>
                    <th className={`${TH} text-right`}>Net</th>
                    <th className={`${TH} text-right`}>Return</th>
                    <th className={TH}>Exit</th>
                    <th className={`${TH} px-4`}>Signal / Closed</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-borderSubtle/60 text-sm">
                  {d.rows.map((p) => (
                    <tr key={p.id} onClick={() => onOpen(p.id)} onKeyDown={(e) => e.key === 'Enter' && onOpen(p.id)} tabIndex={0}
                      className="hover:bg-surfaceHover cursor-pointer transition-colors focus:outline-none focus:bg-surfaceHover">
                      <td className="py-3 px-4 whitespace-nowrap"><span className="font-mono font-bold text-white">{formatPair(p.symbol)}</span> <TierBadge tier={p.tier} /></td>
                      <td className="py-3 px-3"><SideBadge direction={p.direction} /></td>
                      <td className="py-3 px-3"><StatusBadge status={p.status} reason={p.status === 'CLOSED' ? null : p.status_reason} /></td>
                      <td className="py-3 px-3 text-right font-mono text-slate-300 tabular-nums whitespace-nowrap">${formatPrice(p.entry_fill_price ?? p.signal_entry_price)}</td>
                      <td className="py-3 px-3 text-right font-mono text-white tabular-nums whitespace-nowrap">{p.status === 'CLOSED' ? `$${formatPrice(p.avg_exit_price)}` : '—'}</td>
                      <td className={`py-3 px-3 text-right font-mono font-bold tabular-nums whitespace-nowrap ${toneClass(p.realized_net_usd)}`}>{p.status === 'CLOSED' ? formatUsd(p.realized_net_usd, { sign: true }) : '—'}</td>
                      <td className={`py-3 px-3 text-right font-mono text-xs tabular-nums whitespace-nowrap ${toneClass(p.return_on_margin_pct)}`}>{p.status === 'CLOSED' ? formatPct(p.return_on_margin_pct, { sign: true }) : '—'}</td>
                      <td className="py-3 px-3">{p.status === 'CLOSED' ? <ExitBadge reason={p.exit_reason} summary={p.exit_summary} /> : <span className="text-slate-600">—</span>}</td>
                      <td className="py-3 px-4 font-mono text-[11px] text-slate-400 whitespace-nowrap">{formatDateTime(p.opened_at)}<div className="text-slate-500">{p.closed_at ? formatDateTime(p.closed_at) : ''}</div></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="p-4 flex items-center justify-between gap-3 border-t border-borderSubtle text-xs text-slate-400">
              <span className="font-mono">{page * PAGE + 1}–{page * PAGE + d.rows.length} of {total}</span>
              <div className="flex items-center gap-2">
                <button disabled={page === 0} onClick={() => setPage((n) => n - 1)} className="px-3 py-1.5 rounded-lg bg-obsidian border border-borderSubtle enabled:hover:border-slate-500 disabled:opacity-40 cursor-pointer disabled:cursor-default">Prev</button>
                <span className="font-mono">{page + 1} / {pages}</span>
                <button disabled={page + 1 >= pages} onClick={() => setPage((n) => n + 1)} className="px-3 py-1.5 rounded-lg bg-obsidian border border-borderSubtle enabled:hover:border-slate-500 disabled:opacity-40 cursor-pointer disabled:cursor-default">Next</button>
              </div>
            </div>
          </>
        )}
      </AsyncBlock>
    </>
  );
}

export function PositionsPage() {
  const [filters] = useFilters();
  const [view, setView] = useQueryParam('view');
  const tab = view === 'history' ? 'history' : 'open';
  const [openId, setOpenId] = useState<number | null>(null);
  const fkey = JSON.stringify(toRpcParams(filters));

  const summary = useAsync(() => getSummary(filters), [fkey]);
  const config = useAsync(getConfig, []);
  const open = useAsync(() => listPositions({ filters, statuses: ['OPEN'], sort: 'opened_desc', limit: 200 }), [fkey]);
  const stream = useAsync(() => listPositions({ filters, sort: 'opened_desc', limit: 15 }), [fkey]);
  const s = summary.data;

  return (
    <section className="space-y-6">
      {summary.error ? <Card><ErrorState error={summary.error} onRetry={summary.reload} /></Card> : !s ? <Card><Loading rows={2} /></Card> : (
        <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-4">
          <KpiCard big label="Virtual Account Equity" value={formatUsd(s.equity_usd)} icon="fa-solid fa-wallet" iconTone="emeraldNeon"
            sub={<><span className={`font-mono font-semibold ${toneClass(s.equity_return_pct)}`}>{formatPct(s.equity_return_pct, { sign: true })}</span> vs {formatUsd(s.initial_capital_usd)} initial (closed trades)</>} />
          <KpiCard big label="Total Open Exposure" value={formatUsd(s.open_margin_usd)} icon="fa-solid fa-shield-halved" iconTone="electricBlue"
            sub={<><span className="text-electricBlue font-mono font-semibold">{formatPct(s.exposure_pct, { digits: 1 })}</span> of equity as margin · {formatUsd(s.open_notional_usd)} notional</>} />
          <KpiCard big label="Indicative Unrealized P&L" value={formatUsd(s.indicative_unrealized_usd, { sign: true })} valueClass={toneClass(s.indicative_unrealized_usd)}
            icon="fa-solid fa-arrow-trend-up" iconTone={s.indicative_unrealized_usd < 0 ? 'crimsonNeon' : 'emeraldNeon'}
            sub={<><span className={`font-mono font-semibold ${toneClass(s.indicative_unrealized_pct)}`}>{formatPct(s.indicative_unrealized_pct, { sign: true })}</span> on open margin · realized TPs {formatUsd(s.partially_realized_usd, { sign: true })}</>} />
          <KpiCard big label="Signals Processed (24h)" value={s.signals_24h} icon="fa-solid fa-tower-broadcast" iconTone="purple"
            sub={<><span className="text-slate-300 font-mono">{formatPct(s.opened_24h_pct, { digits: 0 })}</span> opened · {s.skipped_24h} skipped · {s.rejected_24h} rejected</>} />
        </div>
      )}

      {config.data && <RulesPanel cfg={config.data} />}

      <Card className="overflow-hidden shadow-xl">
        <div className="p-4 sm:p-5 border-b border-borderSubtle flex flex-col sm:flex-row sm:items-center justify-between gap-3">
          <div>
            <div className="flex items-center gap-2.5 flex-wrap">
              <h2 className="text-base font-bold text-white">{tab === 'open' ? 'Active Virtual Positions' : 'Position History'}</h2>
              <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-[11px] font-mono bg-emeraldNeon/10 text-emeraldNeon border border-emeraldNeon/25">
                <span className="w-1.5 h-1.5 rounded-full bg-emeraldNeon animate-pulse" />Monitor: hourly · closed 1h candles
              </span>
            </div>
            <p className="text-xs text-slate-400 mt-0.5">
              {tab === 'open' ? 'Evaluated against TP and SL on each closed 1h candle. Click a row for details.' : 'Closed, skipped and rejected signals. 50 per page.'}
            </p>
          </div>
          <div className="w-full sm:w-64">
            <Segmented ariaLabel="View" value={tab} onChange={(v) => setView(v === 'open' ? null : v)}
              options={[{ value: 'open', label: `Open${open.data ? ` (${open.data.rows.length})` : ''}` }, { value: 'history', label: 'History' }]} />
          </div>
        </div>
        {tab === 'open'
          ? <AsyncBlock state={open} rows={4}>{(d) => <OpenTable rows={d.rows} onOpen={setOpenId} />}</AsyncBlock>
          : <HistoryTab onOpen={setOpenId} />}
      </Card>

      {tab === 'open' && (
        <Card className="p-4 sm:p-5">
          <div className="flex items-center justify-between mb-3 gap-2">
            <div className="flex items-center gap-2">
              <i className="fa-solid fa-terminal text-electricBlue text-sm" aria-hidden />
              <h3 className="text-sm font-bold text-white">Signal Pipeline Stream</h3>
            </div>
            <span className="text-xs font-mono text-slate-500 hidden sm:inline">telegram_signals → paper_positions</span>
          </div>
          <AsyncBlock state={stream} rows={3}>{(d) => <SignalStream rows={d.rows} />}</AsyncBlock>
        </Card>
      )}

      <PositionModal id={openId} onClose={() => setOpenId(null)} />
    </section>
  );
}
