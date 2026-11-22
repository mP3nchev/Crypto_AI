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
JSON.stringify(cs.map((c) => [c.id, c.timeframe, c.indicators.length])) === JSON.stringify([['BTCUSDT_1h', '1h', 9], ['BTCUSDT_15m', '15m', 2]])
  ? ok('2 constructs per symbol: 1h x9, 15m x2 (v2 has no 2h: those 9 come from 2H INDICATOR CALCULATOR)') : bad('construct layout');
!cs.some((c) => c.timeframe === '2h') ? ok('no unsupported "2h" timeframe is requested') : bad('2h construct present');
cs.every((c) => c.symbol === 'BTCUSDT' && c.exchange === 'binance' && !('interval' in c) && !('backtrack' in c))
  ? ok('symbol without slash, "timeframe" (not "interval"), exchange binance') : bad('construct fields');
cs.flatMap((c) => c.indicators).every((i) => i.backtrack === 1 && !('optInTimePeriod' in i)) ? ok('backtrack:1 on every indicator, no v1 "optInTimePeriod"') : bad('indicator params');
const periods = Object.fromEntries(cs.flatMap((c) => c.indicators.filter((i) => i.period).map((i) => [c.timeframe + '_' + i.id, i.period])));
JSON.stringify(periods) === JSON.stringify({ '1h_rsi': 14, '1h_atr': 14, '1h_ema20': 20, '1h_ema50': 50, '15m_willr': 14, '15m_rsi': 14 })
  ? ok('periods preserved from v1 (rsi/atr/willr 14, ema 20/50)') : bad('periods ' + JSON.stringify(periods));
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
const twoH = v1Indicator.filter((k) => k.endsWith('_2h'));
const rest = v1Indicator.filter((k) => !k.endsWith('_2h'));
JSON.stringify(got) === JSON.stringify(rest)
  ? ok(`processor returns the ${got.length} non-2h fields of the v1 processor (1h + 15m)`) : bad(`field mismatch\n   v1 only: ${rest.filter((k) => !got.includes(k))}\n   v2 only: ${got.filter((k) => !rest.includes(k))}`);
{ // processor + 2H INDICATOR CALCULATOR together must reproduce the complete v1 field set
  const CALC = fs.readFileSync('row2/2H INDICATOR CALCULATOR', 'utf8');
  const H2 = 2 * 3600e3, t0 = Math.floor(Date.now() / H2) * H2;
  const kl = Array.from({ length: 400 }, (_, i) => { const o = t0 - (399 - i) * H2, c = 100 + Math.sin(i / 7) * 5 + i * 0.01; return [o, c - 0.2, c + 1, c - 1, c, 1000 + i, o + H2 - 1, 0, 1, 0, 0, 0].map(String); });
  const merged = quiet(() => new Function('$input', '$', CALC)({ all: () => full.map(() => ({ json: { body: kl, statusCode: 200 } })) },
    (n) => { if (n !== 'TAAPI RESPONSE PROCESSOR') throw new Error(n); return { all: () => full }; }));
  const allKeys = Object.keys(merged[0].json).filter((k) => !meta.includes(k)).sort();
  JSON.stringify(allKeys) === JSON.stringify(v1Indicator)
    ? ok(`processor + 2H calculator = all ${allKeys.length} indicator fields of the v1 pipeline (names identical)`) : bad(`combined mismatch\n   v1 only: ${v1Indicator.filter((k) => !allKeys.includes(k))}\n   new only: ${allKeys.filter((k) => !v1Indicator.includes(k))}`);
  merged.length === 3 && merged[0].json.sma_20 === 100 && merged[0].json.rsi_1h !== undefined ? ok('metadata and TAAPI values survive the 2h step') : bad('metadata lost in 2h step');
}
meta.every((k) => k in f0) && f0.sma_20 === 100 && full[2].json.sma_20 === 102 && f0.symbol === 'BTCUSDT'
  ? ok('metadata + sma_20 carried over from the original request per symbol') : bad('metadata');

// value mapping spot checks (each field gets the number the matching construct/indicator/key produced)
const chk = (field, key) => expected[key] === f0[field] ? null : `${field}: expected ${expected[key]} got ${f0[field]}`;
const errs = [
  chk('macd_signal_1h', 'BTCUSDT_1h|macd|valueMACDSignal'), chk('macd_histogram_1h', 'BTCUSDT_1h|macd|valueMACDHist'),
  chk('ema_20_1h', 'BTCUSDT_1h|ema20|value'), chk('stochrsi_k_1h', 'BTCUSDT_1h|stochrsi|valueFastK'),
  chk('stochrsi_d_1h', 'BTCUSDT_1h|stochrsi|valueFastD'), chk('rsi_15m', 'BTCUSDT_15m|rsi|value'), chk('willr_15m', 'BTCUSDT_15m|willr|value'), chk('atr_1h', 'BTCUSDT_1h|atr|value'),
].filter(Boolean);
errs.length === 0 ? ok('values land in the right fields (1h/15m do not mix, macd/stochrsi sub-values correct)') : bad(errs.join('; '));
// every expected value is mapped exactly once
const used = new Set(Object.values(f0).filter((v) => typeof v === 'number' && !Number.isInteger(v) || (typeof v === 'number' && String(v).endsWith('.5'))));
Object.entries(expected).filter(([k]) => k.startsWith('BTCUSDT')).every(([, v]) => used.has(v)) ? ok('every returned number is used, none dropped') : bad('some returned numbers were not mapped');

// ---- 4. robustness ---------------------------------------------------------------------
{ // symbol split over two responses (e.g. a plan limited to 1 construct per request) -> merged into ONE result
  const a = respond(requests[0].json, ['BTCUSDT_1h']), b = respond(requests[0].json, ['BTCUSDT_15m']);
  const merged = run([a, b]);
  merged.length === 1 && 'rsi_1h' in merged[0].json && 'rsi_15m' in merged[0].json
    ? ok('constructs of one symbol arriving in separate responses are merged into one result') : bad('split merge');
}
{ // a missing indicator and an error object must not crash or invent numbers
  const r = respond(requests[0].json); delete r.BTCUSDT_1h.obv; r.BTCUSDT_1h.atr = { error: 'Indicator failed' };
  const res = run([r])[0].json;
  !('obv_1h' in res) && !('atr_1h' in res) && res.rsi_1h !== undefined ? ok('missing / errored indicator -> field absent, rest intact (no fake values)') : bad('missing indicator handling');
}
{ // multi-element arrays use the last value; non-numeric values are ignored
  const r = respond(requests[0].json); r.BTCUSDT_1h.rsi.value = [1, 2, 3]; r.BTCUSDT_1h.vwap.value = ['x'];
  const res = run([r])[0].json;
  res.rsi_1h === 3 && !('vwap_1h' in res) ? ok('array with several values -> last; non-numeric ignored') : bad('array handling');
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
