# CRYPTO SIGNAL SYSTEM — AUDIT REPORT

**Версия на кода:** commit `3492fcf` (FULL AUDIT) — 16 May 2026
**Обхват:** Row1 → Row4 (40 node-а) + Merge SQL + workflow_node_sequence.md
**Метод:** пълно прочитане на всеки node, проверка спрямо ALREADY FIXED списъка, без дублиране.

---

## 1. АРХИТЕКТУРНИ ПРОБЛЕМИ

### [A-01] Restore Full Data — silent fall-through при липсваща пълна сесия
**Проблем:** В `Restore Full Data After Tier Insert` (ред 145–148), ако `fullDataSource.find(...)` не върне match, се връща `tierItem` без TAAPI/price полета. Всички 5 scoring branch-а получават обект само с tier-метаданни → `momentum_score=0`, `trend_score=0`, `volatility_score=0`, `volume_score=0`, `price_action_score=0`.
**Риск:** Символ продължава като легитимен сигнал със сума 0; coherence penalty (-15) автоматично се прилага; в най-лошия сценарий дава фалшив `VERY_WEAK` запис с грешни weights → разваля относителната Tier3 граница (avg−15) при Top 5.
**Fix:** Изключи символа изцяло (`return null`) и filter преди `return restoredData`. Логирай list на "lost symbols".
**QA:** Симулирай липсващ symbol в `ATR Volatility Analyzer2`; провери че pipeline не пропуска полузаписан signal.

### [A-02] WEIGHTS_MISSING fail-fast е едностранен
**Проблем:** `SCORE AGGREGATOR` правилно отхвърля сигнал при `market_condition='WEIGHTS_MISSING'` (input1), но **не проверява** дали input2/input3/input4/input5 са изпуснати. При срив само на Trend branch например, `trend_score=null→0` → `weighted_trend=0` → totalScore без най-тежкия компонент (40%), съответно директно завишен volume/volatility принос.
**Риск:** Тих провал на ключов компонент → силно изкривени scores, които минават Hard Filters защото dynamic floor е tier+ADX-based, не component-completeness-based.
**Fix:** В `SCORE AGGREGATOR` добави проверка че всеки от 5-те raw score-а е числов и >= 0; null/NaN → exclude. Алтернативно — въведи sentinel в Merge SQL за всеки score (`COALESCE(... , -1)`).
**QA:** Принудително върни `[]` от MOMENTUM SCORE CALCULATOR за един cycle; провери че signals не се произвеждат с фантомен `momentum_score=0`.

### [A-03] Restore-node препраща `volatility_score` единствено през Branch 3
**Проблем:** Решението [T-08] е документирано в коментар (`Restore Full Data` ред 182–185), но Merge SQL все още чете `input3.volatility_score`. Branch 3 е `Volatility Score Calculator1`, който в момента **е input3** (Volume/Price Action е input5 според node_sequence). Mapping-ът е коректен, но нарушава спецификацията „Branch 3 = sole authoritative producer". Ако някой смени реда на Merge inputs, без да актуализира SQL, ще получи мълчалива замяна с ATR Analyzer-метаданните.
**Риск:** Нискa, но fragility — една невалидна корекция в Merge node ще препрати грешен volatility_score.
**Fix:** В коментар на Merge SQL изрично запиши: "input3 == Volatility Score Calculator1 ИЗКЛЮЧИТЕЛНО"; добави assertion в SCORE AGGREGATOR (`if (data.volatility_score === undefined) reject`).
**QA:** Тест: премести inputs и провери че pipeline отказва без silent fallback.

### [A-04] Cooldown зависи от ръчна N8N конфигурация
**Проблем:** `Cooldown after Batch 6` е чист passthrough; реалният Wait е външен IF/Wait node, документиран само в коментар. Няма runtime guard, че Wait е сложен.
**Риск:** При повторен deploy/restore от backup, кооldown лесно изчезва → TAAPI 429 от batch 7+ → tихо отпадат символи.
**Fix:** Включи health-check: в `TAAPI RESPONSE PROCESSOR` следи `429` отговори в последните N батчове и логни ALERT при > 0; пращай Telegram warning.
**QA:** Симулирай липса на Wait node, провери че получаваш alert.

