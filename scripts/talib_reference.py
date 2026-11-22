"""Reference values from the real TA-Lib for scripts/test_2h_indicators.js.
   python3 scripts/talib_reference.py OUT.json [seed]
Needs: pip install TA-Lib numpy   (test tooling only — not used in production)."""
import json, sys, time
import numpy as np, talib

out_path = sys.argv[1]
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 7
rng = np.random.default_rng(seed)
N = 1000
now_ms = int(time.time() * 1000)
H2 = 2 * 3600 * 1000
cases = {}
for name, vol, drift in [('calm', 0.004, 0.0), ('volatile', 0.02, 0.0004), ('trend_up', 0.008, 0.003), ('flat_gaps', 0.0005, 0.0), ('ties', 0.0008, 0.0)]:
    close = 100 * np.exp(np.cumsum(rng.normal(drift, vol, N)))
    if name == 'ties':   # low-priced coin: prices on a coarse tick -> many identical candles / typical prices
        close = np.round(close, 1)
    openp = np.concatenate([[100.0], close[:-1]])
    high = np.maximum(openp, close) * (1 + np.abs(rng.normal(0, vol / 2, N)))
    low = np.minimum(openp, close) * (1 - np.abs(rng.normal(0, vol / 2, N)))
    if name == 'ties':
        high = np.round(high, 1); low = np.round(low, 1); high = np.maximum(high, close); low = np.minimum(low, close)
    volume = np.exp(rng.normal(8, 0.8, N))
    # candle N-1 is still forming: its closeTime is in the future
    open_times = now_ms - (N - 1) * H2 - (now_ms % H2) + np.arange(N) * H2 - 0
    open_times = (now_ms // H2) * H2 - (N - 1 - np.arange(N)) * H2
    kl = [[int(open_times[i]), f'{openp[i]:.8f}', f'{high[i]:.8f}', f'{low[i]:.8f}', f'{close[i]:.8f}', f'{volume[i]:.4f}',
           int(open_times[i] + H2 - 1), '0', 1, '0', '0', '0'] for i in range(N)]
    # expected values are computed on the CLOSED candles (everything but the forming last one), from the
    # same rounded strings the node will parse
    c = np.array([float(k[4]) for k in kl[:-1]]); h = np.array([float(k[2]) for k in kl[:-1]])
    l = np.array([float(k[3]) for k in kl[:-1]]); v = np.array([float(k[5]) for k in kl[:-1]])
    m, s, hist = talib.MACD(c, 12, 26, 9)
    k_, d_ = talib.STOCHRSI(c, timeperiod=14, fastk_period=3, fastd_period=3, fastd_matype=0)
    exp = {
        'rsi_2h': talib.RSI(c, 14)[-1], 'macd_value_2h': m[-1], 'macd_signal_2h': s[-1], 'macd_histogram_2h': hist[-1],
        'adx_2h': talib.ADX(h, l, c, 14)[-1], 'ema_200_2h': talib.EMA(c, 200)[-1], 'ema_20_2h': talib.EMA(c, 20)[-1],
        'ema_50_2h': talib.EMA(c, 50)[-1], 'stochrsi_k_2h': k_[-1], 'stochrsi_d_2h': d_[-1],
        'willr_2h': talib.WILLR(h, l, c, 14)[-1], 'mfi_2h': talib.MFI(h, l, c, v, 14)[-1],
    }
    cases[name] = {'klines': kl, 'expected': {k: (None if np.isnan(x) else float(x)) for k, x in exp.items()}}
# a short history: only some indicators fit
short = cases['calm']['klines'][-61:]
c = np.array([float(k[4]) for k in short[:-1]]); h = np.array([float(k[2]) for k in short[:-1]])
l = np.array([float(k[3]) for k in short[:-1]]); v = np.array([float(k[5]) for k in short[:-1]])
cases['short_60'] = {'klines': short, 'expected': {
    'rsi_2h': float(talib.RSI(c, 14)[-1]), 'ema_20_2h': float(talib.EMA(c, 20)[-1]), 'ema_50_2h': float(talib.EMA(c, 50)[-1]),
    'adx_2h': float(talib.ADX(h, l, c, 14)[-1]), 'ema_200_2h': None}}
json.dump(cases, open(out_path, 'w'))
print('cases:', ', '.join(cases))
