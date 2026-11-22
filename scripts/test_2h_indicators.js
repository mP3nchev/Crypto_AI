// Compares "2H INDICATOR CALCULATOR" with the real TA-Lib (reference values from scripts/talib_reference.py)
//   node scripts/test_2h_indicators.js REFERENCE.json
const fs = require('fs');
const CODE = fs.readFileSync('row2/2H INDICATOR CALCULATOR', 'utf8');
const ref = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const TOL = 1e-6;                         // relative; the algorithms are identical, only float order differs
let fail = 0;

function runNode(klines, extra = {}) {
  const base = [{ json: { symbol: 'TESTUSDT', symbol_id: 1, scan_cycle_id: 'c', cycle_timestamp: 't', sma_20: 5, rsi_1h: 55 } }];
  const input = [{ json: { body: klines, statusCode: 200 }, pairedItem: { item: 0 }, ...extra }];
  const log = console.log; console.log = () => {};
  try {
    return new Function('$input', '$', CODE)({ all: () => input }, (n) => { if (n !== 'TAAPI RESPONSE PROCESSOR') throw new Error(n); return { all: () => base }; });
  } finally { console.log = log; }
}

for (const [name, c] of Object.entries(ref)) {
  const out = runNode(c.klines)[0].json;
  const diffs = [];
  for (const [f, want] of Object.entries(c.expected)) {
    if (want === null) { if (f in out) diffs.push(`${f}: must be absent (not enough history) but is ${out[f]}`); continue; }
    const got = out[f];
    if (got === undefined) { diffs.push(`${f}: missing (want ${want})`); continue; }
    const rel = Math.abs(got - want) / Math.max(1e-9, Math.abs(want));
    if (rel > TOL && Math.abs(got - want) > 1e-9) diffs.push(`${f}: got ${got} want ${want} (rel ${rel.toExponential(2)})`);
  }
  const extras = ['symbol', 'symbol_id', 'scan_cycle_id', 'sma_20', 'rsi_1h'].filter((k) => !(k in out));
  if (extras.length) diffs.push(`base fields lost: ${extras}`);
  if (diffs.length) { fail = 1; console.log(`  FAIL ${name}\n    ` + diffs.join('\n    ')); }
  else console.log(`  ok   ${name}: ${Object.keys(c.expected).filter((k) => c.expected[k] !== null).length} fields match TA-Lib (rel tol ${TOL})`);
}

// the forming candle must be ignored: changing it must change nothing
{
  const c = ref.calm.klines.map((k) => k.slice());
  const a = runNode(c)[0].json;
  const last = c[c.length - 1]; last[2] = '999999'; last[3] = '0.0001'; last[4] = '12345'; last[5] = '1e9';
  const b = runNode(c)[0].json;
  JSON.stringify(a) === JSON.stringify(b) ? console.log('  ok   the still-forming last candle is ignored (backtrack 1 semantics)')
    : (fail = 1, console.log('  FAIL forming candle influenced the result'));
}
// robustness: Binance error / empty body must keep the TAAPI result and add nothing
{
  const log = console.log; console.log = () => {};
  const base = [{ json: { symbol: 'AAAUSDT', symbol_id: 9, sma_20: 1, rsi_1h: 40 } }];
  const run = (input) => new Function('$input', '$', CODE)({ all: () => input }, () => ({ all: () => base }));
  const e1 = run([{ json: { error: { message: 'timeout' } } }])[0].json;
  const e2 = run([{ json: { body: { code: -1121, msg: 'Invalid symbol.' }, statusCode: 400 } }])[0].json;
  const e3 = run([{ json: { body: [], statusCode: 200 } }])[0].json;
  console.log = log;
  const clean = (j) => Object.keys(j).filter((k) => k.endsWith('_2h')).length === 0 && j.rsi_1h === 40 && j.symbol === 'AAAUSDT';
  clean(e1) && clean(e2) && clean(e3) ? console.log('  ok   Binance error / bad symbol / empty body: TAAPI data kept, no 2h fields invented')
    : (fail = 1, console.log('  FAIL error handling'));
}
process.exit(fail);
