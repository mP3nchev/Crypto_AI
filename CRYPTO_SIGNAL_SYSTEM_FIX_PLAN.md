# CRYPTO SIGNAL SYSTEM — FIX PLAN
## Всички оставащи проблеми за отстраняване
## Дата: 2026-05-11 | База: commit e5c4c51 (main)

---

## ПРИОРИТЕТНА ТАБЛИЦА

| ID    | Проблем                                              | Приоритет | Файл                              |
|-------|------------------------------------------------------|-----------|-----------------------------------|
| A-07  | Wait node не е добавен в N8N editor                  | P1        | N8N workflow (не е код)           |
| A-09  | ASSET TIER CALCULATOR: грешни tier граници           | P1        | row3/ASSET TIER CALCULATOR        |
| R-05  | GROUP CANDLE RESPONSES: positional symbol matching   | P1        | row1/GROUP CANDLE RESPONSES       |
| F-01  | Funding rate не е в скоринга (Perpetual Futures)     | P1        | row1 (нов node) + row4/TP-SL CALCULATOR |
| D-01  | macd_histogram_1h е null → SHORT bias в trend score  | P1        | row3/TREND SCORE CALCULATOR + row3/Merge |
| P-01  | Липсва minimum SL distance guard                     | P2        | row4/TP-SL CALCULATOR             |
| T-03  | OBV корекция засяга целия volume weight              | P2        | row3/SCORE AGGREGATOR             |
| T-08  | Misleading logs след T-08 fix                        | P2        | row3/ATR Volatility Analyzer2 + row3/Restore Full Data After Tier Insert |
| R-02  | HARD FILTERS ENFORCER: rrFilterPassed мъртъв код     | P2        | row4/HARD FILTERS ENFORCER        |
| R-04  | Дублирани R/R thresholds в два node-а               | P2        | row4/RISK-REWARD FILTER + row4/HARD FILTERS ENFORCER |

---

## A-07 — Wait Node не е добавен в N8N Workflow Editor

**Засегнат файл:** `row2/Cooldown after Batch 6` (SHA 057052b9) — но самият fix е само в N8N UI, не в код

**Проблем:**
Кодът в `Cooldown after Batch 6` е чист passthrough — извежда log за batch index, но не прилага никакво забавяне. Оригиналният `setTimeout` е бил премахнат правилно (N8N Cloud Code nodes имат ~10s execution timeout, `setTimeout(30000)` никога не изтича преди kill). Корректното решение (IF node + native Wait node в N8N workflow) е документирано в code коментара, но не е имплементирано в N8N workflow editor. Без тази пауза всички TAAPI batches вървят back-to-back без никакво throttling. TAAPI bulk API допуска 1 заявка на ~15-30 секунди в зависимост от плана — при 20 символа и 2 символа на batch се генерират 10+ batches на цикъл. 429 от batch 7+ не abort-ва pipeline-а — TAAPI RESPONSE PROCESSOR получава error response и пропага null/0 за всички индикатори на засегнатите символи. Символи с null RSI, MACD, ADX преминават `safeFloat(null) = 0` и произвеждат изкуствено ниски scores, но не се блокират от нито един текущ guard. Последствие: до 50% от символите в цикъл могат да получат невалидни технически индикатори без никакво предупреждение в Telegram.

**Решения:**

*Вариант A (Препоръчан):* В N8N workflow editor добави структурата описана в коментара на code node-а:
- IF node с условие: `{{ $('Loop Over Items1').context.currentRunIndex === 6 }}`  
  → True: Wait node (Duration: 30 seconds) → HTTP POST TAAPI BULK  
  → False: директно към HTTP POST TAAPI BULK  
- Втори IF node след Wait (или преди него) за index === 12 (Wait 20s)  
- Тествай с N8N execution log — очаква се 30-секундна пауза след 6-ия batch (видима като gap между timestamps)

*Вариант B:* Един IF node с OR условие (`index === 6 || index === 12`), routing към два различни Wait nodes (30s и 20s) чрез N8N expression `{{ $('Loop Over Items1').context.currentRunIndex === 6 ? 30 : 20 }}`.

Гранични случаи: ако TAAPI планът се смени и rate limit-ът се промени, само Wait node duration-а трябва да се редактира. Ако total batches < 6 (< 12 символа), нито един Wait node не се задейства — без проблем. Ако N8N добави native rate-limiting в бъдеще, Wait nodes могат да бъдат премахнати без code промени.

