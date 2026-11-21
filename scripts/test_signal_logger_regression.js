// Compares the ORIGINAL SIGNAL LOGGER with the current one on the same inputs.
// What must NOT change (Telegram + ordering): the output items, their order, and every
// field of every item except the added/fixed logger fields on item[0].
const fs = require('fs');
const [, , oldPath, newPath] = process.argv;
const load = (p) => fs.readFileSync(p, 'utf8');
const run = (code, items) => {
  const log = console.log; console.log = () => {};          // the node logs a lot
  try { return new Function('$input', code)({ all: () => structuredClone(items) }); }
  finally { console.log = log; }
};
const OLD = load(oldPath), NEW = load(newPath);

const sig = (symbol, rank, selected = true, extra = {}) => ({ json: {
  selected_for_telegram: selected, scan_cycle_id: 'c1', cycle_timestamp: '2026-11-21T08:00:03.123Z',
  symbol, tier: 1, signal_direction: rank % 2 ? 'LONG' : 'SHORT', final_rank: rank,
  entry_price: 80000, stop_loss: 78800, take_profit_1: 81200, take_profit_2: 81600, take_profit_3: 82000,
  recommended_leverage: 1, market_condition: 'NEUTRAL', fee_adjusted_rr: 1.8, atr_percentage_1h: 0.9,
  momentum_score: 70, trend_score: 66, volatility_score: 55, volume_score: 61, price_action_score: 64,
  total_score: 77.2, total_score_pre_rr_bonus: 75, rr_bonus_applied_to_total: 2.2,
  tp_strategy: 'STRONG_TREND', entry_quality: 'GOOD', signal_strength: 'STRONG', confidence_level: 'HIGH',
  entry_min: 79900, entry_max: 80100, tp1_allocation: 40, tp2_allocation: 40, tp3_allocation: 20, sl_distance_pct: 1.5,
  applied_weights: { momentum: 0.3, trend: 0.3, volatility: 0.1, volume: 0.15, price_action: 0.15 },
  telegram_text: `msg ${symbol}`, ...extra } });

const cases = {
  'normal cycle (3 signals + 1 unselected)': [sig('BTCUSDT', 1), sig('ETHUSDT', 2), sig('SOLUSDT', 3), sig('XRPUSDT', 4, false)],
  'single signal': [sig('BTCUSDT', 1)],
  'no-signal notification': [{ json: { is_no_signal_notification: true, message: 'no signals' } }],
  'nothing selected': [sig('BTCUSDT', 1, false), sig('ETHUSDT', 2, false)],
  'old-style flat weights only': [sig('BTCUSDT', 1, true, { applied_weights: undefined, weight_momentum: 0.2, weight_trend: 0.4, weight_volatility: 0.1, weight_volume: 0.15, weight_price_action: 0.15 })],
  'fields missing (older upstream)': [sig('BTCUSDT', 1, true, { entry_min: undefined, tp1_allocation: undefined, cycle_timestamp: undefined, applied_weights: undefined })],
};

let fail = 0;
const bad = (c, m) => { console.log(`  FAIL [${c}] ${m}`); fail = 1; };
const strip = (item) => { const j = { ...item.json }; delete j._signal_logger_payload; delete j._signal_logger_count; return j; };
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

for (const [name, input] of Object.entries(cases)) {
  const o = run(OLD, input), n = run(NEW, input);
  if (o.length !== n.length) { bad(name, `item count ${o.length} -> ${n.length}`); continue; }
  // 1. all items (what Telegram reads) identical, same order
  o.forEach((oi, i) => { if (!eq(strip(oi), strip(n[i]))) bad(name, `item ${i} differs`); });
  // 2. payload presence/count identical
  const op = o[0]?.json?._signal_logger_payload, np = n[0]?.json?._signal_logger_payload;
  if ((op === undefined) !== (np === undefined)) { bad(name, 'payload presence changed'); continue; }
  if (o[0]?.json?._signal_logger_count !== n[0]?.json?._signal_logger_count) bad(name, 'count changed');
  if (!op) { console.log(`  ok   ${name} (no payload, items unchanged)`); continue; }
  // 3. same rows in the same order; every OLD field keeps its value except score_snapshot.weights
  op.forEach((orow, i) => {
    const nrow = np[i];
    for (const k of Object.keys(orow)) {
      if (k === 'score_snapshot') {
        const { weights: ow, ...orest } = orow.score_snapshot; const { weights: nw, ...nrest } = nrow.score_snapshot;
        if (!eq(orest, nrest)) bad(name, `row ${i} score_snapshot changed beyond weights`);
        const flat = (w) => Object.values(w).every((v) => v === null);
        if (!flat(ow) && !eq(ow, nw)) bad(name, `row ${i} weights that were present changed`);
      } else if (!eq(orow[k], nrow[k])) bad(name, `row ${i} field ${k}: ${orow[k]} -> ${nrow[k]}`);
    }
    // 4. new fields present
    for (const k of ['entry_min', 'entry_max', 'tp1_allocation', 'tp2_allocation', 'tp3_allocation', 'sl_distance_pct', 'total_score', 'cycle_timestamp'])
      if (!(k in nrow)) bad(name, `row ${i} missing new field ${k}`);
  });
  console.log(`  ok   ${name} (${np.length} rows; items + existing fields unchanged)`);
}

// 5. the weights fix itself
const fixed = run(NEW, cases['normal cycle (3 signals + 1 unselected)'])[0].json._signal_logger_payload[0].score_snapshot.weights;
const was = run(OLD, cases['normal cycle (3 signals + 1 unselected)'])[0].json._signal_logger_payload[0].score_snapshot.weights;
if (!Object.values(was).every((v) => v === null)) { console.log('  note: old logger already had weights'); }
if (!Object.values(fixed).every((v) => typeof v === 'number')) bad('weights fix', `weights not numeric: ${JSON.stringify(fixed)}`);
else console.log(`  ok   weights fix: ${JSON.stringify(was)} -> ${JSON.stringify(fixed)}`);
const fb = run(NEW, cases['old-style flat weights only'])[0].json._signal_logger_payload[0].score_snapshot.weights;
if (fb.trend !== 0.4) bad('weights fallback', 'weight_* fallback not honoured'); else console.log('  ok   weights fallback to flat weight_* fields');

process.exit(fail);
