// Builds tools/validate_2h_vs_taapi.html from the REAL calculator code (so it can never drift):
// the page embeds the indicator library of "2H INDICATOR CALCULATOR" and compares it with a TAAPI v2 response.
//   node scripts/build_validator.js
const fs = require('fs');
const src = fs.readFileSync('row2/2H INDICATOR CALCULATOR', 'utf8');
const a = src.indexOf('// ---------- indicator library');
const b = src.indexOf('// ---------- N8N wiring');
if (a < 0 || b < 0) throw new Error('markers not found');
const lib = src.slice(a, b);
const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>2h indicators vs TAAPI</title>
<style>
 body{background:#0B0E14;color:#E2E8F0;font:14px Inter,system-ui,sans-serif;margin:0;padding:24px;max-width:980px}
 h1{font-size:18px;margin:0 0 4px} p{color:#94A3B8;margin:4px 0 14px} label{display:block;margin:12px 0 4px;font-weight:600}
 textarea,input,select{width:100%;box-sizing:border-box;background:#151A23;border:1px solid #232A3B;color:#E2E8F0;border-radius:8px;padding:8px;font:13px ui-monospace,Consolas,monospace}
 textarea{height:170px} button{margin-top:12px;background:#2979FF;border:0;color:#fff;font-weight:600;padding:10px 18px;border-radius:8px;cursor:pointer}
 table{border-collapse:collapse;width:100%;margin-top:16px} th,td{border-bottom:1px solid #232A3B;padding:6px 8px;text-align:right;font:13px ui-monospace,Consolas,monospace}
 th:first-child,td:first-child{text-align:left} .ok{color:#00E676} .bad{color:#FF3B69} .warn{color:#FFB300} #msg{margin-top:12px;white-space:pre-wrap}
</style></head><body>
<h1>2h indicators: my calculation vs TAAPI</h1>
<p>Runs on your computer only. Nothing is uploaded and your TAAPI key is never needed here.
 1) Run the PowerShell command from the chat (it asks TAAPI for the SAME indicators on the <b>1h</b> timeframe).
 2) Paste its output below. 3) Press Compare: the page downloads the Binance candles, calculates the indicators with the
 exact library used in N8N, and shows the difference to TAAPI.</p>
<label>Symbol (the one used in the PowerShell command)</label><input id="sym" value="BTCUSDT">
<label>TAAPI response (the JSON printed by PowerShell)</label><textarea id="resp" placeholder='{ "BTCUSDT_1h": { "rsi": { "value": [ ... ] }, ... } }'></textarea>
<button id="go">Compare</button><div id="msg"></div><div id="out"></div>
<script>
${lib}
const MAP = [
  ['rsi','value','rsi_2h'],['macd','valueMACD','macd_value_2h'],['macd','valueMACDSignal','macd_signal_2h'],['macd','valueMACDHist','macd_histogram_2h'],
  ['adx','value','adx_2h'],['ema200','value','ema_200_2h'],['ema20','value','ema_20_2h'],['ema50','value','ema_50_2h'],
  ['stochrsi','valueFastK','stochrsi_k_2h'],['stochrsi','valueFastD','stochrsi_d_2h'],['willr','value','willr_2h'],['mfi','value','mfi_2h']];
const $ = (id) => document.getElementById(id);
const fmt = (x) => (typeof x === 'number' ? x.toFixed(6) : '—');
$('go').onclick = async () => {
  $('msg').textContent = 'Working…'; $('out').innerHTML = '';
  try {
    const sym = $('sym').value.trim().toUpperCase();
    let taapi = JSON.parse($('resp').value);
    const key = Object.keys(taapi).find((k) => k.startsWith(sym)) || Object.keys(taapi)[0];
    const res = taapi[key];
    const ts = (res.rsi && res.rsi.timestamp && res.rsi.timestamp[0]) || (Object.values(res)[0].timestamp || [])[0];
    if (!ts) throw new Error('No timestamp in the TAAPI response.');
    const r = await fetch('https://api.binance.com/api/v3/klines?symbol=' + sym + '&interval=1h&limit=1000');
    if (!r.ok) throw new Error('Binance answered HTTP ' + r.status);
    const all = await r.json();
    // TAAPI says which candle it used (timestamp): use the candles up to and including that one
    const kl = all.filter((k) => k[0] <= ts * 1000);
    if (!kl.length || kl[kl.length - 1][0] !== ts * 1000) throw new Error('Candle ' + new Date(ts * 1000).toISOString() + ' is not in the last 1000 Binance candles (run the PowerShell command again, then Compare immediately).');
    const mine = compute2h(kl, Infinity).fields;
    // alternative StochRSI settings, to see which one TAAPI uses by default
    const close = kl.map((k) => Number(k[4])); const alt = stochRsi(close, 14, 5, 3);
    let html = '<table><tr><th>indicator</th><th>TAAPI</th><th>mine</th><th>difference</th><th>status</th></tr>', worst = 0, missing = 0;
    for (const [id, k, field] of MAP) {
      const t = res[id] && res[id][k] && res[id][k][0];
      const m = mine[field];
      if (typeof t !== 'number' || typeof m !== 'number') { missing++; html += '<tr><td>' + field + '</td><td>' + fmt(t) + '</td><td>' + fmt(m) + '</td><td>—</td><td class="warn">missing</td></tr>'; continue; }
      const rel = Math.abs(t - m) / Math.max(1e-9, Math.abs(t)); worst = Math.max(worst, rel);
      const cls = rel < 1e-4 ? 'ok' : rel < 1e-2 ? 'warn' : 'bad';
      html += '<tr><td>' + field + '</td><td>' + fmt(t) + '</td><td>' + fmt(m) + '</td><td>' + (rel * 100).toExponential(2) + ' %</td><td class="' + cls + '">' + (cls === 'ok' ? 'MATCH' : cls === 'warn' ? 'close' : 'DIFFERENT') + '</td></tr>';
    }
    html += '</table>';
    const tk = res.stochrsi && res.stochrsi.valueFastK && res.stochrsi.valueFastK[0];
    const note = typeof tk === 'number' ? '\\nStochRSI check: TAAPI default FastK = ' + fmt(tk) + ' | mine with fastK 3 = ' + fmt(mine.stochrsi_k_2h) + ' | mine with fastK 5 (TA-Lib default) = ' + fmt(alt.k[alt.k.length - 1]) : '';
    $('msg').innerHTML = 'Candle used by TAAPI: ' + new Date(ts * 1000).toISOString() + ' (' + kl.length + ' candles of history).<br>Worst difference: <b class="' + (worst < 1e-4 ? 'ok' : worst < 1e-2 ? 'warn' : 'bad') + '">' + (worst * 100).toExponential(2) + ' %</b>' + (missing ? ' · ' + missing + ' value(s) missing' : '') + note.replace(/\\n/g, '<br>');
    $('out').innerHTML = html;
  } catch (e) { $('msg').innerHTML = '<span class="bad">' + e.message + '</span>'; }
};
</script></body></html>`;
fs.writeFileSync('tools/validate_2h_vs_taapi.html', html);
console.log('written tools/validate_2h_vs_taapi.html (' + html.length + ' bytes, library ' + lib.length + ' bytes)');