**Предпочитано решение:** Вариант A с два отделни IF nodes — визуалното разделение в N8N editor прави логиката очевидна. Едно условие за два различни Wait durations (Вариант B) е по-компактно, но по-трудно за debugване при изпълнение.

---

## A-09 — ASSET TIER CALCULATOR: Tier Граници Несъответстват на Execution Plan v2

**Засегнат файл:** `row3/ASSET TIER CALCULATOR` (SHA 44036c67 — непроменен)

**Проблем:**
Текущият код дефинира Tier 1 = rank 1–10, Tier 2 = rank 11–40, Tier 3 = rank 41–150. Execution Plan v2 специфицира Tier 1 = rank 1–5, Tier 2 = rank 6–15, Tier 3 = rank 16–20. При работа с 20 активни символа: текущата логика произвежда T1=10 символа, T2=10 символа, T3=0 символа — Tier 3 никога не се присвоява. Rank 16–20 символи (по-малки altcoins с по-висока волатилност) получават T2 параметри: SL = 2.0×ATR вместо 2.5×ATR (по-тесен stop), targetRiskPct = 1.5% вместо 1.0% (по-голяма позиция), TIER_MIN_RR = 2.0 вместо 2.5 (по-лесно минава R/R филтъра), max leverage = 7x вместо 5x. Rank 6–10 символи получават T1 параметри: SL = 1.5×ATR вместо 2.0×ATR (прекалено тесен), max leverage = 10x вместо 7x. ATR thresholds в TIER_CONFIG (atr_low/atr_high) също са проектирани за старите tier ширини и не пасват на реалната волатилност на съответните rank зони. Засяга директно риск профила на всяко генерирано signal и е основна причина за недооценена волатилност при по-малките активи.

**Решения:**

*Вариант A (минимален):* Промени само `assignTier` функцията и `rank_range` в `TIER_CONFIG`:
```javascript
const TIER_CONFIG = {
  1: { name: 'Tier 1', rank_range: [1, 5],   atr_low: 2,  atr_high: 4  },
  2: { name: 'Tier 2', rank_range: [6, 15],  atr_low: 4,  atr_high: 8  },
  3: { name: 'Tier 3', rank_range: [16, 20], atr_low: 8,  atr_high: 15 }
};

function assignTier(rankPosition) {
  const rank = parseInt(rankPosition) || 999;
  if (rank >= 1  && rank <= 5)  return 1;
  if (rank >= 6  && rank <= 15) return 2;
  return 3;
}
```

*Вариант B (clean code):* Дефинирай `TIER_BOUNDARIES` като именован constant, деривирай `assignTier` от него — единствен source of truth за бъдещи промени:
```javascript
const TIER_BOUNDARIES = { 1: [1, 5], 2: [6, 15], 3: [16, 20] };
function assignTier(rank) {
  for (const [tier, [min, max]] of Object.entries(TIER_BOUNDARIES)) {
    if (rank >= min && rank <= max) return parseInt(tier);
  }
  return 3;
}
```

Гранични случаи: `rank > 20` при дефектен upstream → `return 3` е правилен safe default. `rank = 0` или null → `parseInt(rankPosition) || 999` → Tier 3 (консервативен). ATR thresholds трябва да се актуализират заедно с tier промяната — BTC/ETH/BNB/XRP/SOL (T1) имат ATR% 0.3–1%, тъй че atr_low=2 / atr_high=4 са разумни. T2 (rank 6–15, LINK/DOT/UNI): 1–3%, thresholds 4/8. T3 (rank 16–20): 3–8%, thresholds 8/15.

**Предпочитано решение:** Вариант B — именованият `TIER_BOUNDARIES` constant елиминира риска от рассинхронизиране на comment и логика при бъдещи промени. Единственото място за редакция при промяна на tier политиката е самият constant.

---

## R-05 — GROUP CANDLE RESPONSES: Positional Symbol Matching при HTTP Retry

**Засегнат файл:** `row1/GROUP CANDLE RESPONSES` (SHA 4aa3c65c)

