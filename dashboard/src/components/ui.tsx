// Building blocks reproducing the provided design (Tailwind classes 1:1).
import { useEffect, type ReactNode } from 'react';
import { exitReasonLabel, splitReason } from '../lib/format';

export function Card({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <div className={`bg-surface border border-borderSubtle rounded-2xl ${className}`}>{children}</div>;
}

export function KpiCard(props: {
  label: string; value: ReactNode; valueClass?: string; sub?: ReactNode; icon?: string; iconTone?: string; big?: boolean;
}) {
  const { label, value, valueClass = 'text-white', sub, icon, iconTone = 'electricBlue', big } = props;
  const tones: Record<string, string> = {
    electricBlue: 'bg-electricBlue/10 border-electricBlue/20 text-electricBlue',
    emeraldNeon: 'bg-emeraldNeon/10 border-emeraldNeon/20 text-emeraldNeon',
    crimsonNeon: 'bg-crimsonNeon/10 border-crimsonNeon/20 text-crimsonNeon',
    purple: 'bg-purple-500/10 border-purple-500/20 text-purple-400',
    amberWarn: 'bg-amberWarn/10 border-amberWarn/20 text-amberWarn',
  };
  return (
    <div className={`bg-surface border border-borderSubtle rounded-2xl ${big ? 'p-5' : 'p-4'} flex items-start justify-between gap-3 min-w-0`}>
      <div className="min-w-0">
        <p className="text-[11px] sm:text-xs font-medium text-slate-400 uppercase tracking-wider">{label}</p>
        <p className={`mt-2 ${big ? 'text-2xl' : 'text-xl sm:text-2xl'} font-bold font-mono tabular-nums truncate ${valueClass}`}>{value}</p>
        {sub && <div className="mt-1.5 text-[11px] sm:text-xs text-slate-500">{sub}</div>}
      </div>
      {icon && (
        <div className={`hidden sm:flex w-10 h-10 shrink-0 rounded-xl border items-center justify-center ${tones[iconTone]}`}>
          <i className={icon} aria-hidden />
        </div>
      )}
    </div>
  );
}

export function SideBadge({ direction }: { direction: string | null }) {
  if (direction === 'LONG')
    return <span className="px-2 py-0.5 rounded-md font-mono text-[11px] font-bold bg-emeraldNeon/15 text-emeraldNeon border border-emeraldNeon/30">LONG</span>;
  if (direction === 'SHORT')
    return <span className="px-2 py-0.5 rounded-md font-mono text-[11px] font-bold bg-crimsonNeon/15 text-crimsonNeon border border-crimsonNeon/30">SHORT</span>;
  return <span className="px-2 py-0.5 rounded-md font-mono text-[11px] text-slate-400 border border-borderSubtle">—</span>;
}

const EXIT_TONE: Record<string, { cls: string; icon: string }> = {
  TP: { cls: 'bg-emeraldNeon/10 text-emeraldNeon border-emeraldNeon/25', icon: 'fa-solid fa-check' },
  SL: { cls: 'bg-crimsonNeon/10 text-crimsonNeon border-crimsonNeon/25', icon: 'fa-solid fa-shield' },
  LIQUIDATION: { cls: 'bg-crimsonNeon/15 text-crimsonNeon border-crimsonNeon/40', icon: 'fa-solid fa-skull' },
  BREAKEVEN_SL: { cls: 'bg-electricBlue/10 text-electricBlue border-electricBlue/25', icon: 'fa-solid fa-equals' },
  TIMEOUT: { cls: 'bg-amberWarn/10 text-amberWarn border-amberWarn/25', icon: 'fa-regular fa-clock' },
  DATA_UNAVAILABLE: { cls: 'bg-slate-500/10 text-slate-300 border-slate-500/30', icon: 'fa-solid fa-plug-circle-xmark' },
};

export function ExitBadge({ reason, summary }: { reason: string | null; summary?: string | null }) {
  if (!reason) return <span className="text-slate-500 text-xs">—</span>;
  const tone = EXIT_TONE[reason.startsWith('TP') ? 'TP' : reason] ?? EXIT_TONE.DATA_UNAVAILABLE;
  return (
    <span className="inline-flex flex-col gap-0.5">
      <span className={`inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-[11px] font-medium border whitespace-nowrap ${tone.cls}`}>
        <i className={`${tone.icon} text-[9px]`} aria-hidden /> {exitReasonLabel(reason)}
      </span>
      {summary && summary !== reason && <span className="font-mono text-[10px] text-slate-500 pl-1">{summary}</span>}
    </span>
  );
}

const STATUS_TONE: Record<string, string> = {
  OPEN: 'bg-electricBlue/15 text-electricBlue border-electricBlue/30',
  CLOSED: 'bg-slate-500/10 text-slate-200 border-slate-500/30',
  SKIPPED: 'bg-amberWarn/10 text-amberWarn border-amberWarn/25',
  REJECTED: 'bg-crimsonNeon/10 text-crimsonNeon border-crimsonNeon/25',
};

export function StatusBadge({ status, reason }: { status: string; reason?: string | null }) {
  const { code, detail } = splitReason(reason);
  return (
    <span className="inline-flex flex-col gap-0.5 min-w-0">
      <span className={`self-start px-2 py-0.5 rounded-md font-mono text-[10px] font-bold border ${STATUS_TONE[status] ?? ''}`}>{status}</span>
      {code && <span className="font-mono text-[10px] text-slate-400 truncate max-w-[220px]" title={reason ?? ''}>{code}{detail ? ` · ${detail}` : ''}</span>}
    </span>
  );
}

export function TierBadge({ tier }: { tier: number | null }) {
  if (!tier) return null;
  return <span className="px-1.5 py-0.5 rounded bg-obsidian border border-borderSubtle font-mono text-[10px] text-slate-400">T{tier}</span>;
}

// ---- states (spec P-24: loading / empty / error) ------------------------------------
export function Loading({ rows = 3, label = 'Loading…' }: { rows?: number; label?: string }) {
  return (
    <div className="p-5 space-y-2.5" role="status" aria-live="polite">
      <span className="sr-only">{label}</span>
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} className="h-9 rounded-lg bg-obsidian/70 border border-borderSubtle/60 animate-pulse" />
      ))}
    </div>
  );
}

