// Trade anatomy inspector (design: "tradeDetailModal") — every position field + event timeline.
import type { ReactNode } from 'react';
import { getEvents, getPosition } from '../lib/api';
import {
  exitReasonLabel, formatDateTime, formatDuration, formatNumber, formatPair, formatPct, formatPrice,
  formatUsd, toneClass,
} from '../lib/format';
import type { Position, PositionEvent } from '../lib/types';
import { useAsync } from '../hooks/useAsync';
import { AsyncBlock, ExitBadge, Modal, SideBadge, StatusBadge, TierBadge } from './ui';

function Row({ k, v, cls = 'text-slate-200' }: { k: string; v: ReactNode; cls?: string }) {
  return (
    <div className="flex justify-between gap-4 py-1">
      <span className="text-slate-400 shrink-0">{k}</span>
      <span className={`text-right break-all ${cls}`}>{v}</span>
    </div>
  );
}

const EVENT_TONE: Record<string, string> = {
  OPENED: 'text-electricBlue', TP1: 'text-emeraldNeon', TP2: 'text-emeraldNeon', TP3: 'text-emeraldNeon',
  SL: 'text-crimsonNeon', LIQUIDATION: 'text-crimsonNeon', BREAKEVEN_SL: 'text-electricBlue',
  TIMEOUT: 'text-amberWarn', DATA_UNAVAILABLE: 'text-slate-300', BE_ACTIVATED: 'text-electricBlue',
  DATA_GAP: 'text-amberWarn', ERROR: 'text-crimsonNeon',
};

function Levels({ p }: { p: Position }) {
  const tps = [
    { k: 1, price: p.tp1, alloc: p.alloc1 },
    { k: 2, price: p.tp2, alloc: p.alloc2 },
    { k: 3, price: p.tp3, alloc: p.alloc3 },
  ];
  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
      <div className="bg-obsidian/70 border border-borderSubtle rounded-xl p-3.5 font-mono text-xs space-y-1.5">
        <p className="text-[11px] uppercase text-slate-400 font-sans font-semibold tracking-wider mb-1">Take Profits</p>
        {tps.map((t) => {
          const hit = p.tp_hits >= t.k;
          return (
            <div key={t.k} className="flex items-center justify-between">
              <span className={hit ? 'text-emeraldNeon' : 'text-slate-300'}>
                <i className={`${hit ? 'fa-solid fa-circle-check' : 'fa-regular fa-circle'} mr-1.5`} aria-hidden />
                TP{t.k} <span className="text-slate-500">({formatNumber(t.alloc, 0)}%)</span>
              </span>
              <span className={hit ? 'text-emeraldNeon font-semibold' : 'text-slate-200'}>${formatPrice(t.price)}</span>
            </div>
          );
        })}
      </div>
      <div className="bg-obsidian/70 border border-borderSubtle rounded-xl p-3.5 font-mono text-xs space-y-1.5">
        <p className="text-[11px] uppercase text-slate-400 font-sans font-semibold tracking-wider mb-1">Entry & Risk</p>
        <div className="flex justify-between"><span className="text-slate-400">Signal entry</span><span>${formatPrice(p.signal_entry_price)}</span></div>
        <div className="flex justify-between"><span className="text-slate-400">Simulated fill</span><span className="text-white font-semibold">${formatPrice(p.entry_fill_price)}</span></div>
        <div className="flex justify-between"><span className="text-slate-400">Stop loss (signal)</span><span className="text-crimsonNeon">${formatPrice(p.stop_loss)}</span></div>
        <div className="flex justify-between"><span className="text-slate-400">Effective stop</span>
          <span className="text-crimsonNeon">${formatPrice(p.effective_stop)}{p.stop_capped_by_liquidation && <span className="text-amberWarn"> (liq.)</span>}{p.be_active && <span className="text-electricBlue"> BE</span>}</span>
        </div>
        <div className="flex justify-between"><span className="text-slate-400">Liquidation</span><span className="text-slate-300">${formatPrice(p.liquidation_price)}</span></div>
      </div>
    </div>
  );
}