**Проблем:**
При `splitOn = true` (Split Into Items включено), свещите за символ `i` се събират чрез `resp.slice(i * limit, (i + 1) * limit)`. Съответствието символ → свещи е изцяло позиционно — index в response array-а трябва да съвпада точно с index в filter metadata-та. Ако Binance rate-limit-не HTTP заявката за символ `k` и N8N retry-не, допълнителният response item измества всички символи `k+1, k+2, ...` — те получават свещите на `k, k+1, ...`. Кодът инкрементира `errors++` при candle count mismatch, но pipeline-ът **продължава** с корумпирани данни. Timestamp-gap валидацията проверява само интервала между първите две свещи на всеки batch — не открива cross-symbol contamination. При splitOff path (`resp[i]?.json`) съществува идентичното позиционно допускане. Корумпирани свещи се предават на TAAPI, Score Calculator-ите и евентуално на Telegram — грешните RSI/MACD/ATR стойности от чужди свещи генерират фиктивни технически сигнали без никаква индикация за проблем.

**Решения:**

*Вариант A:* При candle count mismatch за символ `k` в splitOn режим — маркирай символ `k` И всички `k+1, k+2, ...` в същия интервал като `data_status: 'CONTAMINATED'` с `exclude_from_taapi: true`. Само символи преди `k` (index < k) са гарантирано верни. Едно retry-то на един символ засяга целия tail на batch-а.

*Вариант B (препоръчан):* При `errors > 0` след обработка на всички символи за даден интервал, throw Error и спри целия цикъл вместо да продължиш с corruption. По-консервативно, но предотвратява silent propagation:
```javascript
if (errors > 0) {
  throw new Error(`[R-05] ${errors} candle error(s) detected — aborting cycle to prevent corrupt signals.`);
}
```

*Вариант C (дългосрочен):* Премини от batch HTTP request към индивидуални HTTP заявки per символ в N8N loop (20 calls вместо 1). Всяка заявка е URL-bound към конкретен символ, без positional mapping. Елиминира проблема напълно, но увеличава HTTP overhead 20×.

Гранични случаи: splitOff path трябва да получи идентичен guard. Ако всичките 20 символа са error-free, поведението е без промяна. Вариант B-абортирането засяга целия 2h цикъл — без Telegram output за тог цикъл, но предотвратява фалшиви сигнали, което е по-важно.

**Предпочитано решение:** Вариант B — сигнал генериран от грешни свещи (чужд RSI/ATR) е по-опасен от пропуснат цикъл. Abort при errors > 0 е минимална промяна от 3 реда, гарантираща невъзможност за silent data corruption.

---

## F-01 — Funding Rate не е включен в скоринга (Perpetual Futures)

**Засегнати файлове:** Нов fetch node (Row 1/2) + `row4/TP-SL CALCULATOR` (SHA edecc059) + евентуално `row3/SCORE AGGREGATOR`

**Проблем:**
Системата генерира сигнали за Binance Perpetual Futures, при които funding rate се начислява на всеки 8 часа (позитивен = longs плащат shorts, негативен = shorts плащат longs). Нито един node в текущия pipeline не fetch-ва или използва funding rate данни. TP-SL CALCULATOR отчита maker/taker fees (0.055% + 0.055% = 0.11% total), но не и funding разходите. При средна funding rate ~0.01% на период ефектът е малък, но при силни trends funding може да достигне 0.1–0.3% на 8h (0.3% × 3 периода/ден = 0.9%/ден само от funding). За Tier 1 сигнал с TIER_MIN_RR=1.5 и SL distance 0.5%, TP1 е 0.75% — единичен 0.3% funding event намалява ефективната reward с 40%, правейки R/R < breakeven. Освен разход, висока позитивна funding rate е contrarian сигнал: пазарът е over-leveraged long, вероятността за long squeeze расте — информация, директно приложима за SHORT signal quality. В момента сигнали при 0.01% и 0.3% funding са третирани идентично при скоринга, sizing-а и R/R изчисленията.

**Решения:**

*Вариант A (минимален — само филтър):* Добави Binance Futures API call (`GET /fapi/v1/premiumIndex`) след symbol selection (Row 1). В HARD FILTERS ENFORCER добави нов filter check:
```javascript
funding_rate: {
  passed: !(direction === 'LONG'  && fundingRate > 0.0005) &&
          !(direction === 'SHORT' && fundingRate < -0.0005),
  reason: `Funding rate ${fundingRate} unfavorable for ${direction}`
}
```
Без промени в R/R математиката.