### [A-05] Двоен код за извличане на median_volume и 1m цени
**Проблем:** `EXTRACT 1M PRICES AND MERGE` (Row 1) и `Restore Full Data After Tier Insert` (Row 3) изпълняват една и съща логика върху `BINANCE CANDLE PROCESSOR`. Source of truth е разкъсан → ако някой смени Map key, двете места ще се разсинхронизират.
**Риск:** Технически дълг; не функционален bug, но повишава вероятност за бъдещи регресии.
**Fix:** Премахни логиката от Row 1 (вече се извлича в Row 3 от cross-row `$('BINANCE CANDLE PROCESSOR')`); или обратно — разчитай само на pass-through и убий дублирания extract в Row 3.
**QA:** Сравни `latest_1m_price` от двата източника per cycle — трябва да са идентични.

### [A-06] DEBUG + DE-DUPLICATION връща един `candles_array` обект
**Проблем:** Изходът е `[{ json: { candles_array, total_count } }]` — единичен item. Следващите HTTP nodes към Supabase POST вероятно се чакат да обработят един row на item; ако schema очаква множество items → DB upsert-ва един JSON блоб с array.
**Риск:** Зависи от DB schema; ако `raw_candles_data` приема JSON array колона — OK; ако очаква flat rows — partial insert.
**Fix:** Потвърди schema; ако flat — върни map(item => ({json:item})) вместо обвиване в array.
**QA:** Провери `SELECT count(*) FROM raw_candles_data WHERE scan_cycle_id = current` спрямо очакваното (~20 × 4 интервала × 12+ candles).

---

## 2. ПРОБЛЕМИ В WORKFLOW-а

### [W-01] HARD FILTERS ENFORCER — `ReferenceError: rrFilterPassed is not defined`
**Проблем:** Ред 242: `rr_filter_passed: rrFilterPassed,` — променливата НЕ е дефинирана никъде в node-а. Изпълнява се в rejected-branch при всеки сигнал, който не премине поне един филтър.
**Риск:** **CRITICAL.** При първия отхвърлен символ в cycle, node-ът crash-ва → workflow exception → сигнали не достигат Telegram. Към момента pipeline работи единствено когато ВСИЧКИ кандидати минават всички филтри (рядък сценарий).
**Fix:** Замени с `data.rr_filter_passed === true` или премахни полето изцяло.
**QA:** Принудително направи cycle с поне един под-floor сигнал → провери че rejected branch не throw-ва.

### [W-02] Volume двойно наказание (volume_score weighting + volume_penalty subtract)
**Проблем:** Volume score (0–100) вече участва weighted в total_score (15–20%). След това `VOLUME PENALTY APPLICATOR` изважда отделно `volume_penalty` (диапазон −5…−100) от total_score директно. Нисък volume → нисък volume_score → нисък weighted_volume → допълнителен penalty. Двойно отчитане на същия фактор.
**Риск:** Прекомерно потискане на иначе валидни сигнали при ratio 0.5–0.79 → late-entry/breakout сетъпи се filter-ват несправедливо.
**Fix:** Избери една стратегия: или премахни weighted_volume от total_score когато volume_penalty < 0, или изтрий penalty-механизма и разчитай само на volume_score weighting + hard volume_ratio filter (>=0.5).
**QA:** Backtest 10 cycle-а; сравни брой сигнали passed с/без double penalty за ratio 0.5–0.79.

### [W-03] Volume soft-disqualification (-100 за ratio 0.3–0.5) е dead code
**Проблем:** Hard Filters Enforcer филтрира `volume_ratio >= 0.5` → всеки сигнал с ratio 0.3–0.5 умира на по-късен етап от друг филтър. Soft −100 penalty в Volume Score Calculator не променя резултата, но харчи compute и обърква audit trail.
**Риск:** Минимален; подвеждащо логване ("DISQUALIFIED" в Volume node, но истинският kill е в Hard Filters).
**Fix:** Премахни soft −100 zone (0.3–0.5); приведи Volume Score Calculator да dropp-ва същото като hard branch (<0.3).
**QA:** Провери че логиката за `original_signal_strength` в Volume Penalty Applicator не е счупена след промяната.