function Timeline({ events }: { events: PositionEvent[] }) {
  if (!events.length) return <p className="text-xs text-slate-500">No events.</p>;
  return (
    <ol className="relative border-l border-borderSubtle ml-1.5 space-y-3">
      {events.map((e) => (
        <li key={e.id} className="ml-4">
          <span className={`absolute -left-[5px] mt-1.5 w-2.5 h-2.5 rounded-full bg-current ${EVENT_TONE[e.event_type] ?? 'text-slate-400'}`} aria-hidden />
          <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5 font-mono text-xs">
            <span className={`font-bold ${EVENT_TONE[e.event_type] ?? 'text-slate-300'}`}>
              {e.event_type}{e.pct_of_position !== null && e.event_type !== 'OPENED' ? ` · ${formatNumber(e.pct_of_position, 0)}%` : ''}
            </span>
            <span className="text-slate-500">{formatDateTime(e.candle_open_time ?? e.created_at)}{e.candle_open_time ? ' (1h candle)' : ''}</span>
          </div>
          <div className="flex flex-wrap justify-between gap-x-3 font-mono text-[11px] text-slate-400 mt-0.5">
            <span>{e.fill_price !== null ? `fill $${formatPrice(e.fill_price)}` : e.level_price !== null ? `level $${formatPrice(e.level_price)}` : ''}</span>
            {e.net_usd !== null && <span className={`font-semibold ${toneClass(e.net_usd)}`}>{formatUsd(e.net_usd, { sign: true })}</span>}
          </div>
          {e.event_type === 'ERROR' && e.details && <p className="text-[11px] text-crimsonNeon/80 mt-0.5 break-words">{String(e.details.message ?? '')}</p>}
          {e.event_type === 'DATA_GAP' && e.details && <p className="text-[11px] text-amberWarn/80 mt-0.5">missing {String(e.details.missing_hours ?? '?')} h of candles</p>}
        </li>
      ))}
    </ol>
  );
}