*Вариант B (препоръчан — R/R интеграция):* Fetch funding rate данните и ги предай на TP-SL CALCULATOR. В `riskWithFees` изчислението добави очаквания funding разход:
```javascript
// Assume average 1 funding period per 2h signal holding window
const fundingCostPct = Math.abs(fundingRate) * Math.sign(fundingRateDirection);
// fundingCostPct added to risk side (LONG: fundingRate > 0 → cost)
const effectiveRisk = riskWithFees + (currentPrice * fundingCostPct / 100);
const rrTP1 = rewardTP1 / effectiveRisk;
```
Funding данните се включват и в SCORE AGGREGATOR като contrarian multiplier (+5 pts за SHORT при funding > 0.05%, -5 pts за LONG при funding > 0.05%).

*Вариант C (само scoring):* Funding rate като score modifier само в SCORE AGGREGATOR без R/R промяна. По-лесно за имплементация, но R/R показваният в Telegram остава неточен.

Гранични случаи: Binance Futures API изисква endpoint `/fapi/` (не `/api/` за spot). При API failure → default 0 (neutral), не блокира pipeline. Funding rate може временно да достигне >1% при liquidation cascades — добави cap: `Math.min(Math.abs(fundingRate), 0.005)`. Не всички spot символи имат Perpetual Futures contract — системата вече таргетира USDT perps, но верификацията е задължителна.

**Предпочитано решение:** Вариант B — funding rate е first-class риск фактор за perpetual futures, директно влияещ на profitability. Включването му в R/R изчислението дава честен R/R ratio, а contrarian scoring-ът добавя информационна стойност без значителна сложност. Вариант A е подходящ като бърз patch, но не решава проблема с Telegram reporting-а на R/R.

---

## D-01 — macd_histogram_1h е null → Систематичен SHORT Bias в Trend Score

**Засегнати файлове:** `row3/TREND SCORE CALCULATOR` (SHA 7e1916d2), `row3/Merge` (SHA 35a6e913)

**Проблем:**
TREND SCORE CALCULATOR v4.0 (T-04 fix) добавя multi-timeframe alignment check: ако 2h и 1h MACD histogram-ите са в едно направление → +15 points (alignment), иначе → +5 points (divergence). `safeFloat(scanData.macd_histogram_1h)` връща 0 при null/undefined с default. Проверка на Merge SQL (SHA 35a6e913) потвърди: `macd_histogram_1h` не е включен в SELECT — полето не съществува в нито един от 5-те inputs. Следователно `macd_histogram_1h` е **винаги null** → `safeFloat` → 0 → `macd_bullish_1h = (0 > 0) = false`. Асиметричен ефект: при LONG сигнал (`macd_histogram_2h > 0`) `macd_bullish_2h=true ≠ macd_bullish_1h=false` → divergence → +5 вместо +15. При SHORT сигнал (`macd_histogram_2h < 0`) `macd_bullish_2h=false === macd_bullish_1h=false` → alignment → +15. NET резултат: LONG сигналите губят 10 MACD alignment точки спрямо SHORT сигналите само поради липсващи данни, не поради реална пазарна дивергенция. При maxScore=100 (всички 3 компонента присъстват) тези 10 точки директно влияят на `trend_score` и следователно на `signal_direction` определянето и `total_score` в SCORE AGGREGATOR. Проблемът е въведен с T-04 fix — alignment бонус е добавен, но без гаранция че данните са налични.

**Решения:**

*Вариант A (patch без данни):* Промени `safeFloat(scanData.macd_histogram_1h)` на `safeFloat(scanData.macd_histogram_1h, null)` и добави guard преди alignment check:
```javascript
const macd_histogram_1h_raw = scanData.macd_histogram_1h;
const has1hMacd = macd_histogram_1h_raw !== null && macd_histogram_1h_raw !== undefined;
// Alignment check само ако 1h данните са налични
if (has1hMacd) {
  const macd_bullish_1h = safeFloat(macd_histogram_1h_raw) > 0;
  if (macd_bullish_2h === macd_bullish_1h) { macdContribution += 15; }
  else { macdContribution += 5; }
} else {
  macdContribution += 10; // neutral при липса на 1h данни
}
```