### [W-04] Coherence penalty (Score Aggregator) реагира на липсващи компоненти
**Проблем:** `scoreDifference = |momentum_score − trend_score|`. Когато trend_score = 0 поради липсващи MACD+EMA данни, а momentum_score е валиден 50, difference = 50 → автоматично −15 penalty без реален конфликт.
**Риск:** Изкривяване на total_score при immature символи (нови listings, отрязани от ранните 72h, но проникнали).
**Fix:** Прилагай coherence penalty САМО когато И двата score-а са > 0; иначе skip.
**QA:** Test fixture с trend_score=0, momentum_score=50 → очаквай penalty=0.

### [W-05] TP/SL използва close_price при 1m deviation > 3%, но Entry Zone използва 1m винаги
**Проблем:** [T-06] guard в TP-SL Calculator коректно substitute-ва `close_price` при 1m deviation > 3%. Обаче `TECHNICAL LEVEL IDENTIFIER` (ред 35) използва `latest_1m_price` БЕЗ deviation check. Резултат: entry zone center = 1m price, SL/TP = около close_price → entry_min/max могат да са извън SL/TP диапазона → Entry Zone Validator може да маркира TP/SL clearance като нелогично.
**Риск:** Инконсистентен trade plan по време на news-driven price spike-ове; губят се иначе валидни сетъпи или се пускат невалидни.
**Fix:** Изнеси deviation guard в споделена функция/utility и приложи в Technical Level Identifier и Entry Zone Validator. И двата трябва да използват една и съща `currentPrice`.
**QA:** Симулирай 1m спайк >3% → провери че entry_min/max са консистентни с stop_loss/take_profit.

### [W-06] Signal direction е MACD/EMA-only — Momentum няма право на vote
**Проблем:** `trend_direction` (= signal_direction в целия pipeline) се определя единствено в TREND SCORE CALCULATOR от MACD-2h хистограма + EMA20/50 alignment. RSI/StochRSI/Williams %R не участват в директионалното решение, само в quality multiplier (T-02 post-hoc penalty).
**Риск:** Свръхзависимост от един индикатор — при MACD whipsaw в ранно reversal, signal_direction променя посока всеки cycle, но Momentum (RSI/StochRSI) показва стабилна посока. Това генерира тих pipeline noise: late entries в края на trend (RSI overbought + MACD still bullish → LONG).
**Fix:** Минимална промяна без ML: добави voting логика в Score Aggregator — ако MACD direction != RSI bias (rsi_2h>55 vs <45), намали total_score с допълнителни 5–10 pts вместо да блокираш сигнала.
**QA:** Маркирай (за audit) сигнали с MACD/RSI conflict; следи win-rate в реалния feed.

### [W-07] SIGNAL RANKING — несъществуващо поле `entry_zone` в логване
**Проблем:** Ред 287: `Entry: ${data.entry_zone}` — това поле никога не е сетвано. Реалните полета са `entry_min`/`entry_max`. Лог показва `undefined`, но не е runtime error.
**Риск:** Минимален; cosmetic + audit confusion.
**Fix:** Замени с `${data.entry_min.toFixed(8)} – ${data.entry_max.toFixed(8)}`.

### [W-08] Tier diversification — Tier3 dynamic threshold (avg−15) става неуловим
**Проблем:** Когато първият selected е Tier1 със score 88, Tier3 threshold = 73. При Hard Filters floor за Tier3=50–65, Tier3 кандидати фактически НИКОГА не достигат селекция, освен в `ALL_TIER3_EXCEPTION`. Това убива диверсификацията към altcoins почти изцяло когато BTC/ETH е силен.
**Риск:** Систематична концентрация в Tier1/Tier2, дори когато expected value за Tier3 setup е по-висока.
**Fix:** Замени `avg − 15` с по-нисък tier-aware delta: `avg × 0.85` или absolute floor `max(50, avg−25)`.
**QA:** Replay 30 cycle-а; преброй колко Tier3 сигнала са били скипнати само заради тoзи threshold.

---

## 3. ТРЕЙДИНГ ЛОГИКА ПРОБЛЕМИ

