// Closed trades table (design: "Executed & Closed Trades"); spec P-24 columns.
import { formatDuration, formatPair, formatPct, formatPrice, formatUsd, toneClass } from '../lib/format';
import type { Position } from '../lib/types';
import { ExitBadge, SideBadge, THEAD_ROW, TH, TierBadge } from './ui';

export function TradesTable({ rows, onOpen, compact }: { rows: Position[]; onOpen: (id: number) => void; compact?: boolean }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-left border-collapse">
        <thead>
          <tr className={THEAD_ROW}>
            <th className={`${TH} px-4`}>Pair</th>
            <th className={TH}>Direction</th>
            <th className={`${TH} text-right`}>Entry</th>
            <th className={`${TH} text-right`}>Exit (avg)</th>
            <th className={`${TH} text-right`}>Duration</th>
            <th className={`${TH} text-right`}>Net Result</th>
            <th className={`${TH} text-right`}>Return</th>
            <th className={TH}>Exit Reason</th>
            {!compact && <th className={`${TH} px-4 text-right`}>Details</th>}
          </tr>
        </thead>
        <tbody className="divide-y divide-borderSubtle/60 text-sm">
          {rows.map((t) => (
            <tr key={t.id} onClick={() => onOpen(t.id)} onKeyDown={(e) => e.key === 'Enter' && onOpen(t.id)} tabIndex={0}
              className="hover:bg-surfaceHover cursor-pointer transition-colors focus:outline-none focus:bg-surfaceHover">
              <td className="py-3 px-4 whitespace-nowrap">
                <span className="font-mono font-bold text-white">{formatPair(t.symbol)}</span> <TierBadge tier={t.tier} />
              </td>
              <td className="py-3 px-3"><SideBadge direction={t.direction} /></td>
              <td className="py-3 px-3 text-right font-mono text-slate-300 tabular-nums whitespace-nowrap">${formatPrice(t.entry_fill_price)}</td>
              <td className="py-3 px-3 text-right font-mono text-white tabular-nums whitespace-nowrap">${formatPrice(t.avg_exit_price)}</td>
              <td className="py-3 px-3 text-right font-mono text-xs text-slate-400 whitespace-nowrap">{formatDuration(t.duration_hours)}</td>
              <td className={`py-3 px-3 text-right font-mono font-bold tabular-nums whitespace-nowrap ${toneClass(t.realized_net_usd)}`}>{formatUsd(t.realized_net_usd, { sign: true })}</td>
              <td className={`py-3 px-3 text-right font-mono text-xs tabular-nums whitespace-nowrap ${toneClass(t.return_on_margin_pct)}`}>{formatPct(t.return_on_margin_pct, { sign: true })}</td>
              <td className="py-3 px-3"><ExitBadge reason={t.exit_reason} summary={t.exit_summary} /></td>
              {!compact && (
                <td className="py-3 px-4 text-right whitespace-nowrap">
                  <span className="text-xs text-electricBlue hover:underline font-medium">Inspect <i className="fa-solid fa-arrow-up-right-from-square text-[10px] ml-0.5" aria-hidden /></span>
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