*Вариант B (Remove check):* Премахни alignment check изцяло — MACD компонентът дава само histogram strength (15 pts max вместо 30 pts max). Преизчисли `maxScore` accordingly. Елиминира bias напълно без нови данни.

*Вариант C (препоръчан — добави данните):* Добави `macd_histogram_1h` в Merge SQL от input-а, който го предоставя (вероятно input4 от TREND SCORE CALCULATOR chain, или директно от TAAPI response). Провери дали TAAPI bulk request за 1h timeframe включва MACD — ако не, добави го. Тогава полето ще бъде реално populated и alignment check-ът ще работи коректно.

Гранични случаи: ако TAAPI планът не включва 1h MACD в bulk request, Вариант C изисква и TAAPI конфигурационна промяна. При Вариант A — `macdContribution += 10` neutral при липса е по-справедлив от +5 или +15, но е произволна стойност без market logic. Вариант B намалява `maxScore` когато MACD е present (30→15) — нормализацията остава коректна, но MACD contribution е намален наполовина.

**Предпочитано решение:** Вариант C ако TAAPI bulk request може да бъде разширен с 1h MACD (проверка задължителна преди имплементация); в противен случай Вариант A с neutral default при null. Вариант B е acceptable като временно решение — отстранява bias безусловно, въпреки намалената MACD чувствителност.

---

## P-01 — Lipsa Minimum SL Distance Guard в TP-SL CALCULATOR

**Засегнат файл:** `row4/TP-SL CALCULATOR` (SHA edecc059)

**Проблем:**
Stop Loss се изчислява като `currentPrice ± (atr × SL_MULTIPLIERS[tier])`. Единственият guard е `atr <= 0` → skip. При много малка, но положителна ATR стойност (TAAPI partial data, weekend ниска ликвидност, нов листинг с малко история) — `slDistancePct` може да бъде под 0.2–0.3%. Такъв SL се задейства от нормален bid-ask spread noise на Binance Perpetual Futures за всеки актив. Пример: Tier 3 актив, ATR=0.0002 при price=$0.05, slMultiplier=2.5 → `slDistancePct = 1.0%` (добре). Но при ATR=0.00005 (corrupted data) → `slDistancePct = 0.25%` — под spread noise за mid/small-cap perps. Стойността `slDistancePct` се предава на RISK-REWARD FILTER за leverage изчисление (`targetRiskPct / slDistancePct`) — много малка `slDistancePct` дава `calculatedLeverage = Infinity`, cap-нат от tier max, но SL-ът е неизползваем. TP нивата се изчисляват спрямо `risk = abs(stopLoss - currentPrice)` — при near-zero risk, TP1/TP2/TP3 са практически на entry price-а. HARD FILTERS ENFORCER и Entry Zone Validator нямат check за `slDistancePct` минимум. Резултат: сигнал с аномален SL може да премине всички филтри и да достигне Telegram.

**Решения:**

*Вариант A (adjust SL до минимум):* Добави minimum floor веднага след SL изчислението:
```javascript
const MIN_SL_DISTANCE_PCT = { 1: 0.20, 2: 0.40, 3: 0.70 };
const minSlPct = MIN_SL_DISTANCE_PCT[tier] || 0.40;
if (slDistancePct < minSlPct) {
  console.warn(`[P-01] slDistancePct ${slDistancePct.toFixed(3)}% < ${minSlPct}% minimum for Tier ${tier} — enforcing minimum`);
  const minSlDistance = (currentPrice * minSlPct) / 100;
  stopLoss = direction === 'LONG' ? currentPrice - minSlDistance : currentPrice + minSlDistance;
  // Recalculate slDistance, slDistancePct, risk и всички TP нива
}
```

*Вариант B (препоръчан — skip символа):* При `slDistancePct < minSlPct` третирай като невалидни данни и skip:
```javascript
if (slDistancePct < minSlPct) {
  console.warn(`[P-01] slDistancePct ${slDistancePct.toFixed(3)}% < ${minSlPct}% minimum — symbol skipped`);
  results.push({ json: { ...data, tpsl_calculated: false, rejection_reason: `SL_TOO_TIGHT: ${slDistancePct.toFixed(3)}% < ${minSlPct}%` } });
  continue;
}
```

*Вариант C:* Добави guard в HARD FILTERS ENFORCER като нов `filter check`:
```javascript
sl_distance: {
  passed: slDistancePct >= (MIN_SL_DISTANCE_PCT[tier] || 0.40),
  reason: `SL distance ${slDistancePct.toFixed(3)}% too tight`
}
```

