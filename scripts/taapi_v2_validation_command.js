// PowerShell command that asks TAAPI v2 for the 9 indicators (same ids/params as the 2h set) on the 1h
// timeframe, for comparison with tools/validate_2h_vs_taapi.html.   node scripts/taapi_v2_validation_command.js [SYMBOL]
const symbol = (process.argv[2] || 'BTCUSDT').toUpperCase();
const ind = (id, indicator, period) => ({ id, indicator, backtrack: 1, ...(period ? { period } : {}) });
const body = { constructs: [{ id: `${symbol}_1h`, exchange: 'binance', symbol, timeframe: '1h', indicators: [
  ind('rsi', 'rsi', 14), ind('macd', 'macd'), ind('adx', 'adx', 14), ind('ema200', 'ema', 200), ind('stochrsi', 'stochrsi'),
  ind('willr', 'willr', 14), ind('mfi', 'mfi', 14), ind('ema20', 'ema', 20), ind('ema50', 'ema', 50)] }] };
console.log("$body = '" + JSON.stringify(body) + "'");
console.log('$r = Invoke-RestMethod -Method Post -Uri "https://v2.taapi.io/bulk" -Headers @{ Authorization = "Bearer ТВОЯТ_КЛЮЧ" } -ContentType "application/json" -Body $body; $r | ConvertTo-Json -Depth 10 | Set-Clipboard; $r | ConvertTo-Json -Depth 10');