### [T-01] Momentum scoring е reversal-blind при overbought/oversold
**Проблем:** `MOMENTUM SCORE CALCULATOR` дава 40 pts когато `avg_rsi >= 60` (за bullish) — но RSI 70+ исторически е exhaustion zone в crypto. Системата интерпретира dangerous late-entry zone като силна bullish momentum. StochRSI extreme >= 80 също дава 15 pts (вместо 0 или негативен сигнал). Williams %R `>= -20` дава само 10 (правилно), но RSI overrules.
**Влияние:** Произвежда LONG сигнали в края на impulse → лош fill, бърз stop hunt в leverage.
**Fix:** Преобърни scoring: за RSI 60–70 = 40 pts; 70–80 = 25 pts; > 80 = 10 pts (mirror за SHORT). За StochRSI > 85 в extreme → 5 pts. Това хармонизира с Williams %R логиката, която вече налага намаление в overbought.
**QA:** Сравни raw momentum_score преди/след промяна за топ 20 BTC cycle-а; провери че overbought сетъпи получават по-нисък рейтинг.

### [T-02] Adaptive weights за Tier1 MACD threshold (0.005% / 0.01%) — практически винаги "STRONG"
**Проблем:** В TREND SCORE CALCULATOR, Tier1 (BTC/ETH) праг за strong MACD momentum е 0.01% от цената. На BTC с цена 60k, това е $6 хистограма — почти всеки cycle постига това. Tier2/Tier3 праговете са разумни (0.05% / 0.10%).
**Влияние:** Tier1 trend_score систематично завишен; relative ranking against Tier2/3 изкривен → BTC/ETH винаги доминират Top 5 дори при weak setup.
**Fix:** Калибрирай Tier1 prag → 0.05% strong, 0.025% moderate (в съответствие с Tier2 baseline за по-стабилни активи).
**QA:** Проследи разпределението на trend_components.macd_contribution за Tier1 vs Tier2/3 за 50 cycle-а.

### [T-03] Coherence bonus +5 е прекалено лесен
**Проблем:** Score Aggregator дава +5 bonus когато momentum >= 50 И trend >= 50 И diff <=15. Прагът 50 е много нисък — половината символи в нормални пазари го минават. Bonus постоянно е активен → нивото на total_score постоянно завишено с 5 → калибровката на signal_strength прагове (50/65/75/85) не е приложена към "чист" score.
**Влияние:** Inflates STRONG/VERY_STRONG counts; намалява false-negative rate за сметка на false-positive rate.
**Fix:** Вдигни праг на coherence bonus: и двата score-а >= 65 И diff <= 10. Или премахни bonus изцяло и разчитай само на penalty при divergence.
**QA:** Преброй процента сигнали с активиран bonus в production cycles; цел < 30%.

### [T-04] BBW thresholds за Tier3 (squeeze=0.025, optimal=0.060) — твърде ниско за altcoin волатилност
**Проблем:** Tier3 (altcoins/shitcoins) обикновено имат BBW 0.05–0.20; current optimal range (0.025–0.060) поставя повечето altcoins в "elevated" или "extreme" зона → волатилност score = 15–30/40 → волатилност контрибуция намалява точно за активите където волатилност = възможност.
**Влияние:** Adaptive Weights за RANGING режим дават 25% волатилност тегло — а Tier3 рядко достига optimal range → systematic suppression на legitimate breakout сетъпи.
**Fix:** Tier3 BBW: squeeze=0.04, optimal=0.10, elevated=0.18; или динамично калибриране на база historical median BBW за символа (използвай 12 candles от 1h, които вече се извличат).
**QA:** За 20 Tier3 символа изчисли median BBW от raw_candles_data и сравни с current thresholds.

### [T-05] Volume Score дава 70 pts ("EXCELLENT") при cs_volume >= 1B, но cap е 50
**Проблем:** В `VOLUME SCORE CALCULATOR` ред 36–50 кодът присвоява до 70 points, докато maxScore += 50. Резултатът се нормализира `(totalScore / maxScore) × 100` → дробта може да е 70/50 = 1.4 → finalScore = 140% преди други компоненти, но компонентите downstream нормализират пак → финален volume_score може да надвиши 100 преди clamp. Нямам clamp на final volume_score връщане; downstream weighting × volume_score (0–140) × 0.15–0.20 = до 28 pts от max 20.
**Влияние:** Volume компонент може да даде > планираните 15–20% от total_score за висок-волуме активи → прекомерно тежи в полза на BTC/ETH.
**Fix:** Промени scoring към 50 max: EXCELLENT=50, GOOD=42, MODERATE=35, LOW=20, VERY_LOW=8 (или промени maxScore += 70).
**QA:** Логни volume_score distribution; провери че никой не надвишава 100.