Гранични случаи: минимумите трябва да отразяват реалния spread noise per tier — BTC/ETH (T1): spread ~0.05–0.1% → min 0.20%; large alts (T2): spread 0.1–0.3% → min 0.40%; small alts (T3): spread 0.3–0.8% → min 0.70%. Ако ATR-ът е правилен (просто нисковолатилен период), Вариант A изкуствено разшири stop-а и намаля R/R — сигналът може да падне под TIER_MIN_RR и да бъде отхвърлен на следващата стъпка. Вариант B изобщо не публикува сигнала при корумпирани данни.

**Предпочитано решение:** Вариант B — изкуственото разширяване на SL (Вариант A) промълчаливо променя risk профила на сигнала. По-добре да се пропусне символа при аномална ATR, отколкото да се публикува сигнал с неавтентичен stop. Вариант B е 3 реда допълнение — минимална промяна, максимална защита.

---

## T-03 — SCORE AGGREGATOR: OBV Корекция Засяга Целия Volume Weight

**Засегнат файл:** `row3/SCORE AGGREGATOR` (SHA 8307f6ca)

**Проблем:**
`getVolumeCorrectionMultiplier` връща 0.75/0.85/1.0 базиран на OBV level и direction и се прилага върху цялото `weightedVolume = volumeScore × weights.volume × volumeCorrMult`. `volumeScore` (0–100) комбинира OBV (max ~30 pts), MFI (max ~30 pts) и volume tier (max ~40 pts). Корекцията е проектирана да penalize-ира само OBV под-компонента (bullish OBV при SHORT сигнал), но редуцира и MFI и volume tier — две direction-neutral метрики. MFI (Money Flow Index) измерва дали паричният поток е inflow/outflow без направленческо bias спрямо OBV. Силен MFI при SHORT може да потвърди downside pressure — неправилно е да бъде наказван. При multiplier 0.75, volumeScore=100 и weight_volume=0.20: пълното `weightedVolume` пада от 20 на 15, но само ~6 от тези точки са OBV-derived — 9 точки от MFI и volume tier се намаляват без основание. Максималният overshoot е ~4–5 точки на total score. Документиран като "Option A architectural tradeoff" в кода. Не е бъг в смисъл на неправилно изпълнение, но е неточна корекция с measurable directional impact.

**Решения:**

*Вариант A (настоящо състояние):* Приемане на ~5pt overshoot като известен трейдоф. Рискът е документиран в код коментара. Максималният ефект е ~5 точки на total_score — приемливо ниво на неточност при настоящата scoring архитектура.

*Вариант B (препоръчан — прецизна корекция):* Премести OBV direction корекцията в `VOLUME SCORE CALCULATOR` (Branch 5), където OBV sub-score се изчислява отделно от MFI и volume tier. Приложи multiplier само там:
```javascript
// В VOLUME SCORE CALCULATOR:
const obvRawScore = calculateOBVScore(obv_1h);  // 0-30
const obvCorrMult = getOBVDirectionMultiplier(direction, obv_1h);
const obvAdjustedScore = obvRawScore * obvCorrMult;
const volumeScore = obvAdjustedScore + mfiScore + volumeTierScore;
return volumeScore; // Already direction-adjusted
```
В SCORE AGGREGATOR премахни `volumeCorrMult` напълно — `volumeScore` ще дойде вече коригиран.

*Вариант C:* Изчисли OBV proportion в SCORE AGGREGATOR: `obvProportion = obvRawScore / volumeScore`, приложи само `obvProportion` от penalty. Изисква VOLUME SCORE CALCULATOR да изнася `obv_raw_score` отделно.

Гранични случаи: Вариант B изисква промяна в VOLUME SCORE CALCULATOR (Branch 5) — node-ът трябва да изнася OBV sub-score поотделно или направлението-коригирания total. При volumeScore = 0 (no volume data) корекцията е без ефект — безопасно. При obv_1h = 0 multiplier = 1.0 — без penalty — коректно.

**Предпочитано решение:** Вариант B — fix-ва проблема при source-а в VOLUME SCORE CALCULATOR. Принципът "корекцията се прилага при изчислението, не след агрегацията" прави scoring-а по-прозрачен и предотвратява натрупване на подобни "approximation layers" в SCORE AGGREGATOR.

