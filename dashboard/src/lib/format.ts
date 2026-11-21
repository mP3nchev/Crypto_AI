// Display formatting only — no financial calculations (spec P-22).
// USD and percentages: 2 decimals. Dates/times: Europe/Sofia.

export const TIMEZONE = 'Europe/Sofia';
const DASH = '—';

type Num = number | string | null | undefined;

function toNum(v: Num): number | null {
  if (v === null || v === undefined || v === '') return null;
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

const usd2 = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

/** 1234.5 -> "$1,234.50"; with sign: "+$1,234.50" / "-$1,234.50". */
export function formatUsd(v: Num, opts: { sign?: boolean } = {}): string {
  const n = toNum(v);
  if (n === null) return DASH;
  const rounded = Math.round(n * 100) / 100;
  const abs = usd2.format(Math.abs(rounded));
  if (opts.sign) {
    if (rounded > 0) return `+$${abs}`;
    if (rounded < 0) return `-$${abs}`;
    return `$${abs}`;
  }
  return rounded < 0 ? `-$${abs}` : `$${abs}`;
}

/** 2.4458 -> "2.45%"; with sign: "+2.45%". */
export function formatPct(v: Num, opts: { sign?: boolean; digits?: number } = {}): string {
  const n = toNum(v);
  if (n === null) return DASH;
  const d = opts.digits ?? 2;
  const factor = 10 ** d;
  const rounded = Math.round(n * factor) / factor;
  const body = Math.abs(rounded).toFixed(d);
  if (opts.sign && rounded > 0) return `+${body}%`;
  if (rounded < 0) return `-${body}%`;
  return `${body}%`;
}

/** Plain number with fixed decimals, e.g. profit factor "1.85". */
export function formatNumber(v: Num, digits = 2): string {
  const n = toNum(v);
  if (n === null) return DASH;
  return n.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

/** Price precision depends on magnitude (BTC 80,040.00 … PEPE 0.00001234). */
export function formatPrice(v: Num): string {
  const n = toNum(v);
  if (n === null) return DASH;
  const a = Math.abs(n);
  if (a >= 1000) return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  if (a >= 10) return n.toFixed(2);
  if (a >= 0.1) return n.toFixed(4);
  if (a === 0) return '0';
  return n.toLocaleString('en-US', { maximumSignificantDigits: 4, maximumFractionDigits: 10 });
}

function parts(iso: string, withTime: boolean): Record<string, string> {
  const f = new Intl.DateTimeFormat('en-GB', {
    timeZone: TIMEZONE,
    year: 'numeric', month: '2-digit', day: '2-digit',
    ...(withTime ? { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' as const } : {}),
  });
  const out: Record<string, string> = {};
  for (const p of f.formatToParts(new Date(iso))) out[p.type] = p.value;
  return out;
}

/** ISO timestamp -> "2026-11-21 14:05" in Europe/Sofia. */
export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return DASH;
  const p = parts(iso, true);
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}`;
}

/** ISO timestamp -> "14:05" in Europe/Sofia. */
export function formatTime(iso: string | null | undefined): string {
  if (!iso) return DASH;
  const p = parts(iso, true);
  return `${p.hour}:${p.minute}`;
}

/** Instant -> calendar date "YYYY-MM-DD" in Europe/Sofia. */
export function sofiaDate(instant: Date | string = new Date()): string {
  const p = parts(typeof instant === 'string' ? instant : instant.toISOString(), false);
  return `${p.year}-${p.month}-${p.day}`;
}

/** "2026-11-21" -> "Sat, 21 Nov 2026". A pure date: no timezone shift. */
export function formatLongDate(day: string): string {
  const [y, m, d] = day.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-GB', {
    timeZone: 'UTC', weekday: 'short', day: 'numeric', month: 'short', year: 'numeric',
  });
}

/** "2026-11" -> "November 2026". */
export function formatMonth(month: string): string {
  const [y, m] = month.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', {
    timeZone: 'UTC', month: 'long', year: 'numeric',
  });
}

/** 3.3 -> "3h 18m"; 50.5 -> "2d 2h 30m". */
export function formatDuration(hours: Num): string {
  const h = toNum(hours);
  if (h === null) return DASH;
  const totalMin = Math.round(h * 60);
  const d = Math.floor(totalMin / 1440);
  const hh = Math.floor((totalMin % 1440) / 60);
  const mm = totalMin % 60;
  if (d > 0) return `${d}d ${hh}h${mm ? ` ${mm}m` : ''}`;
  if (hh > 0) return `${hh}h ${String(mm).padStart(2, '0')}m`;
  return `${mm}m`;
}

/** "Signed" colour class for a value: positive green, negative red, zero neutral. */
export function toneClass(v: Num): string {
  const n = toNum(v);
  if (n === null || Math.round(n * 100) === 0) return 'text-slate-300';
  return n > 0 ? 'text-emeraldNeon' : 'text-crimsonNeon';
}

export const EXIT_REASON_LABEL: Record<string, string> = {
  TP1: 'Take Profit 1',
  TP2: 'Take Profit 2',
  TP3: 'Take Profit 3',
  SL: 'Stop Loss',
  BREAKEVEN_SL: 'Break-even Stop',
  TIMEOUT: 'Time Exit (max hold)',
  LIQUIDATION: 'Liquidation',
  DATA_UNAVAILABLE: 'No Market Data',
};

export function exitReasonLabel(reason: string | null | undefined): string {
  if (!reason) return DASH;
  return EXIT_REASON_LABEL[reason] ?? reason;
}

/** "STALE_SIGNAL: 52.3 min old (max 45)" -> { code: "STALE_SIGNAL", detail: "52.3 min old (max 45)" } */
export function splitReason(reason: string | null | undefined): { code: string; detail: string } {
  if (!reason) return { code: '', detail: '' };
  const i = reason.indexOf(':');
  return i < 0 ? { code: reason, detail: '' } : { code: reason.slice(0, i), detail: reason.slice(i + 1).trim() };
}

/** "BTCUSDT" -> "BTC/USDT" (display only). */
export function formatPair(symbol: string): string {
  for (const q of ['USDT', 'USDC', 'FDUSD', 'BUSD']) {
    if (symbol.endsWith(q) && symbol.length > q.length) return `${symbol.slice(0, -q.length)}/${q}`;
  }
  return symbol;
}
