// Prints a PowerShell command that sends EXACTLY the request "Separation of Requests" builds for one
// symbol to TAAPI v2, so the real response can be checked before touching N8N.
//   node scripts/taapi_v2_test_command.js [SYMBOL]
const fs = require('fs');
const symbol = (process.argv[2] || 'BTCUSDT').toUpperCase();
const code = fs.readFileSync('row2/Separation of Requests', 'utf8');
const items = [{ json: { symbol, symbol_id: 1, scan_cycle_id: 'test', cycle_timestamp: new Date().toISOString(), sma_20: 1 } }];
const l = console.log, e = console.error; console.log = () => {}; console.error = () => {};
const out = new Function('$input', code)({ all: () => items });
console.log = l; console.error = e;
const body = JSON.stringify({ constructs: out[0].json.constructs });
console.log("$body = '" + body + "'");
console.log('Invoke-RestMethod -Method Post -Uri "https://v2.taapi.io/bulk" -Headers @{ Authorization = "Bearer ТВОЯТ_КЛЮЧ" } -ContentType "application/json" -Body $body | ConvertTo-Json -Depth 10');