---

## T-08 — ATR Volatility Analyzer2 + Restore Full Data: Misleading Logs

**Засегнати файлове:** `row3/ATR Volatility Analyzer2` (SHA 05f4aba4), `row3/Restore Full Data After Tier Insert` (SHA 08b93dc7)

**Проблем:**
В `ATR Volatility Analyzer2`: summary блокът изчислява `avgVolScore = processedResults.reduce((sum, r) => sum + (r.json.volatility_score || 0), 0) / length` и логва `📊 Average Volatility Score: ${avgVolScore.toFixed(1)}/100`. Тъй като T-08 fix премахна `volatility_score` от output-а на този node (авторитетният producer е `Volatility Score Calculator1`), `r.json.volatility_score` е винаги `undefined` → `|| 0` → sum=0 → avgVolScore=0 → логва "Average Volatility Score: 0.0/100" при всяко изпълнение. В `Restore Full Data After Tier Insert`: debug секцията включва `console.log(\`  - volatility_score: ${sampleRecord.volatility_score}\`)`. Тъй като `volatility_score` не се propagate-ва от `tierData` (T-08 fix коментарът в кода го документира), `sampleRecord.volatility_score` е винаги `undefined` → логва "volatility_score: undefined". Двата лога нямат функционален ефект — scoring, filtering и signal generation са напълно коректни. Проблемът е debug качеството: "0.0/100" Average Volatility Score кара разработчика да провери дали scoring branch-ът е broken, а "undefined" в Restore Full Data имитира data restoration failure без да има такава.

**Решения:**

*Fix 1 — ATR Volatility Analyzer2:* Изтрий `avgVolScore` изчислението и неговия `console.log`. Замени с нещо смислено, например:
```javascript
const extremeCount = processedResults.filter(r => r.json.volatility_status === 'EXTREME').length;
console.log(`📊 Extreme volatility symbols: ${extremeCount}/${processedResults.length}`);
```
`volatility_status` е валидно поле в output-а на този node.

*Fix 2 — Restore Full Data After Tier Insert:* Изтрий реда `console.log(\`  - volatility_score: ${sampleRecord.volatility_score}\`)` от sample record inspection блока. `volatility_score` умишлено не е в тези данни.

Гранични случаи: При бъдещ рефакторинг, ако `volatility_score` бъде върнат в ATR Volatility Analyzer2 output, `|| 0` default щеше да маскира null стойности — по-добре е да се изтрие и да се добави правилно отново при нужда.

**Предпочитано решение:** Директна делеция на двата реда — лаконична промяна без risk. Авторитетният volatility_score log е в `Volatility Score Calculator1` (Branch 3). Orphaned debug lines с `undefined` / `0.0` стойности дeградират debugging confidence при production incidents.

---

## R-02 — HARD FILTERS ENFORCER: rrFilterPassed Мъртъв Код

**Засегнат файл:** `row4/HARD FILTERS ENFORCER` (SHA 48227461)

**Проблем:**
Редът `const rrFilterPassed = data.rr_filter_passed === true;` извлича upstream флага, идващ от RISK-REWARD FILTER. Флагът се използва единствено в `console.log(\`     R/R Filter Passed: ${rrFilterPassed ? 'Yes' : 'No'}\`)`. Действителният R/R gate в `filterChecks.risk_reward.passed` е: `data.tpsl_calculated === true && feeAdjustedRR >= ({ 1: 1.5, 2: 2.0, 3: 2.5 }[tier] ?? 1.5)`. `rrFilterPassed` не участва в нито едно `if`, нито в `filterChecks`, нито в `allFiltersPassed` определянето. Бъдещ разработчик, виждащ "R/R Filter Passed: Yes" в логовете, може да приеме, че upstream `rr_filter_passed=true` е необходимо условие за преминаване — неправилно. Може да приеме, че манипулирането на `rr_filter_passed` upstream ще bypass-не check-а тук — също неправилно. Подвеждащо при debug: "R/R Filter Passed: Yes" може да се появи едновременно с failнал `risk_reward` filter check, ако `feeAdjustedRR` е NaN/0 — две противоречиви сигнализации в един лог.

**Решения:**

