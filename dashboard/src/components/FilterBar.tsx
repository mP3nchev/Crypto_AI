// Global filter bar (spec P-24): symbols (multi), category, direction, tier.
// State lives in the URL query; every screen reads the same filters.
import { useEffect, useMemo, useRef, useState } from 'react';
import { getCategoryMap, getSymbols } from '../lib/api';
import { EMPTY_FILTERS, hasActiveFilters, type Filters } from '../lib/filters';
import { formatPair } from '../lib/format';
import type { Direction } from '../lib/types';
import { useAsync } from '../hooks/useAsync';
import { useFilters } from '../hooks/useFilters';
import { Modal, Segmented } from './ui';

function SymbolMultiSelect({ options, value, onChange }: { options: string[]; value: string[]; onChange: (v: string[]) => void }) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState('');
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [open]);
  const shown = options.filter((o) => o.includes(q.toUpperCase().replace('/', '')));
  const toggle = (s: string) => onChange(value.includes(s) ? value.filter((x) => x !== s) : [...value, s]);
  const label = value.length === 0 ? 'All trading pairs' : value.length <= 2 ? value.map(formatPair).join(', ') : `${value.length} pairs selected`;
  return (
    <div className="relative" ref={ref}>
      <button
        type="button" onClick={() => setOpen((o) => !o)} aria-haspopup="listbox" aria-expanded={open}
        className="w-full flex items-center justify-between gap-2 bg-obsidian border border-borderSubtle hover:border-slate-600 focus:border-electricBlue rounded-xl px-3 py-2 text-xs sm:text-sm font-mono text-white focus:outline-none cursor-pointer"
      >
        <span className="truncate">{label}</span>
        <i className="fa-solid fa-chevron-down text-[10px] text-slate-400" aria-hidden />
      </button>
      {open && (
        <div className="absolute z-40 mt-1.5 w-full min-w-[220px] bg-surface border border-borderSubtle rounded-xl shadow-2xl p-2">
          <input
            autoFocus value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search pair…"
            className="w-full mb-2 bg-obsidian border border-borderSubtle focus:border-electricBlue rounded-lg px-2.5 py-1.5 text-xs font-mono text-white focus:outline-none"
          />
          <ul role="listbox" aria-multiselectable className="max-h-60 overflow-y-auto space-y-0.5">
            {shown.length === 0 && <li className="px-2 py-1.5 text-xs text-slate-500">No pairs yet</li>}
            {shown.map((s) => {
              const on = value.includes(s);
              return (
                <li key={s}>
                  <button type="button" role="option" aria-selected={on} onClick={() => toggle(s)}
                    className={`w-full flex items-center gap-2 px-2 py-1.5 rounded-lg text-xs font-mono cursor-pointer ${on ? 'bg-electricBlue/15 text-white' : 'text-slate-300 hover:bg-surfaceHover'}`}>
                    <i className={`${on ? 'fa-solid fa-square-check text-electricBlue' : 'fa-regular fa-square text-slate-500'}`} aria-hidden />
                    {formatPair(s)}
                  </button>
                </li>
              );
            })}
          </ul>
          {value.length > 0 && (
            <button type="button" onClick={() => onChange([])} className="mt-2 w-full text-[11px] text-slate-400 hover:text-white cursor-pointer">Clear selection</button>
          )}
        </div>
      )}
    </div>
  );
}

function CategoriesModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const state = useAsync(() => (open ? getCategoryMap() : Promise.resolve([])), [open]);
  return (
    <Modal open={open} onClose={onClose} labelledBy="cat-title">
      <div className="p-5 border-b border-borderSubtle flex items-center justify-between bg-obsidian/60">
        <div>
          <h3 id="cat-title" className="text-base font-bold text-white">Asset Category Mapping</h3>
          <p className="text-xs text-slate-400">Pairs not listed here are grouped as <span className="font-mono">OTHER</span>.</p>
        </div>
        <button onClick={onClose} aria-label="Close" className="w-8 h-8 rounded-lg bg-surface hover:bg-surfaceHover border border-borderSubtle text-slate-400 hover:text-white flex items-center justify-center cursor-pointer">
          <i className="fa-solid fa-xmark" aria-hidden />
        </button>
      </div>
      <div className="p-5 space-y-2 max-h-[60vh] overflow-y-auto">
        {(state.data ?? []).map((c) => (
          <div key={c.symbol} className="flex items-center justify-between bg-obsidian border border-borderSubtle rounded-xl px-3.5 py-2.5">
            <span className="font-mono font-bold text-white text-xs">{formatPair(c.symbol)}</span>
            <span className="font-mono text-xs text-electricBlue">{c.category}</span>
          </div>
        ))}
        {state.error && <p className="text-xs text-crimsonNeon">{state.error.message}</p>}
      </div>
      <div className="p-4 border-t border-borderSubtle bg-obsidian/50 text-[11px] text-slate-400 leading-relaxed">
        The dashboard is read-only. To change a mapping, run in Supabase SQL Editor:<br />
        <code className="font-mono text-slate-300">insert into paper_symbol_categories values ('AVAXUSDT','L1_ALTS') on conflict (symbol) do update set category = excluded.category;</code><br />
        The category is stored on each position when it opens, so existing positions keep their category.
      </div>
    </Modal>
  );
}

