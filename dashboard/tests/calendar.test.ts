import { describe, expect, it } from 'vitest';
import { dayStyle, dayTone, isValidDay, isValidMonth, monthGrid, shiftDay, shiftMonth } from '../src/lib/calendar';

describe('calendar colouring (spec P-24)', () => {
  it('no trades -> neutral', () => {
    expect(dayTone(0, 0, 100)).toEqual({ kind: 'none', intensity: 0 });
    expect(dayStyle(dayTone(0, 0, 100))).toBeUndefined();
  });
  it('net 0 with trades -> neutral (flat)', () => {
    expect(dayTone(0.004, 3, 100).kind).toBe('flat');
    expect(dayStyle(dayTone(0, 2, 100))).toBeUndefined();
  });
  it('green when net > 0, red when net < 0', () => {
    expect(dayTone(25, 4, 25).kind).toBe('win');
    expect(dayTone(-8, 1, 25).kind).toBe('loss');
  });
  it('intensity is proportional to |net| vs the month maximum (with a floor)', () => {
    expect(dayTone(25, 4, 25).intensity).toBe(1);
    expect(dayTone(-12.5, 1, 25).intensity).toBe(0.6);
    expect(dayTone(0.5, 1, 1000).intensity).toBe(0.2);
    expect(dayTone(-30, 1, 25).intensity).toBe(1); // capped
  });
  it('style uses the design colours and grows with intensity', () => {
    const weak = dayStyle(dayTone(1, 1, 100))!;
    const strong = dayStyle(dayTone(100, 1, 100))!;
    expect(weak.background).toContain('0, 230, 118');
    expect(dayStyle(dayTone(-5, 1, 5))!.borderColor).toContain('255, 59, 105');
    expect(parseFloat(strong.borderColor.split(',')[3])).toBeGreaterThan(parseFloat(weak.borderColor.split(',')[3]));
  });
});

describe('calendar layout', () => {
  it('Monday-first grid: November 2026 starts on a Sunday', () => {
    const g = monthGrid('2026-11');
    expect(g.leading).toBe(6);
    expect(g.days).toHaveLength(30);
    expect(g.days[0]).toBe('2026-11-01');
  });
  it('February in a leap year', () => {
    expect(monthGrid('2028-02').days).toHaveLength(29);
  });
  it('shifts months and days across year boundaries', () => {
    expect(shiftMonth('2026-12', 1)).toBe('2027-01');
    expect(shiftMonth('2026-01', -1)).toBe('2025-12');
    expect(shiftDay('2026-12-31', 1)).toBe('2027-01-01');
  });
  it('validates URL date params', () => {
    expect(isValidDay('2026-02-30')).toBe(false);
    expect(isValidDay('2026-11-05')).toBe(true);
    expect(isValidMonth('2026-13')).toBe(false);
    expect(isValidMonth('2026-11')).toBe(true);
  });
});