function Body({ p, events }: { p: Position; events: PositionEvent[] }) {
  const open = p.status === 'OPEN';
  const traded = p.status === 'OPEN' || p.status === 'CLOSED';
  const cfgVersion = p.config_snapshot ? String(p.config_snapshot.config_version ?? '—') : '—';
  return (
    <div className="p-4 sm:p-5 space-y-5 text-sm">
      {traded && (
        <div className="grid grid-cols-2 gap-3">
          <div className="bg-obsidian border border-borderSubtle rounded-xl p-3.5">
            <p className="text-[11px] uppercase text-slate-400">{open ? 'Realized so far' : 'Net Result'}</p>
            <p className={`mt-1 text-xl font-bold font-mono ${toneClass(p.realized_net_usd)}`}>{formatUsd(p.realized_net_usd, { sign: true })}</p>
            {open && p.indicative_unrealized_usd !== null && (
              <p className="text-[11px] text-slate-500 mt-0.5">Indicative open P&L: <span className={toneClass(p.indicative_unrealized_usd)}>{formatUsd(p.indicative_unrealized_usd, { sign: true })}</span></p>
            )}
          </div>
          <div className="bg-obsidian border border-borderSubtle rounded-xl p-3.5">
            <p className="text-[11px] uppercase text-slate-400">Return on Margin</p>
            <p className={`mt-1 text-xl font-bold font-mono ${toneClass(p.return_on_margin_pct)}`}>{formatPct(p.return_on_margin_pct, { sign: true })}</p>
            <p className="text-[11px] text-slate-500 mt-0.5">Price move: {formatPct(p.price_move_pct, { sign: true })}</p>
          </div>
        </div>
      )}

      {!traded && (
        <div className="bg-obsidian border border-amberWarn/30 rounded-xl p-3.5">
          <p className="text-[11px] uppercase text-slate-400">Not traded</p>
          <p className="mt-1 font-mono text-xs text-amberWarn break-words">{p.status_reason ?? p.status}</p>
          {p.related_position_id && <p className="text-[11px] text-slate-500 mt-1">Blocked by open position #{p.related_position_id}</p>}
        </div>
      )}

      <Levels p={p} />

      <div className="bg-obsidian/70 border border-borderSubtle rounded-xl p-4 font-mono text-xs divide-y divide-borderSubtle/50">
        <div className="pb-2">
          <Row k="Leverage" v={p.leverage ? `${p.leverage}x (signal ${p.signal_leverage ?? '—'}x)` : '—'} />
          <Row k="Margin / Notional" v={`${formatUsd(p.margin_usd)} / ${formatUsd(p.notional_usd)}`} />
          <Row k="Quantity" v={p.quantity !== null ? formatNumber(p.quantity, 6) : '—'} />
          <Row k="Remaining" v={`${formatNumber(p.remaining_pct, 0)}%`} />
          <Row k="Gross / Fees" v={`${formatUsd(p.realized_gross_usd, { sign: true })} / ${formatUsd(p.fees_usd)}`} />
        </div>
        <div className="py-2">
          <Row k="Opened" v={formatDateTime(p.opened_at)} />
          <Row k="Evaluated from" v={formatDateTime(p.eval_start_open_time)} />
          <Row k="Last candle evaluated" v={formatDateTime(p.last_evaluated_open_time)} />
          <Row k="Closed" v={formatDateTime(p.closed_at)} />
          <Row k="Duration" v={open ? `${formatDuration(p.hours_open)} (open)` : formatDuration(p.duration_hours)} />
        </div>
        <div className="pt-2">
          <Row k="Exit" v={p.exit_reason ? `${exitReasonLabel(p.exit_reason)} · ${p.exit_summary ?? ''}` : '—'} cls={toneClass(p.realized_net_usd)} />
          <Row k="Market / TP strategy" v={`${p.market_condition ?? '—'} / ${p.tp_strategy ?? '—'}`} />
          <Row k="Score / Fee-adj. R:R" v={`${formatNumber(p.total_score, 1)} / ${formatNumber(p.fee_adjusted_rr, 2)}`} />
          <Row k="Scan cycle" v={p.scan_cycle_id ?? '—'} cls="text-slate-400" />
          <Row k="Config version" v={cfgVersion} cls="text-slate-400" />
          {p.has_data_gap && <Row k="Data" v="gap in candle data detected" cls="text-amberWarn" />}
          {p.status_reason && traded && <Row k="Note" v={p.status_reason} cls="text-slate-400" />}
        </div>
      </div>

      <div>
        <p className="text-[11px] uppercase text-slate-400 font-semibold tracking-wider mb-3">Event Timeline</p>
        <Timeline events={events} />
      </div>
    </div>
  );
}

export function PositionModal({ id, onClose }: { id: number | null; onClose: () => void }) {
  const state = useAsync(
    async () => (id === null ? null : Promise.all([getPosition(id), getEvents(id)])),
    [id],
  );
  const p = state.data?.[0] ?? null;
  return (
    <Modal open={id !== null} onClose={onClose} labelledBy="position-modal-title">
      <div className="p-4 sm:p-5 border-b border-borderSubtle flex items-center justify-between gap-3 bg-obsidian/60 sticky top-0 z-10">
        <div className="flex items-center gap-3 min-w-0">
          <SideBadge direction={p?.direction ?? null} />
          <div className="min-w-0">
            <h3 id="position-modal-title" className="text-base font-bold font-mono text-white flex items-center gap-2">
              {p ? formatPair(p.symbol) : '…'} {p && <TierBadge tier={p.tier} />}
            </h3>
            <p className="text-[11px] font-mono text-slate-400 truncate">
              {p ? `Position #${p.id} · Signal #${p.signal_id} · ${p.category ?? 'OTHER'}` : 'Loading…'}
            </p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {p && <StatusBadge status={p.status} />}
          {p?.exit_reason && <span className="hidden sm:inline"><ExitBadge reason={p.exit_reason} /></span>}
          <button onClick={onClose} aria-label="Close" className="w-8 h-8 rounded-lg bg-surface hover:bg-surfaceHover border border-borderSubtle text-slate-400 hover:text-white flex items-center justify-center cursor-pointer">
            <i className="fa-solid fa-xmark" aria-hidden />
          </button>
        </div>
      </div>
      <AsyncBlock state={state} rows={6}>
        {(d) => (d && d[0] ? <Body p={d[0]} events={d[1]} /> : <p className="p-5 text-sm text-slate-400">Position not found.</p>)}
      </AsyncBlock>
    </Modal>
  );
}