*Вариант A (препоръчан):* Изтрий `const rrFilterPassed = data.rr_filter_passed === true;` и `console.log(... rrFilterPassed ...)`. R/R check-ът в `filterChecks` вече логва threshold и result директно.

*Вариант B:* Добави `rrFilterPassed` реално в `risk_reward.passed` като допълнителна guard:
```javascript
passed: rrFilterPassed && data.tpsl_calculated === true && feeAdjustedRR >= tierMin
```
Превръща dead code в active code. Изисква RISK-REWARD FILTER да е надежден. Добавя double-gate но усложнява rejection diagnostics.

*Вариант C:* Замени log-а с коментар обясняващ защо node-ът re-evaluate-ва R/R независимо:
```javascript
// R/R is re-evaluated independently here because rr_filter_passed
// could be stale (e.g. if RISK-REWARD FILTER node was bypassed or modified).
```

Гранични случаи: при Вариант B — ако RISK-REWARD FILTER е bypass-нат в N8N и `rr_filter_passed` не присъства в data, `data.rr_filter_passed === true` е `false` → всички сигнали се reject-ват. Вариант A е по-resilient срещу такъв upstream failure.

**Предпочитано решение:** Вариант A — clean deletion. HARD FILTERS ENFORCER коректно recalculate-ва R/R от raw стойности, upstream флагът е genuinely redundant. Dead code с мisleading семантика е maintenance liability.

---

## R-04 — Дублирани R/R Thresholds в Два Node-а

**Засегнати файлове:** `row4/RISK-REWARD FILTER` (SHA 5077e707), `row4/HARD FILTERS ENFORCER` (SHA 48227461)

**Проблем:**
`TIER_MIN_RR = { 1: 1.5, 2: 2.0, 3: 2.5 }` е дефинирано като именован constant в RISK-REWARD FILTER. Идентичните стойности са hardcoded inline в HARD FILTERS ENFORCER на две места: в `filterChecks.risk_reward.passed` expression `({ 1: 1.5, 2: 2.0, 3: 2.5 }[tier] ?? 1.5)` и в `filterChecks.risk_reward.threshold`. N8N Code nodes са напълно независими — няма споделен module или config. Стойностите са идентични в момента, но при промяна в единия без другия ще се появят confusing rejection patterns: сигнал преминава RISK-REWARD FILTER (с новия threshold), но се reject-ва от HARD FILTERS ENFORCER (остарял threshold) или vice versa. При debug на rejection reason ще се вижда `risk_reward: fee_adjusted_rr 2.1 < 2.2 (Tier 2 floor)` след като RISK-REWARD FILTER е одобрил сигнала — трудно разбираемо несъответствие. Четири независими числа вместо едно са четири места за потенциална грешка при промяна на R/R политиката.

**Решения:**

*Вариант A (препоръчан):* Дефинирай именован constant в HARD FILTERS ENFORCER и добави sync warning:
```javascript
// ⚠️ SYNC REQUIRED: Must match TIER_MIN_RR in RISK-REWARD FILTER node.
// If you change these values here, update RISK-REWARD FILTER identically.
const TIER_MIN_RR = { 1: 1.5, 2: 2.0, 3: 2.5 };
```
Замени inline literals с `TIER_MIN_RR[tier] ?? 1.5` на двете места.

*Вариант B:* Премахни R/R check от HARD FILTERS ENFORCER изцяло. Разчитай само на RISK-REWARD FILTER. Опростява HARD FILTERS ENFORCER, но премахва safety redundancy.

*Вариант C:* Консолидирай двата nodes в един "FILTERS ENFORCER" node. Overengineering — не препоръчано.

Гранични случаи: ако Tier 4 бъде добавен в бъдеще, `?? 1.5` default fallback ще бъде приложен мълчаливо — добави explicit error при неизвестен tier. При Вариант B — ако RISK-REWARD FILTER е bypass-нат или реде-натан, HARD FILTERS ENFORCER е последна линия на защита; премахването й е риск.

**Предпочитано решение:** Вариант A — именованият constant + `// SYNC REQUIRED` коментар е минималната промяна с максималната видимост. Запазва defensive redundancy. Вариант B опростява кода на цената на single point of failure при R/R policy.

---

*Fix Plan генериран след fresh read на всички засегнати файлове. Базиран на commit e5c4c51 (main branch).*
*Дата: 2026-05-11*