export function FilterBar() {
  const [filters, setFilters] = useFilters();
  const [openMobile, setOpenMobile] = useState(false);
  const [catModal, setCatModal] = useState(false);
  const symbols = useAsync(getSymbols, []);
  const symbolOptions = useMemo(() => (symbols.data ?? []).map((s) => s.symbol), [symbols.data]);
  const categoryOptions = useMemo(
    () => [...new Set((symbols.data ?? []).map((s) => s.category ?? 'OTHER'))].sort(),
    [symbols.data],
  );
  const set = (patch: Partial<Filters>) => setFilters({ ...filters, ...patch });
  const active = hasActiveFilters(filters);
  const count = filters.symbols.length + filters.categories.length + (filters.direction ? 1 : 0) + filters.tiers.length;

  return (
    <div className="bg-surface border border-borderSubtle rounded-2xl">
      <button
        type="button" onClick={() => setOpenMobile((o) => !o)}
        className="sm:hidden w-full flex items-center justify-between px-4 py-3 text-xs font-semibold text-slate-200 cursor-pointer"
        aria-expanded={openMobile}
      >
        <span><i className="fa-solid fa-filter text-electricBlue mr-2" aria-hidden />Filters{count ? ` (${count})` : ''}</span>
        <i className={`fa-solid fa-chevron-${openMobile ? 'up' : 'down'} text-[10px] text-slate-400`} aria-hidden />
      </button>
      <div className={`${openMobile ? 'block' : 'hidden'} sm:block p-4 sm:p-5 pt-0 sm:pt-5`}>
        <div className="flex flex-col xl:flex-row xl:items-end gap-3">
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 flex-1">
            <div>
              <label className="block text-[11px] font-semibold uppercase tracking-wider text-slate-400 mb-1.5">Cryptocurrency Pair</label>
              <SymbolMultiSelect options={symbolOptions} value={filters.symbols} onChange={(v) => set({ symbols: v })} />
            </div>
            <div>
              <label htmlFor="filterCategory" className="block text-[11px] font-semibold uppercase tracking-wider text-slate-400 mb-1.5">Asset Category</label>
              <select
                id="filterCategory"
                value={filters.categories[0] ?? 'ALL'}
                onChange={(e) => set({ categories: e.target.value === 'ALL' ? [] : [e.target.value] })}
                className="w-full bg-obsidian border border-borderSubtle focus:border-electricBlue rounded-xl px-3 py-2 text-xs sm:text-sm text-white focus:outline-none cursor-pointer"
              >
                <option value="ALL">All asset classes</option>
                {categoryOptions.map((c) => <option key={c} value={c}>{c}</option>)}
              </select>
            </div>
            <div>
              <label className="block text-[11px] font-semibold uppercase tracking-wider text-slate-400 mb-1.5">Direction Bias</label>
              <Segmented<'ALL' | Direction>
                ariaLabel="Direction"
                value={filters.direction ?? 'ALL'}
                onChange={(v) => set({ direction: v === 'ALL' ? null : v })}
                options={[
                  { value: 'ALL', label: 'ALL' },
                  { value: 'LONG', label: 'LONG', activeClass: 'bg-emeraldNeon text-obsidian font-bold' },
                  { value: 'SHORT', label: 'SHORT', activeClass: 'bg-crimsonNeon text-white font-bold' },
                ]}
              />
            </div>
            <div>
              <label className="block text-[11px] font-semibold uppercase tracking-wider text-slate-400 mb-1.5">Tier</label>
              <div className="grid grid-cols-4 gap-1 bg-obsidian p-1 rounded-xl border border-borderSubtle" role="group" aria-label="Tier">
                <button type="button" onClick={() => set({ tiers: [] })} aria-pressed={filters.tiers.length === 0}
                  className={`py-1.5 rounded-lg text-xs cursor-pointer ${filters.tiers.length === 0 ? 'bg-electricBlue text-white font-semibold' : 'text-slate-400 hover:text-white font-medium'}`}>ALL</button>
                {[1, 2, 3].map((t) => {
                  const on = filters.tiers.includes(t);
                  return (
                    <button key={t} type="button" aria-pressed={on}
                      onClick={() => set({ tiers: on ? filters.tiers.filter((x) => x !== t) : [...filters.tiers, t] })}
                      className={`py-1.5 rounded-lg text-xs font-mono cursor-pointer ${on ? 'bg-electricBlue text-white font-semibold' : 'text-slate-400 hover:text-white font-medium'}`}>
                      T{t}
                    </button>
                  );
                })}
              </div>
            </div>
          </div>
          <div className="flex gap-2">
            <button type="button" onClick={() => setCatModal(true)}
              className="flex-1 xl:flex-none flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-obsidian hover:bg-surfaceHover border border-borderSubtle hover:border-electricBlue text-xs font-semibold text-slate-200 transition-all cursor-pointer">
              <i className="fa-solid fa-tags text-electricBlue" aria-hidden /><span>Categories</span>
            </button>
            <button type="button" disabled={!active} onClick={() => setFilters(EMPTY_FILTERS)}
              className="flex-1 xl:flex-none flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-obsidian border border-borderSubtle text-xs font-semibold text-slate-200 enabled:hover:border-slate-500 disabled:opacity-40 cursor-pointer disabled:cursor-default">
              <i className="fa-solid fa-rotate-left" aria-hidden /><span>Reset</span>
            </button>
          </div>
        </div>
      </div>
      <CategoriesModal open={catModal} onClose={() => setCatModal(false)} />
    </div>
  );
}
