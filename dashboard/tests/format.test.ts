import { describe, expect, it } from 'vitest';
import {
  formatDateTime, formatDuration, formatLongDate, formatMonth, formatPair, formatPct, formatPrice,
  formatTime, formatUsd, sofiaDate, splitReason, toneClass,
} from '../src/lib/format';

describe('formatUsd (2 decimals)', () => {
  it('formats with grouping and two decimals', () => {
    expect(formatUsd(1234.5)).toBe('$1,234.50');
    expect(formatUsd(0)).toBe('$0.00');
    expect(formatUsd(-4.26893)).toBe('-$4.27');
  });
  it('adds an explicit sign when asked', () => {
    expect(formatUsd(6.2263, { sign: true })).toBe('+$6.23');
    expect(formatUsd(-1.2229, { sign: true })).toBe('-$1.22');
    expect(formatUsd(0.004, { sign: true })).toBe('$0.00');
  });
  it('accepts numeric strings and handles nulls', () => {
    expect(formatUsd('17.005')).toBe('$17.01');
    expect(formatUsd(null)).toBe('—');
    expect(formatUsd(undefined)).toBe('—');
    expect(formatUsd('abc')).toBe('—');
  });
});

describe('formatPct (2 decimals)', () => {
  it('formats percentages', () => {
    expect(formatPct(-2.4458)).toBe('-2.45%');
    expect(formatPct(12.4526, { sign: true })).toBe('+12.45%');
    expect(formatPct(50)).toBe('50.00%');
    expect(formatPct(83.333, { digits: 1 })).toBe('83.3%');
    expect(formatPct(null)).toBe('—');
  });
});

describe('formatPrice', () => {
  it('scales precision with magnitude', () => {
    expect(formatPrice(80040)).toBe('80,040.00');
    expect(formatPrice(132.5703)).toBe('132.57');
    expect(formatPrice(3.72)).toBe('3.7200');
    expect(formatPrice(0.00001234)).toBe('0.00001234');
    expect(formatPrice(null)).toBe('—');
  });
});

describe('dates in Europe/Sofia', () => {
  it('converts UTC instants to Sofia local time (winter UTC+2)', () => {
    expect(formatDateTime('2026-11-05T23:30:00Z')).toBe('2026-11-06 01:30');
    expect(formatTime('2026-11-05T21:30:00Z')).toBe('23:30');
  });
  it('handles summer time (UTC+3)', () => {
    expect(formatDateTime('2026-07-01T21:30:00Z')).toBe('2026-07-02 00:30');
  });
  it('gives the Sofia calendar date of an instant (spec T17 boundary)', () => {
    expect(sofiaDate(new Date('2026-11-05T21:59:59Z'))).toBe('2026-11-05');
    expect(sofiaDate(new Date('2026-11-05T22:00:00Z'))).toBe('2026-11-06');
  });
  it('formats pure dates without timezone shift', () => {
    expect(formatLongDate('2026-11-21')).toBe('Sat, 21 Nov 2026');
    expect(formatMonth('2026-11')).toBe('November 2026');
  });
  it('returns a dash for missing timestamps', () => {
    expect(formatDateTime(null)).toBe('—');
  });
});

describe('misc display helpers', () => {
  it('formats durations', () => {
    expect(formatDuration(3.3)).toBe('3h 18m');
    expect(formatDuration(0.5)).toBe('30m');
    expect(formatDuration(72 + 46 / 60)).toBe('3d 0h 46m');
    expect(formatDuration(null)).toBe('—');
  });
  it('formats pairs', () => {
    expect(formatPair('BTCUSDT')).toBe('BTC/USDT');
    expect(formatPair('XYZ')).toBe('XYZ');
  });
  it('splits status reasons', () => {
    expect(splitReason('STALE_SIGNAL: 52.3 min old (max 45)')).toEqual({ code: 'STALE_SIGNAL', detail: '52.3 min old (max 45)' });
    expect(splitReason('PAPER_DISABLED')).toEqual({ code: 'PAPER_DISABLED', detail: '' });
  });
  it('picks a tone class by sign (rounded to cents)', () => {
    expect(toneClass(1)).toBe('text-emeraldNeon');
    expect(toneClass(-0.5)).toBe('text-crimsonNeon');
    expect(toneClass(0.004)).toBe('text-slate-300');
  });
});
