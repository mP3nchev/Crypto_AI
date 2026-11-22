// Offline checks for the TAAPI v2 migration (Row 2):
//   * "Separation of Requests" builds valid v2 bulk bodies (20 indicators, ids, params)
//   * "TAAPI RESPONSE PROCESSOR" turns a v2-shaped response back into the SAME scan fields the
//     v1 processor produced (so "Final post to DB" and later nodes are unaffected)
//   * ids in the request and in the processor cannot drift apart
// The response shape comes from a real call on the user's account (verified 2026-11-22).
const fs = require('fs');
const { execSync } = require('child_process');
const BUILDER = fs.readFileSync('row2/Separation of Requests', 'utf8');
const PROC = fs.readFileSync('row2/TAAPI RESPONSE PROCESSOR', 'utf8');
const OLD_PROC = execSync('git show 7ac6881:"row2/TAAPI RESPONSE PROCESSOR"', { encoding: 'utf8' });

let fail = 0;
const ok = (m) => console.log('  ok   ' + m);
const bad = (m) => { console.log('  FAIL ' + m); fail = 1; };
const quiet = (f) => { const l = console.log, e = console.error; console.log = () => {}; console.error = () => {}; try { return f(); } finally { console.log = l; console.error = e; } };

const symbols = ['BTCUSDT', 'ETHUSDT', 'SOLUSDT'];
const input = symbols.map((s, i) => ({ json: { symbol: s, symbol_id: i + 1, scan_cycle_id: '2026-11-22_10:09', cycle_timestamp: '2026-11-22T10:09:29.924+00:00', sma_20: 100 + i } }));
const requests = quiet(() => new Function('$input', BUILDER)({ all: () => input }));

// ---- 1. request shape -------------------------------------------------------------
requests.length === 3 ? ok('one request item per symbol') : bad('request count ' + requests.length);
const r0 = requests[0].json;
const cs = r0.constructs;
JSON.stringify(cs.map((c) => [c.id, c.timeframe, c.indicators.length])) === JSON.stringify([['BTCUSDT_2h', '2h', 9], ['BTCUSDT_1h', '1h', 9], ['BTCUSDT_15m', '15m', 2]])
  ? ok('3 constructs per symbol: 2h x9, 1h x9, 15m x2 (= 20 indicators, as in v1)') : bad('construct layout');
cs.every((c) => c.symbol === 'BTCUSDT' && c.exchange === 'binance' && !('interval' in c) && !('backtrack' in c))
  ? ok('symbol without slash, "timeframe" (not "interval"), exchange binance') : bad('construct fields');
cs.flatMap((c) => c.indicators).every((i) => i.backtrack === 1 && !('optInTimePeriod' in i)) ? ok('backtrack:1 on every indicator, no v1 "optInTimePeriod"') : bad('indicator params');
const periods = Object.fromEntries(cs.flatMap((c) => c.indicators.filter((i) => i.period).map((i) => [c.timeframe + '_' + i.id, i.period])));
JSON.stringify(periods) === JSON.stringify({ '2h_rsi': 14, '2h_adx': 14, '2h_ema200': 200, '2h_willr': 14, '2h_mfi': 14, '2h_ema20': 20, '2h_ema50': 50, '1h_rsi': 14, '1h_atr': 14, '1h_ema20': 20, '1h_ema50': 50, '15m_willr': 14, '15m_rsi': 14 })
  ? ok('periods preserved from v1 (rsi/adx/willr/mfi/atr 14, ema 20/50/200)') : bad('periods ' + JSON.stringify(periods));
!JSON.stringify(requests).includes('secret') ? ok('no API key / "secret" in the request items') : bad('secret leaked into items');
const body = JSON.stringify({ constructs: r0.constructs });
body.length < 8000 ? ok(`request body ${body.length} bytes`) : bad('body too large');

// ---- 2. fake TAAPI v2 response built from the request itself ------------------------
const MULTI = { macd: ['valueMACD', 'valueMACDSignal', 'valueMACDHist'], stochrsi: ['valueFastK', 'valueFastD'] };
let seq = 1;
const expected = {};
function respond(symbolRequest, onlyIds) {
  const out = {};
  for (const c of symbolRequest.constructs) {
    if (onlyIds && !onlyIds.includes(c.id)) continue;
    out[c.id] = {};
    for (const i of c.indicators) {
      const keys = MULTI[i.indicator] || ['value'];
      out[c.id][i.id] = { timestamp: [1795345200] };
      for (const k of keys) { const v = seq++ + 0.5; out[c.id][i.id][k] = [v]; expected[`${c.id}|${i.id}|${k}`] = v; }
    }
  }
  return out;
}
const run = (responses) => quiet(() => new Function('$input', '$', PROC)(
  { all: () => responses.map((j) => ({ json: j })) },
  (n) => { if (n !== 'Separation of Requests') throw new Error('unexpected node ' + n); return { all: () => requests }; }));

