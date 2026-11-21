// Calendar layout and colouring (display only). Values come from paper_daily_pnl.

/** "2026-11" for the month containing `day` ("YYYY-MM-DD"). */
export function monthOf(day: string): string {
  return day.slice(0, 7);
}

export function isValidMonth(m: string | null | undefined): m is string {
  return !!m && /^\d{4}-(0[1-9]|1[0-2])$/.test(m);
}

export function isValidDay(d: string | null | undefined): d is string {
  if (!d || !/^\d{4}-\d{2}-\d{2}$/.test(d)) return false;
  const [y, m, dd] = d.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, dd));
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 && dt.getUTCDate() === dd;
}

export function shiftMonth(month: string, delta: number): string {
  const [y, m] = month.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1 + delta, 1));
  return `${dt.getUTCFullYear()}-${String(dt.getUTCMonth() + 1).padStart(2, '0')}`;
}

export function shiftDay(day: string, delta: number): string {
  const [y, m, d] = day.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d + delta));
  return dt.toISOString().slice(0, 10);
}

/** First day of the month as "YYYY-MM-01" (the RPC p_month argument). */
export function monthStart(month: string): string {
  return `${month}-01`;
}

/** Monday-first grid: number of empty leading cells and the list of days. */
export function monthGrid(month: string): { leading: number; days: string[] } {
  const [y, m] = month.split('-').map(Number);
  const first = new Date(Date.UTC(y, m - 1, 1)).getUTCDay(); // 0 = Sunday
  const leading = first === 0 ? 6 : first - 1;
  const count = new Date(Date.UTC(y, m, 0)).getUTCDate();
  const days = Array.from({ length: count }, (_, i) => `${month}-${String(i + 1).padStart(2, '0')}`);
  return { leading, days };
}

export type DayKind = 'win' | 'loss' | 'flat' | 'none';

export interface DayTone {
  kind: DayKind;
  /** 0..1, proportional to |net| relative to the month's largest |net| */
  intensity: number;
}

/**
 * Green when net > 0, red when net < 0, neutral when 0 or no trades (spec P-24).
 * Intensity is |net| / max|net| of the month, with a visible floor of 0.2.
 */
export function dayTone(net: number, trades: number, maxAbs: number): DayTone {
  if (!trades) return { kind: 'none', intensity: 0 };
  const cents = Math.round(net * 100);
  if (cents === 0) return { kind: 'flat', intensity: 0 };
  const ratio = maxAbs > 0 ? Math.min(1, Math.abs(net) / maxAbs) : 1;
  return { kind: cents > 0 ? 'win' : 'loss', intensity: Math.round((0.2 + 0.8 * ratio) * 100) / 100 };
}

const RGB = { win: '0, 230, 118', loss: '255, 59, 105' } as const;

/** Inline style reproducing the design's .cal-win / .cal-loss gradient, scaled by intensity. */
export function dayStyle(t: DayTone): Record<string, string> | undefined {
  if (t.kind !== 'win' && t.kind !== 'loss') return undefined;
  const rgb = RGB[t.kind];
  const bg = (0.05 + 0.22 * t.intensity).toFixed(3);
  const border = (0.2 + 0.5 * t.intensity).toFixed(3);
  return {
    background: `linear-gradient(145deg, rgba(${rgb}, ${bg}) 0%, rgba(21, 26, 35, 0.95) 100%)`,
    borderColor: `rgba(${rgb}, ${border})`,
  };
}