### [T-06] OBV thresholds са абсолютни, не нормализирани спрямо cs_volume
**Проблем:** `obv_1h > 1000000` дава +30 pts универсално. За BTC OBV regularly e в милиарди → винаги +30. За ниско-волуме altcoin (cs_volume = 100M), OBV рядко достига 1M → почти винаги +5. Това превръща OBV в proxy за volume, не за buying/selling pressure direction.
**Влияние:** OBV компонент губи аналитичната си стойност; нашето T-03 OBV direction correction в Score Aggregator работи на грешна сигнална база.
**Fix:** Нормализирай: `obv_normalized = obv_1h / candle_volume`; thresholds 0.5/0.1/−0.1/−0.5 (приблизително positive/negative pressure ratio).
**QA:** Сравни старите vs новите OBV-derived точки за 20 символа.

### [T-07] R/R bonus до +10 заобикаля coherence/volume penalty math
**Проблем:** `RISK-REWARD FILTER` дава +2/+5/+10 bonus, добавени в `RISK-REWARD SCORE OUTPUT` към risk_reward_score (0–100), но **НЕ КЪДЕ** към total_score, използван от Hard Filters/Ranking. Bonus реално не влияе на ranking.
**Влияние:** R/R quality не се проявява в финалния select; high-R/R signal с marginal score = 65 ще остане под 70-floor дори при +10 bonus, защото bonus е изолиран в страничен score.
**Fix:** Или внеси `+rr_bonus` в total_score преди Hard Filters; или премахни bonus като подвеждащ artifact.
**QA:** Логни случаи където bonus е +10 но сигналът не е селектиран — те са candidates за фалшиво отказани setups.

### [T-08] Leverage formula `targetRisk% / slDist%` пренебрегва liquidation buffer
**Проблем:** При Tier3 targetRisk=1%, slDist=2.5% → leverage = 0.4 → floor = 1x. При Tier1 targetRisk=2%, slDist=1.5% → leverage=1.33 → floor = 1x. Системата постоянно връща 1–3x за повечето сценарии, но Tier max е 5/7/10x. Edge: при много тесен SL (slDist=0.3% за Tier1), leverage=6.67 → floor=6, capped at 10. Без buffer срещу exchange liquidation = entry+SL+fees+funding.
**Влияние:** В реални условия 6x leverage с SL на 0.3% разстояние е под 1.8% от capital загуба, но Binance liquidation buffer + funding може да премести real liquidation на 0.4%–0.5% → SL не работи, ликвидация преди stop.
**Fix:** Гарантирай минимум 2× ATR distance OR минимален slDist абсолютен (Tier1: 0.5%, Tier2: 0.8%, Tier3: 1.2%) преди да изчислиш leverage. Това е safety guard, не нов индикатор.
**QA:** Провери разпределение на slDistancePct за Tier1 сигнали — колко % са под 0.5%.

### [T-09] LONG/SHORT directional imbalance в bull регим
**Проблем:** В STRONG_TREND market_condition, MACD-2h определя посоката. В bull cycle 80%+ от Top 20 ще са bullish trending → 80% от сигнали са LONG. Hard Filters няма balance constraint.
**Влияние:** Свръхконцентрация в една посока; цялото portfolio се движи синхронизирано → корелиран risk при reversal.
**Fix:** Добави в SIGNAL RANKING: ако > 4 от 5 сигнали са в една посока, замени най-слабия с най-силния от обратната посока (ако total_score > absolute floor 60). Без нови индикатори.
**QA:** Backtest 30-дневен bull/bear/sideways прозорец; проследи portfolio drawdown при concentrated signals.

### [T-10] ATR Volatility Analyzer "EXTREME" праг = 1.5× threshold_high — твърде тесен за crypto
**Проблем:** Tier3 high=15, EXTREME при 22.5% ATR/price. ATR на altcoin spike-ове редовно достига 25–40%. Система маркира като "EXTREME" и vol_score=25 → намалява вероятност за избор. Но 25–40% ATR е КЛАСИЧЕСКИ breakout setup, не avoid-zone.
**Влияние:** Изпускат се най-печелившите altcoin breakout-и.
**Fix:** Tier3 EXTREME → 2× threshold_high (30%); over 40% → emergency exclude. Tier1/Tier2 запази текущи стойности.
**QA:** Анализирай 90-дневна history на ATR% за Top 20 — намери P95/P99 distribution per tier.

