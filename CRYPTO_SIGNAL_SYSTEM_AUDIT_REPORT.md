# CRYPTO SIGNAL SYSTEM — AUDIT REPORT
## Revision: commit e5c4c51 vs Execution Plan v2
## Audit Date: 2026-05-11

---

## 1. ARCHITECTURAL ISSUES

---

### [A-07] Cooldown after Batch 6 — Wait node pending manual N8N workflow edit
**File:** `row2/Cooldown after Batch 6`

**Problem:**
`setTimeout` е премахнат. Code node е passthrough. Cooldown-ът обаче не е възстановен — Wait node трябва да се добави ръчно в N8N workflow editor.

**Risk:** P1 — До добавяне на Wait node, всички TAAPI батчове вървят без пауза. 429 от batch 7+ ще причини partial индикаторни данни за цикъла.

**QA Note:** Добави IF node → Wait node (30s при index 6, 20s при index 12) в N8N editor. Провери execution timeline за 30-секундна пауза между batch 6 и 7.

---

### [A-09] ASSET TIER CALCULATOR — Tier boundaries не съответстват на Execution Plan
**File:** `row3/ASSET TIER CALCULATOR` — SHA 44036c67 (не е докоснат)

**Problem:**
Кодът дефинира Tier 1 = rank 1–10, Tier 2 = rank 11–40, Tier 3 = rank 41–150. Execution Plan v2 специфицира Tier 1 = rank 1–5, Tier 2 = rank 6–15, Tier 3 = rank 16–20. При 20 активни символа Tier 3 никога не се присвоява.

**Risk:** P1 — SL multiplier, leverage cap, targetRiskPct, R/R floor и BBW thresholds са greed-dependent от tier. Rank 16–20 altcoins получават Tier 2 параметри (SL 2.0×ATR, max 7x) вместо Tier 3 (SL 2.5×ATR, max 5x).

**QA Note:** Потвърди с product owner дали границите са plan-v2 (1-5/6-15/16-20) или текущата конфигурация е умишлена.

---

## 2. SIGNAL QUALITY ISSUES

---

### [T-03] SCORE AGGREGATOR — OBV корекция засяга целия volume weight
**File:** `row3/SCORE AGGREGATOR`

**Забележка към решението:**
`getVolumeCorrectionMultiplier()` е коректно имплементиран, но multiplier-ът се прилага върху целия `weightedVolume` (OBV + MFI + volume tier = 100 точки), не само върху OBV sub-компонента (30 точки). При SHORT с OBV > 1M, multiplier 0.75 редуцира и direction-neutral MFI и volume tier точките. Максималният overshoot е `volumeScore × weight_volume × 0.25 ≈ 4 точки` — приемлив като трейдоф от Option A, но не е прецизна корекция.

**Risk:** P2 — Не е бъг, а архитектурен компромис. Документиран за бъдещо прецизиране (Option B — корекция директно в VOLUME SCORE CALCULATOR).

---

### [T-08] ATR Volatility Analyzer2 — misleading summary log
**File:** `row3/ATR Volatility Analyzer2`

**Забележка към решението:**
`volatility_score` е коректно премахнат от output-а. Summary блокът обаче все още изчислява `avgVolScore = reduce((sum, r) => sum + (r.json.volatility_score || 0))` — ще логва `0.0/100` всеки цикъл. Функционално без ефект, но подвеждащо при дебъг.

Аналогично: Restore Full Data debug log `- volatility_score: ${sampleRecord.volatility_score}` ще показва `undefined`.

**Risk:** P2 — Само misleading logs. Нула функционален ефект.

---

## 3. REGRESSION FINDINGS

---

### [R-02] HARD FILTERS ENFORCER — rrFilterPassed dead variable
**File:** `row4/HARD FILTERS ENFORCER`

**Problem:**
`rrFilterPassed` се извлича от `data.rr_filter_passed` и се включва в `console.log`, но не участва в нито едно control-flow условие. Филтърът коректно използва `tpsl_calculated === true && safeRR >= tierMin`. Мъртъв код.

**Risk:** P2 — Maintenance риск. Бъдещ разработчик може да приеме, че флагът влияе на логиката.

---

### [R-04] RISK-REWARD FILTER + HARD FILTERS ENFORCER — Дублирани R/R thresholds
**Files:** `row4/RISK-REWARD FILTER`; `row4/HARD FILTERS ENFORCER`

**Problem:**
`TIER_MIN_RR = { 1: 1.5, 2: 2.0, 3: 2.5 }` е хардкоднато независимо в двата node-а. Стойностите са идентични — в момента няма mismatch. При промяна в единия без другия ще се появят confusing rejection patterns.

**Risk:** P2 — Maintenance риск. Всяка бъдеща промяна на R/R floors трябва да се приложи на две места.

---

### [R-05] GROUP CANDLE RESPONSES — Positional symbol matching при HTTP retry
**File:** `row1/GROUP CANDLE RESPONSES`

**Problem:**
A-03 Option A гарантира interval identity чрез 4 отделни HTTP node-а. Symbol identity обаче все още е позиционна — `resp.slice(i * limit, (i + 1) * limit)` маппва response items по array index. При Binance rate-limit на един символ и N8N retry, допълнителният item измества всички следващи символи. `errors++` се инкрементира но pipeline-ът продължава с корумпирани данни.

**Risk:** P1 — Silent data corruption при HTTP retry. Timestamp-gap и candle-count validation са частична защита, не пълна.

**QA Note:** Тествай с форсиран retry на един символ — провери дали съседните символи получават грешни свещи.

---

## 4. PRIORITY SUMMARY

| Приоритет | ID | Проблем | Риск |
|----------|-----|---------|------|
| P1 | A-07 | Wait node трябва да се добави ръчно в N8N workflow editor | TAAPI rate-limit без защита |
| P1 | A-09 | ASSET TIER CALCULATOR: tier границите несъответстват на Execution Plan | Грешни SL/RR за rank 16-20 |
| P1 | R-05 | GROUP CANDLE RESPONSES: positional symbol matching при HTTP retry | Silent data corruption |
| P2 | T-03 | OBV корекция засяга целия volume weight, не само OBV sub-компонент | ~4pt overshoot |
| P2 | T-08 | ATR Analyzer2 + Restore Full Data: misleading logs след T-08 fix | Подвеждащ дебъг |
| P2 | R-02 | HARD FILTERS ENFORCER: rrFilterPassed мъртъв код | Maintenance риск |
| P2 | R-04 | Дублирани R/R thresholds в два node-а | Sync риск при промяна |

---

## 5. OUTSTANDING ACTIONS (извън кода)

| Действие | Приоритет |
|--------|----------|
| Добави IF + Wait node в N8N workflow editor за TAAPI batch cooldown (A-07) | P1 |
| Потвърди tier границите с product owner и приложи A-09 fix | P1 |
| Ротирай TAAPI secret key — старият хардкоднат ключ е в git history и остава валиден | P0 |

---

*Покрива commit e5c4c51 (main branch). Файловете са прочетени директно от GitHub repo mp3nchev/crypto_ai.*
