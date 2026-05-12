# CRYPTO SIGNAL SYSTEM — AUDIT REPORT
## Revision: PR #6 + PR #7 merged (2026-05-12)
## Audit Date: 2026-05-11 | Last Updated: 2026-05-12

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

## 3. PRIORITY SUMMARY

| Приоритет | ID | Проблем | Риск |
|----------|-----|---------|------|
| P1 | A-07 | Wait node трябва да се добави ръчно в N8N workflow editor | TAAPI rate-limit без защита |
| P2 | T-03 | OBV корекция засяга целия volume weight, не само OBV sub-компонент | ~4pt overshoot |
| P2 | T-08 | ATR Analyzer2 + Restore Full Data: misleading logs след T-08 fix | Подвеждащ дебъг |

---

## 4. OUTSTANDING ACTIONS (извън кода)

| Действие | Приоритет |
|--------|----------|
| Добави IF + Wait node в N8N workflow editor за TAAPI batch cooldown (A-07) | P1 |
| Ротирай TAAPI secret key — старият хардкоднат ключ е в git history и остава валиден | P0 |

---

*Последно актуализиран след PR #6 (R-02, R-04, R-05 fixed) и PR #7 (A-09 fixed) — 2026-05-12.*
*Покрива repo mp3nchev/crypto_ai.*