---

## 4. ОЦЕНКА НА СИСТЕМАТА

### 4.1 Архитектурна стабилност — 6/10
Pipeline-ът е добре сегментиран по rows и cross-row референциите са защитени с named-node lookups и sentinel-и. Слабост: дублиране на 1m price/median extraction между Row1 и Row3 (A-05) и липса на единен fail-fast за всички 5 scoring branch-а (A-02). Cooldown логиката зависи от документация в коментар, не от runtime invariant (A-04). Restore-node може да върне полу-валиден обект (A-01). Архитектурно базата е стабилна, но runtime-resilience е под нивото на трейдинг система с реално капитално излагане.

### 4.2 Качество на сигналите — 5/10
Multi-component scoring е концептуално солиден (5 компонента + adaptive weights + coherence + corrections), но има няколко калибрационни недостатъка: momentum reversal-blindness (T-01), Tier1 MACD prag практически винаги strong (T-02), volume scoring overflow до 140 (T-05), OBV не е нормализиран (T-06). Coherence bonus +5 се активира прекалено лесно и инфлира signal_strength разпределенията (T-03). Не съм убеден, че средният expected value на сигнал е статистически положителен след fees + slippage без re-калибровка.

### 4.3 Безопасност при 3x–5x leverage — 6/10
Tier-aware SL multipliers (1.5/2.0/2.5 ATR) и tier-capped leverage (10/7/5x) са разумни. Fee-adjusted R/R floor (1.5/2.0/2.5) предпазва от математически губещи трейдове. Главен дефицит: формулата за leverage не отчита exchange liquidation buffer + funding (T-08), което при тесни SL за Tier1 може да доведе до ликвидация преди stop. Минималният leverage guard (= 1x) е добър safety net, но няма горна защита срещу calculated 1x при ATR>SL_target ratio дисбаланс.

### 4.4 Workflow надеждност — 4/10
**Critical bug:** `rrFilterPassed is not defined` в HARD FILTERS ENFORCER (W-01) — node crash-ва при първи отхвърлен сигнал. В production това означава, че pipeline produces signals САМО когато всички кандидати минават всички филтри — много рядко. Освен този bug, останалите са меки (W-02 double penalty, W-03 dead code, W-05 entry/TP-SL price inconsistency). Логване и audit trail са добри, но runtime exception handling в страничните пътища е слабо.

### 4.5 Устойчивост на data integrity проблеми — 7/10
GROUP CANDLE RESPONSES правилно валидира interval gaps и обема candles per symbol; A-04 фикса за median volumes (1h/2h) е смислен; cycle_id propagation е осигурен с няколко fallback-а. Седиментарната уязвимост: Restore Full Data (A-01) tolerира липсващ pull → silent partial signal. DEBUG + DE-DUPLICATION packs всичко в един array item (A-06) — зависи от downstream schema. Като цяло DB integrity е добре защитена с UPSERT + scan_cycle_id partition.

### 4.6 Потенциал за надграждане и оптимизация — 7/10
Архитектурата позволява безболезнени калибрационни промени (BBW thresholds, MACD percentage thresholds, momentum scoring tables, leverage safety buffer) без да чупи node interfaces. Adaptive Weights и Tier system са правилните абстракции за бъдещи Daily EMA50 / Funding Rate slot-ове, които вече са в roadmap. Главни ограничения: липса на per-symbol calibration (всички Tier3 използват identical thresholds), липса на feedback loop от изпълнените сигнали обратно към scoring weights.

---

## 5. ТОП 5 ФУНДАМЕНТАЛНИ ОПТИМИЗАЦИИ

