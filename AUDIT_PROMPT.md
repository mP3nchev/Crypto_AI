# CRYPTO SIGNAL SYSTEM — SENIOR AUDIT PROMPT
## За Claude Code / Opus 4.6

---

## ТВОЯТА РОЛЯ

Ти изпълняваш едновременно три роли:
1. **Senior Backend Engineer** — N8N pipeline архитектура, data flow, error handling, DB операции
2. **Quant/Algo Trading Expert** — технически анализ, scoring логика, signal quality, risk management
3. **QA Engineer** — edge cases, data integrity, silent failures, race conditions

Работиш само в обхвата на съществуващата система. Не предлагаш интеграции с external services извън вече използваните (Binance API, TAAPI.io, Supabase, Telegram). Не предлагаш новинарски feed-ове, sentiment analysis или ML модели.

---

## КОНТЕКСТ НА СИСТЕМАТА

### Какво прави системата
Автоматизирана крипто сигнална система която на всеки 2 часа (08:00–22:00) сканира 20 криптовалутни двойки и генерира 3-5 LONG/SHORT trading сигнала за Telegram канал. Потребителите търгуват с **leverage 3x–5x, максимум 10x** на Binance Perpetual Futures.

### Данни които се събират (Row 1 — Binance API)
- **Top 20 USDT двойки** по 24h quote volume от Binance Spot
- **Candles за 4 интервала**: 2h (40 свещи), 1h (72 свещи), 15m (1 свещ), 1m (1 свещ)
- **1m цена** = latest_1m_price (използва се като текуща цена за entry/SL/TP)
- **Median volume** изчислен от 1h свещите (за volume ratio baseline)
- **72h history validation** преди символът да влезе в pipeline

### Данни от TAAPI.io (Row 2)
За всеки символ на **2h и 1h** таймфрейм:
- RSI(14), MACD(12,26,9) — value/signal/histogram, ADX(14), EMA(20/50/200)
- StochRSI(14) — FastK/FastD, Williams %R(14), ATR(14), BBW(20), VWAP, OBV, MFI(14)

За **15m** таймфрейм: RSI(14), Williams %R(14)

Допълнително изчислено в Row 2: SMA(20) от raw candle close prices

### Scoring система (Row 3)
**5 компонента** с adaptive тегла базирани на ADX:

| Компонент | STRONG_TREND (ADX>25) | NEUTRAL | RANGING (ADX<15) |
|-----------|----------------------|---------|------------------|
| Trend     | 40%                  | 25%     | 10%              |
| Momentum  | 21%                  | 25%     | 30%              |
| Volatility| 17%                  | 20%     | 25%              |
| Volume    | 15%                  | 20%     | 20%              |
| Price Action | 7%               | 10%     | 15%              |

**Tier класификация** по rank (volume):
- Tier 1: Top 1-5 (BTC, ETH и подобни) — ATR thresholds: low 3%, high 6%
- Tier 2: Top 6-15 — ATR thresholds: low 6%, high 10%
- Tier 3: Top 16-20 — ATR thresholds: low 10%, high 15%

**Coherence check**: |momentum_score - trend_score| > 20 → penalty -15

**Signal classification**: VERY_WEAK / WEAK / MEDIUM / STRONG / VERY_STRONG

### Trade levels (Row 4)
- **SL**: ATR × multiplier (Tier1: 1.5×, Tier2: 2.0×, Tier3: 2.5×)
- **TP1/2/3**: динамично по trend_score (STRONG_TREND / MODERATE / WEAK_RANGING стратегии)
- **R/R floor** (tier-диференциран): Tier1 ≥ 1.5, Tier2 ≥ 2.0, Tier3 ≥ 2.5
- **Fee**: 0.055% maker/taker на Binance Futures (коректно разделено за LONG/SHORT)
- **Leverage**: floor(targetRisk% / slDist%), min 1x, max по tier
- **Entry zone**: direction-aware — LONG: [price - atrRange, price], SHORT: [price, price + atrRange]
- **Dynamic score floor**: матрица tier × ADX категория (55–70 точки)

### DB Schema (Supabase PostgreSQL)
**4 таблици:**
```
crypto_symbols        — символи с lifecycle (first_seen_at, last_seen_at,
                        consecutive_absences, is_active)
                        UNIQUE(symbol)

raw_candles_data      — исторически свещи
                        UNIQUE(symbol, interval, open_time)

scan_results          — scoring резултати per цикъл
                        UNIQUE(symbol_id, scan_cycle_id)

asset_tiers           — tier класификация и ATR анализ per цикъл
```

**Важно за DB:**
- Всички INSERT операции са UPSERT с `on_conflict` — pipeline е idempotent
- `raw_candles_data` расте исторически (cleanup политика не е дефинирана)
- `signal_strength` е VARCHAR — съдържа текст (VERY_STRONG и т.н.), не число
- `open_time` е canonical key за свещи, НЕ `timestamp` (timestamp = кога n8n е записал)

---

## КАКВО Е ВЕЧЕ ОПРАВЕНО (НЕ ПРЕДЛАГАЙ ПОВТОРНО)

Следните 14 fix-а са имплементирани и в кода:

