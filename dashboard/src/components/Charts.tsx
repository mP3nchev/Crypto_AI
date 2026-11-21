// Lightweight bar charts in plain HTML/CSS (no chart library — spec P-22).
// Values are computed in SQL; bar length is only visual scaling.
import { formatUsd } from '../lib/format';

export interface Bar { label: string; value: number; sub?: string }

export function HBarChart({ bars, positiveClass = 'bg-electricBlue/80' }: { bars: Bar[]; positiveClass?: string }) {
  const max = Math.max(1e-9, ...bars.map((b) => Math.abs(b.value)));
  const hasNeg = bars.some((b) => b.value < 0);
  return (
    <div className="space-y-2.5" role="list">
      {bars.map((b) => {
        const w = `${(Math.abs(b.value) / max) * (hasNeg ? 50 : 100)}%`;
        const neg = b.value < 0;
        return (
          <div key={b.label} role="listitem" className="grid grid-cols-[minmax(70px,120px)_1fr_auto] items-center gap-3">
            <div className="min-w-0">
              <p className="text-xs font-semibold text-slate-200 truncate">{b.label}</p>
              {b.sub && <p className="text-[10px] text-slate-500 truncate">{b.sub}</p>}
            </div>
            <div className="relative h-6 rounded-md bg-obsidian/70 border border-borderSubtle/60 overflow-hidden">
              {hasNeg && <div className="absolute inset-y-0 left-1/2 w-px bg-borderSubtle" />}
              <div
                className={`absolute inset-y-0 rounded-md ${neg ? 'bg-crimsonNeon/80' : positiveClass}`}
                style={hasNeg ? (neg ? { right: '50%', width: w } : { left: '50%', width: w }) : { left: 0, width: w }}
              />
            </div>
            <span className={`font-mono text-xs font-semibold tabular-nums ${neg ? 'text-crimsonNeon' : 'text-emeraldNeon'}`}>{formatUsd(b.value, { sign: true })}</span>
          </div>
        );
      })}
    </div>
  );
}

export function VBarPair({ bars }: { bars: Bar[] }) {
  const max = Math.max(1e-9, ...bars.map((b) => Math.abs(b.value)));
  return (
    <div className="h-52 w-full grid gap-6 px-4" style={{ gridTemplateColumns: `repeat(${bars.length}, minmax(0, 1fr))` }}>
      {bars.map((b) => {
        const h = `${(Math.abs(b.value) / max) * 50}%`;
        const neg = b.value < 0;
        return (
          <div key={b.label} className="relative flex flex-col items-center">
            <div className="relative w-full flex-1">
              <div className="absolute left-0 right-0 top-1/2 h-px bg-borderSubtle" />
              <div
                className={`absolute left-1/2 -translate-x-1/2 w-12 sm:w-16 ${neg ? 'bg-crimsonNeon/75 rounded-b-lg' : 'bg-emeraldNeon/75 rounded-t-lg'}`}
                style={neg ? { top: '50%', height: h } : { bottom: '50%', height: h }}
              />
            </div>
            <p className="mt-2 font-mono text-[11px] text-slate-400">{b.label}</p>
            <p className={`font-mono text-xs font-bold ${neg ? 'text-crimsonNeon' : 'text-emeraldNeon'}`}>{formatUsd(b.value, { sign: true })}</p>
          </div>
        );
      })}
    </div>
  );
}