### [O-01] Поправка на runtime crash-овете и data flow inconsistencies (W-01, A-01, A-02, W-05)
**Защо:** Това е блокер за изобщо да можеш да измериш стойността на каквато и да е друга оптимизация. `rrFilterPassed` undefined (W-01) crash-ва pipeline при първия rejected сигнал. Restore Full Data (A-01) пуска полузаписани сигнали в pipeline. WEIGHTS_MISSING fail-fast (A-02) проверява само input1.
**Кои зони:** Workflow integrity → Signal output reliability.
**Очакван impact:** Преходът от спорадично работещ pipeline към 100% cycle delivery rate; премахва фантомни сигнали с total_score=0; ефективно удвоява броя cycles, които достигат Telegram.
**Tradeoffs:** Минимални; чисти bug-fixes без change на трейдинг логика. Може да разкрие "no signal" cycles, които преди тихо са били crash-нати.

### [O-02] Re-калибровка на Momentum scoring за overbought/oversold reversal awareness (T-01)
**Защо:** Текущата логика третира RSI 70+ като силна bullish momentum (40 pts), което противоречи на основополагащия принцип, че късните моментум сигнали в overbought зони имат най-нисък expected value под leverage. T-02 multiplier в Score Aggregator частично компенсира, но само за SHORT signals — LONG в overbought преминава без correction.
**Кои зони:** Signal Quality → Late-entry suppression → Loss avoidance.
**Очакван impact:** Намаляване на late-entry losing trades в продължителни trends с 20–30%; по-добро timing на LONG entries в pullback вместо breakout exhaustion. Win-rate повишение оценъчно 3–5 pp при същия сигнален обем.
**Tradeoffs:** Намалява общия брой сигнали в продължителни bull periods (ще премине от 5 на 2–3 сигнала per cycle понякога). Изисква две стъпки калибровка — RSI и StochRSI scoring tables. Може първоначално да изключи легитимни strong-trend continuation entries — компенсира се от MACD/EMA confirmation.

### [O-03] Volume penalty unification — премахване на double counting (W-02, W-03, T-05)
**Защо:** Volume в момента влиза в total_score през три различни механизма: weighted (15–20%), penalty subtract (-5 до -100), и hard ratio filter (>=0.5). Soft penalty zone (0.3–0.5) е dead code. Volume_score може да премине 100 cap. Резултатът е непредсказуем суперпозитивен или свръхнегативен volume contribution в зависимост от ratio bucket.
**Кои зони:** Scoring math purity → Reproducibility → Calibration tractability.
**Очакван impact:** Предсказуемо поведение на volume контрибуцията; премахване на скрити non-linearities, които правят threshold tuning невъзможно. Около 10–15% от сигнали ще променят пасажа си през filter chain (някои ще преминават, които преди не — и обратно), но статистически разпределенията ще са центрирани, а не bi-modal.
**Tradeoffs:** Изисква backtest за нова калибровка на dynamic score floors в Hard Filters Enforcer след премахване на double penalty. Може временно да намали или увеличи pass rate с 10–20%.

### [O-04] Tier-aware BBW и ATR EXTREME граници за crypto-realistic волатилност (T-04, T-10)
**Защо:** BBW thresholds за Tier3 (squeeze=0.025, optimal=0.06) и ATR EXTREME prag = 1.5× threshold_high са калибрирани за традиционни пазари, не за crypto altcoin реалност. Резултат: системата активно избягва най-печелившите breakout setups в Tier3 (където най-високият expected value на trade седи) и ги класифицира като "EXTREME volatility avoid".
**Кои зони:** Signal Quality (Tier3) → Market regime adaptation → Profitability tail.
**Очакван impact:** Възстановяване на Tier3 breakout сигналите, които в момента са systematically suppressed. Очаквам 2–3× повече Tier3 сигнали per седмица, с асиметрично положителен PnL profile (single trade може да даде 3–5R при правилен breakout).
**Tradeoffs:** По-голяма волатилност на portfolio drawdown — Tier3 breakouts често имат 30–40% intraday swings. Tier diversification филтър (W-08) трябва да се промени едновременно, иначе тези нови Tier3 кандидати ще бъдат блокирани от threshold.