// ---- 3. processor output = v1 field set ---------------------------------------------
const v1Fields = [...new Set([...OLD_PROC.matchAll(/scanResult\.(\w+)\s*=/g)].map((m) => m[1]))].sort();
const full = run(requests.map((r) => respond(r.json)));
full.length === 3 ? ok('one result per symbol') : bad('result count ' + full.length);
const f0 = full[0].json;
const meta = ['symbol_id', 'symbol', 'cycle_timestamp', 'scan_cycle_id', 'scan_time', 'scan_date', 'sma_20'];
const got = Object.keys(f0).filter((k) => !meta.includes(k)).sort();
const v1Indicator = v1Fields.filter((k) => !meta.includes(k));
JSON.stringify(got) === JSON.stringify(v1Indicator)
  ? ok(`same ${got.length} indicator fields as the v1 processor`) : bad(`field mismatch\n   v1 only: ${v1Indicator.filter((k) => !got.includes(k))}\n   v2 only: ${got.filter((k) => !v1Indicator.includes(k))}`);
meta.every((k) => k in f0) && f0.sma_20 === 100 && full[2].json.sma_20 === 102 && f0.symbol === 'BTCUSDT'
  ? ok('metadata + sma_20 carried over from the original request per symbol') : bad('metadata');

// value mapping spot checks (each field gets the number the matching construct/indicator/key produced)
const chk = (field, key) => expected[key] === f0[field] ? null : `${field}: expected ${expected[key]} got ${f0[field]}`;
const errs = [
  chk('rsi_2h', 'BTCUSDT_2h|rsi|value'), chk('macd_signal_2h', 'BTCUSDT_2h|macd|valueMACDSignal'), chk('macd_histogram_1h', 'BTCUSDT_1h|macd|valueMACDHist'),
  chk('ema_200_2h', 'BTCUSDT_2h|ema200|value'), chk('ema_20_1h', 'BTCUSDT_1h|ema20|value'), chk('stochrsi_k_2h', 'BTCUSDT_2h|stochrsi|valueFastK'),
  chk('stochrsi_d_1h', 'BTCUSDT_1h|stochrsi|valueFastD'), chk('rsi_15m', 'BTCUSDT_15m|rsi|value'), chk('willr_15m', 'BTCUSDT_15m|willr|value'), chk('atr_1h', 'BTCUSDT_1h|atr|value'),
].filter(Boolean);
errs.length === 0 ? ok('values land in the right fields (2h/1h/15m do not mix, macd/stochrsi sub-values correct)') : bad(errs.join('; '));
// every expected value is mapped exactly once
const used = new Set(Object.values(f0).filter((v) => typeof v === 'number' && !Number.isInteger(v) || (typeof v === 'number' && String(v).endsWith('.5'))));
Object.entries(expected).filter(([k]) => k.startsWith('BTCUSDT')).every(([, v]) => used.has(v)) ? ok('every returned number is used, none dropped') : bad('some returned numbers were not mapped');

// ---- 4. robustness ---------------------------------------------------------------------
{ // symbol split over two responses (e.g. a plan limited to 1 construct per request) -> merged into ONE result
  const a = respond(requests[0].json, ['BTCUSDT_2h']), b = respond(requests[0].json, ['BTCUSDT_1h', 'BTCUSDT_15m']);
  const merged = run([a, b]);
  merged.length === 1 && 'rsi_2h' in merged[0].json && 'rsi_1h' in merged[0].json && 'rsi_15m' in merged[0].json
    ? ok('constructs of one symbol arriving in separate responses are merged into one result') : bad('split merge');
}
{ // a missing indicator and an error object must not crash or invent numbers
  const r = respond(requests[0].json); delete r.BTCUSDT_1h.obv; r.BTCUSDT_2h.mfi = { error: 'Indicator failed' };
  const res = run([r])[0].json;
  !('obv_1h' in res) && !('mfi_2h' in res) && res.rsi_2h !== undefined ? ok('missing / errored indicator -> field absent, rest intact (no fake values)') : bad('missing indicator handling');
}
{ // multi-element arrays use the last value; non-numeric values are ignored
  const r = respond(requests[0].json); r.BTCUSDT_2h.rsi.value = [1, 2, 3]; r.BTCUSDT_2h.adx.value = ['x'];
  const res = run([r])[0].json;
  res.rsi_2h === 3 && !('adx_2h' in res) ? ok('array with several values -> last; non-numeric ignored') : bad('array handling');
}
{ // HTTP error body / empty input
  const res = run([{ error: 'Invalid or inactive token' }]);
  res.length === 1 && res[0].json.error === 'No TAAPI data processed' ? ok('error response -> explicit "No TAAPI data processed" (same as v1)') : bad('error body');
}
{ // unknown symbol (no original request) is skipped
  const res = run([{ 'ZZZUSDT_1h': { rsi: { value: [1] } } }]);
  res[0].json.error ? ok('response for an unknown symbol is ignored') : bad('unknown symbol');
}
process.exit(fail);