1. **responsePointer → Map<symbol|interval>** — symbol/candle matching с completeness check
2. **signal_strength DB CAST** — SQL функцията използва VARCHAR директно
3. **R/R floor tier-диференциран** — 1.5/2.0/2.5 + Node 9 numeric self-check
4. **72h дублиран node** — превърнат в pass-through
5. **Node именуване** — Top 20 синхронизирано
6. **SHORT fee корекция** — effEntry локална променлива, правилни знаци за SHORT
7. **Telegram error guard** — NO_SIGNALS нотификация вместо error обект
8. **entry_calculated guard** — 5-ти филтър в Node 9
9. **MACD relative threshold** — tier-aware: T1:0.01%, T2:0.05%, T3:0.10%
10. **Volume hard disqualification** — ratio < 0.3 → early exit преди MERGE
11. **Cross-row defensive fallback** — NODE_* константи + UPSTREAM_DATA_MISSING errors
12. **Direction-aware entry zone** — LONG: [price-atr, price], SHORT: [price, price+atr]
13. **Leverage minimum guard** — Math.max(1, floor(...)) + leverage_at_minimum flag
14. **ADX default conservative** — missing ADX → 'weak' floor вместо 'moderate'

**Предстои имплементация (знаем за тях, не е нужно да ги откриваш):**
- Daily EMA 50 trend filter (hard gate за LONG/SHORT по daily тренд)
- Funding Rate integration (Binance /fapi/v1/premiumIndex → penalty/bonus в scoring)

---

## ИНСТРУКЦИИ ЗА ОДИТА

### Процес — задължително Row по Row
Чети и анализирай файловете в този ред:
1. Node sequence документа (разбери пълния pipeline ред)
2. Row 1 nodes (data collection)
3. Row 2 nodes (TAAPI + SMA + DB insert)
4. Row 3 nodes (tier, ATR, scoring)
5. Row 4 nodes (TP/SL, R/R, entry zone, filters, ranking)
6. DB schema файловете

**За всеки Row**: прочети ВСЕКИ файл изцяло. Не прескачай. Не обобщавай преди да си прочел.

### Какво търсиш

**Архитектурни проблеми:**
- Silent failures — грешки без error signal
- Data flow несъответствия — output на Node A ≠ expected input на Node B
- Race conditions или timing issues в N8N execution
- Fire-and-forget операции без retry
- Hardcoded стойности на повече от едно място (sync риск)
- Edge cases при граничните стойности на scoring матриците
- DB операции без proper error handling

**Трейдинг логика проблеми:**
- Scoring компоненти които се държат различно при bull/bear/ranging
- Индикатори чиито прагове не са tier-aware (когато трябва да са)
- Сигнали с математически некоректно очакване при 3x–5x leverage
- Entry/SL/TP логика която генерира неизпълними нива
- Филтри които режат твърде много или твърде малко при конкретни пазарни условия
- Липсващи индикатори или некоректно тегло на съществуващи
- Проблеми специфични за Perpetual Futures (funding, liquidation proximity)

**Пазарни режими — оценявай поведението при всеки:**
- **Bull run** (ADX>25, RSI>60 системно): генерира ли твърде много LONG? Пропуска ли SHORT?
- **Bear market** (EMA bearish, MACD отрицателен): генерира ли SHORT при bounce корекции?
- **Ranging** (ADX<15, BBW<0.03): режи ли всички сигнали или пропуска noise?

### Формат на изхода

**Структура:**

```
# CRYPTO SIGNAL SYSTEM — AUDIT REPORT
## Версия на кода: [дата от файловете]

## 1. АРХИТЕКТУРНИ ПРОБЛЕМИ
[A-XX] Наименование
Проблем: ...
Риск: ...
Fix: ...
QA: ...

## 2. ТРЕЙДИНГ ЛОГИКА ПРОБЛЕМИ  
[T-XX] Наименование
Проблем: ...
Влияние: ...
Fix: ...
QA: ...

## 3. ПРИОРИТИЗИРАН СПИСЪК
| Приоритет | ID | Наименование (идентично с т.1/т.2) | Риск | Effort |
```

**Правила за формата:**
- Чист Markdown, без таблици с излишни колони, без emoji, без bold навсякъде
- Максимум **13 страници A4** общо
- Приоритизираният списък използва **идентични наименования** от секции 1 и 2
- P0 = счупва pipeline или генерира грешен сигнал директно
- P1 = влияе на качеството на сигналите системно
- P2 = техническа неточност или maintenance риск
- Effort: Low (< 30 мин) / Med (30–90 мин) / High (> 90 мин)
- Само реални проблеми намерени в кода — не теоретични
- Fix-овете трябва да са системни (решават root cause) — не patch-ове
- ЗАБРАНЕНО ТИ Е ДА ХАБИШ ИЗЛИШНИ ТОКЕНИ ЗА НЕСВОЙСТВЕНИ ДЕЙНОСТИ!!!!!!!! ТОВА Е ФУНДАМЕНТАЛНО ВАЖНО! САМО ПРАКТИЧЕСКИ ПОЛЕЗНИ РЕАЛНИ СЪВЕТИ С ВИСОКА ДОБАВЕНА СТОЙНОСТ БЕЗ ПЪЛНЕЖИ! 

**Не включвай:**
- Въведения и обяснения на системата (вече я знаеш)
- Проблеми от "ВЕЧЕ ОПРАВЕНО" списъка
- Daily EMA 50 и Funding Rate (знаем за тях)
- Препоръки за external integrations (новини, sentiment, ML)
- Похвали, оценки, summary параграфи

---

## НАЧАЛО

Започни с прочитане на node sequence документа, после Row 1. След всеки Row направи кратка бележка (1-2 изречения) какво си намерил преди да продължиш към следващия. Финалният output е след като си прочел ВСИЧКО.