### [O-05] Leverage liquidation safety buffer + minimum SL distance per tier (T-08)
**Защо:** Текущата формула `targetRisk% / slDist%` е математически коректна по отношение на capital risk, но не отчита Binance liquidation buffer (~0.5% за USDT-margined perpetuals при 5–10x), funding payments, slippage. Tier1 setup със slDist=0.4% и leverage=5x означава реална liquidation на ~0.5–0.6%, която ще се удари ПРЕДИ stop loss → загуба на цялата margin вместо planned 2%.
**Кои зони:** Leverage survivability → Catastrophic loss prevention.
**Очакван impact:** Премахване на "stop hunted" катастрофни загуби, които в момента са скрити в системата, защото нямаш ekzekution feedback. Дори една предотвратена ликвидация на cycle спестява 10–15% от portfolio.
**Tradeoffs:** Минимум-SL guard ще намали leverage за Tier1 в tight markets — означава по-малко "perfect" R/R setups, но реално достижими, без disaster risk. Психологически по-консервативен output, който ще намали брой VERY_STRONG сигнали в Tier1.

---

## 6. ПРИОРИТИЗИРАН СПИСЪК

| Приоритет | ID | Наименование | Риск | Effort | РЕШЕН |
|---|---|---|---|---|---|
| P0 | W-01 | rrFilterPassed undefined → workflow crash | Critical | Low | ДА |
| P0 | A-01 | Restore Full Data — silent partial signal | High | Low | ДА |
| P0 | T-08 | Leverage без liquidation buffer | High | Med | ДА |
| P0 | W-05 | Entry vs TP/SL price source inconsistency | High | Low | ДА |
| P1 | A-02 | WEIGHTS_MISSING едностранен fail-fast | High | Low | ДА |
| P1 | T-01 | Momentum reversal-blindness | High | Med | ДА |
| P1 | W-02 | Volume double penalty | Med | Med | ДА |
| P1 | T-04 | BBW thresholds Tier3 неадекватни | Med | Low | ДА |
| P1 | T-10 | ATR EXTREME prag твърде тесен | Med | Low | — |
| P1 | T-02 | Tier1 MACD threshold винаги strong | Med | Low | ДА |
| P1 | T-05 | Volume score overflow > 100 | Med | Low | ДА |
| P1 | W-08 | Tier3 dynamic threshold убива диверсификация | Med | Low | ДА |
| P1 | T-09 | LONG/SHORT imbalance в bull регим | Med | Med | — |
| P2 | T-06 | OBV non-normalized | Med | Low | — |
| P2 | T-03 | Coherence bonus prag твърде нисък | Low | Low | — |
| P2 | T-07 | R/R bonus не влиза в ranking score | Low | Low | — |
| P2 | A-04 | Cooldown зависи от ръчна N8N конфигурация | Med | Low | — |
| P2 | W-04 | Coherence penalty при липсващи компоненти | Low | Low | — |
| P2 | A-05 | Дублиран 1m/median extract | Low | Low | — |
| P2 | A-06 | DEBUG node single-item array packaging | Low | Low | — |
| P2 | A-03 | Volatility_score routing fragility | Low | Low | — |
| P2 | W-03 | Volume soft-disqualification dead code | Low | Low | ДА* |
| P2 | W-07 | entry_zone undefined в SIGNAL RANKING лог | Low | Low | — |
| P2 | W-06 | Signal direction MACD-only voting | Med | Med | — |

*W-03 е автоматично решен от W-02 fix-а: soft-disqualification path-ът беше премахнат заедно с double penalty логиката.

### Решени issues по итерации

**Итерация 1 (commit `9b452ab`):** W-01 (HARD FILTERS ENFORCER), A-01 (Restore Full Data After Tier Insert), T-08 (TP-SL CALCULATOR), W-05 (TECHNICAL LEVEL IDENTIFIER), A-02 (SCORE AGGREGATOR).

**Итерация 2 (commit current):** T-01 (MOMENTUM SCORE CALCULATOR — regime-aware), T-02 (TREND SCORE CALCULATOR — Tier1 MACD), T-04 (Volatility Score Calculator1 — BBW rebalance), T-05 + W-02 (VOLUME SCORE CALCULATOR + VOLUME PENALTY APPLICATOR — re-scale + ratio multiplier + passthrough), W-08 (SIGNAL RANKING & TOP 5 SELECTION — diversification threshold).

**Финална препоръка:** Започни от P0 (един следобед работа), след това P1 пакета T-01/T-02/T-04/T-05/T-10 (калибровки в scoring tables, едновременно). Backtest 30-дневна замразена history между всеки етап. Не пускай нови оптимизации преди да валидираш предишните в реални 5–7 cycles.