export function Empty({ text = 'No trades for this period', hint }: { text?: string; hint?: ReactNode }) {
  return (
    <div className="py-10 px-4 text-center">
      <i className="fa-regular fa-folder-open text-slate-600 text-2xl" aria-hidden />
      <p className="mt-2 text-sm text-slate-400">{text}</p>
      {hint && <p className="mt-1 text-xs text-slate-500">{hint}</p>}
    </div>
  );
}

export function ErrorState({ error, onRetry }: { error: Error; onRetry: () => void }) {
  return (
    <div className="m-4 p-4 rounded-xl border border-crimsonNeon/40 bg-crimsonNeon/5 flex flex-col sm:flex-row sm:items-center justify-between gap-3" role="alert">
      <div className="flex items-start gap-2.5 min-w-0">
        <i className="fa-solid fa-circle-exclamation text-crimsonNeon mt-0.5" aria-hidden />
        <div className="min-w-0">
          <p className="text-sm font-semibold text-white">Could not load data</p>
          <p className="text-xs text-slate-400 break-words">{error.message}</p>
        </div>
      </div>
      <button onClick={onRetry} className="shrink-0 px-3.5 py-2 rounded-xl bg-electricBlue hover:bg-blue-600 text-white text-xs font-semibold cursor-pointer">
        <i className="fa-solid fa-rotate-right mr-1.5" aria-hidden />Try again
      </button>
    </div>
  );
}

/** Renders loading / error / children for one async block. */
export function AsyncBlock<T>(props: {
  state: { data: T | undefined; error: Error | null; loading: boolean; reload: () => void };
  rows?: number;
  children: (data: T) => ReactNode;
}) {
  const { state, rows, children } = props;
  if (state.error) return <ErrorState error={state.error} onRetry={state.reload} />;
  if (state.data === undefined) return <Loading rows={rows} />;
  return <>{children(state.data)}</>;
}

export function Segmented<T extends string>(props: {
  value: T; options: { value: T; label: string; activeClass?: string }[]; onChange: (v: T) => void; ariaLabel: string;
}) {
  const { value, options, onChange, ariaLabel } = props;
  return (
    <div role="radiogroup" aria-label={ariaLabel} className="grid gap-1 bg-obsidian p-1 rounded-xl border border-borderSubtle" style={{ gridTemplateColumns: `repeat(${options.length}, minmax(0, 1fr))` }}>
      {options.map((o) => {
        const active = o.value === value;
        return (
          <button
            key={o.value}
            role="radio"
            aria-checked={active}
            onClick={() => onChange(o.value)}
            className={`py-1.5 px-2 rounded-lg text-xs cursor-pointer transition-colors ${
              active ? (o.activeClass ?? 'bg-electricBlue text-white font-semibold') : 'font-medium text-slate-400 hover:text-white'
            }`}
          >
            {o.label}
          </button>
        );
      })}
    </div>
  );
}

export function Modal(props: { open: boolean; onClose: () => void; children: ReactNode; wide?: boolean; labelledBy?: string }) {
  const { open, onClose, children, wide, labelledBy } = props;
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    document.addEventListener('keydown', onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => { document.removeEventListener('keydown', onKey); document.body.style.overflow = prev; };
  }, [open, onClose]);
  if (!open) return null;
  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/75 backdrop-blur-sm p-3 sm:p-4"
      onMouseDown={(e) => e.target === e.currentTarget && onClose()}
      role="dialog" aria-modal="true" aria-labelledby={labelledBy}
    >
      <div className={`bg-surface border border-borderSubtle rounded-2xl ${wide ? 'max-w-3xl' : 'max-w-xl'} w-full max-h-[92vh] overflow-y-auto shadow-2xl`}>
        {children}
      </div>
    </div>
  );
}

export function SectionTitle({ title, subtitle, right }: { title: string; subtitle?: ReactNode; right?: ReactNode }) {
  return (
    <div className="p-4 sm:p-5 border-b border-borderSubtle flex flex-col sm:flex-row sm:items-center justify-between gap-2">
      <div className="min-w-0">
        <h2 className="text-base font-bold text-white">{title}</h2>
        {subtitle && <p className="text-xs text-slate-400 mt-0.5">{subtitle}</p>}
      </div>
      {right}
    </div>
  );
}

export const TH = 'py-3 px-3 whitespace-nowrap';
export const THEAD_ROW = 'border-b border-borderSubtle bg-obsidian/50 text-[11px] font-semibold uppercase tracking-wider text-slate-400';
