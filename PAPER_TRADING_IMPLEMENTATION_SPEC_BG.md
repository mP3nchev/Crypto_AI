# Техническа и функционална спецификация: Paper Trading система

**Версия:** 1.0 · **Дата:** 21.11.2026 · **Основа:** `PAPER_TRADING_FEASIBILITY_AUDIT_2026-11-21.md`
**Адресат:** AI coding агент с достъп до `mp3nchev/crypto_ai`, клон `claude/system-audit-3gDsG`
**Език на изпълнение:** код и коментари на английски, документация на български, по конвенцията на repo-то

---

## 0. Резюме

Системата добавя към съществуващия сигнален pipeline автоматичен 30-дневен тест с виртуални пари. Всеки сигнал, избран за Telegram, отваря виртуална позиция в Supabase. Отделен малък N8N workflow на всеки час тегли затворени 1h свещи от Binance за символите с отворени позиции. SQL функция в Supabase оценява TP и SL по детерминирани правила и записва частичните и пълните изходи. Статичен уеб dashboard чете готовите агрегати от Supabase и показва дневна статистика, детайл на сделка, месечен календар и филтри.

**Архитектурни решения (окончателни):**
1. **Логиката живее в Supabase** (PL/pgSQL). N8N само пренася данни, а frontend-ът само показва. Нито едно финансово изчисление не се прави в N8N или в браузъра.
2. **Сигналната логика в Rows 1–4 не се променя.** Единственият променен node е `SIGNAL LOGGER`: добавят се полета.
3. **Позиция се отваря от DB trigger** върху `telegram_signals`. Грешка в paper логиката никога не блокира записа на сигнала или Telegram.
4. **Мониторингът е отделен workflow**, а не част от тежкия основен. Отделните сривове не се засягат взаимно.
5. **Изходът се оценява по High/Low на затворени свещи** с курсор за всяка позиция. Резултатът не зависи от честотата и времето на изпълнение.
6. **Dashboard-ът е нов, минимален SPA** (Vite + React + TypeScript + supabase-js), защото в repo-то няма frontend.

---

## 1. Задължителни правила за AI агента

1. Преди промяна на файл го прочети изцяло. Следвай съществуващите конвенции: файлове без разширение за N8N Code node-ове в `row*/`, SQL в `supabase/`, тагове за промени във формат `[P-xx]` в коментарите (аналогично на `[T-09]` и `[B-03]`).
2. Изпълнявай частите в реда от раздел 5. **Не започвай част, преди приемните критерии на предишната да са изпълнени.**
3. **Не променяй** нищо в `row1/` до `row4/` освен изрично посоченото. Особено: scoring, TP-SL CALCULATOR, RISK-REWARD FILTER и класирането.
4. Нямаш достъп до N8N и до crypto Supabase проекта. Твоят резултат са **файлове в repo-то плюс инструкции за внедряване стъпка по стъпка**. Потребителят ги прилага ръчно. Критерии, маркирани **(П)**, се проверяват от потребителя в живата система.
5. Всеки SQL файл е idempotent (`IF NOT EXISTS`, `CREATE OR REPLACE`) и може да се пусне повторно без вреда.
6. Тест, който пада, не се заобикаля и не се изтрива. Спри, опиши причината и предложи минималната корекция.
7. **Правило за спиране:** ако откриеш разминаване с тази спецификация (липсващо поле, различно име на node, различна схема), спри конкретната задача, опиши разминаването и предложи най-малката корекция. Не импровизирай.
8. Commit-ите са малки, по задачи, с префикс `feat(paper):`, `test(paper):` или `docs(paper):`.

---

## 2. Текуща архитектура и ограничения

### 2.1 Компоненти (проверени в кода)

| Компонент | Файл | Роля за paper trading |
|---|---|---|
| Избор на universe | `row1/Sort & Select Top 20` | `LIMIT = 5` е тестова стойност и трябва да е 20 |
| Свещи | `row1/Bulk Requests Generator Binance Candles` | 1h × 12 само за текущия топ N. Не е подходящо за мониторинг |
| Binance host | `api.binance.com/api/v3/klines` (spot) | Мониторингът използва **същия** endpoint за консистентност |
| TP/SL | `row4/TP-SL CALCULATOR` | `entry_price`, `stop_loss`, `take_profit_1..3`, `tp1..3_allocation`, `tp_strategy`, `sl_distance_pct`, fee 0.00055 на страна |
| Leverage | `row4/RISK-REWARD FILTER` | `recommended_leverage` е практически винаги 1x. Виж P-03 |
| Entry зона | `row4/TECHNICAL LEVEL IDENTIFIER` | `entry_min`, `entry_max`, `entry_zone_type` |
| Избор | `row4/SIGNAL RANKING & TOP 5 SELECTION` | `selected_for_telegram = true`, `final_rank`, до 5 сигнала |
| Logger | `row4/SIGNAL LOGGER` | Строи `_signal_logger_payload`. Чете `weight_*`, но Row 4 носи `applied_weights` (SCORE AGGREGATOR:322), затова weights са `null` |
| Insert | `row4/SUPABASE SIGNAL INSERT — N8N CONFIG` | HTTP POST към `telegram_signals`, документиран с **anon** ключ |
| Таблица | `supabase/telegram_signals.sql` | DDL без уникален ключ и без статус |

### 2.2 Ограничения
- N8N Cloud free plan: няма `$env`, промените по node-овете се правят ръчно, а квотата за изпълнения не е проверена. Hourly monitor означава около 720 изпълнения на месец. Ако квотата не стига, интервалът става 2h, а коректността не се засяга.
- Crypto Supabase проектът не е бил достъпен при одита. Агентът **не предполага** схемата на `raw_candles_data`, `scan_results` и т.н. и не зависи от тях.
- Липсват правила за break-even, trailing stop и максимално задържане. Тази спецификация ги дефинира само за симулацията и **не** променя стратегията.

---

## 3. Целева архитектура

```
ОСНОВЕН WORKFLOW (без промяна в логиката)
 Row 4 → SIGNAL LOGGER (разширен, P-05)
           ├─(изход 1, първи)→ Supabase Signal Insert (service key, idempotent)
           │                       └─ DB TRIGGER paper_on_signal_insert → paper_positions + OPENED събитие
           └─(изход 2)→ Loop Over Items → Send to Telegram (без промяна)

PAPER MONITOR WORKFLOW (нов, на час в HH:05, Europe/Sofia)
 Schedule → RPC paper_get_monitor_targets → [няма цели → край]
          → Binance klines 1h (за символ, от startTime)
          → Code: PAPER CANDLE NORMALIZER (само затворени свещи)
          → RPC paper_ingest_candles → RPC paper_evaluate_positions
          → (по желание) Telegram известие за изходи

SUPABASE
 paper_config · paper_positions · paper_position_events · paper_candles
 · paper_symbol_categories · paper_monitor_runs · изгледи и RPC за статистика · RLS

DASHBOARD (dashboard/, статичен SPA, Vercel/Netlify)
 Supabase Auth (1 потребител) → SELECT и RPC само за четене
```

**Нови файлове:**
- `supabase/paper_trading/001_schema.sql` … `005_security.sql` и `README.md` с реда на изпълнение
- `supabase/paper_trading/tests/*.sql`
- `monitor/PAPER CANDLE NORMALIZER` (Code node) и `monitor/PAPER MONITOR — N8N CONFIG` (описание на node-овете)
- `dashboard/`

**Променени файлове:**
- `row4/SIGNAL LOGGER`
- `row4/SUPABASE SIGNAL INSERT — N8N CONFIG`
- `row1/Sort & Select Top 20` (само `LIMIT`)

---

## 4. Пътна карта

| Част | Съдържание | Зависи от |
|---|---|---|
| 1 | Подготовка: предпоставки, схема, конфигурация | — |
| 2 | Интеграция на сигналите | 1 |
| 3 | Двигател за позиции (отваряне, sizing, статуси) | 1, 2 |
| 4 | Мониторинг и симулация на изходите | 3 |
| 5 | История и аналитика | 4 |
| 6 | Dashboard и календар | 5 |
| 7 | Тестове, валидация, надеждност (паралелно на 3–6, финализира се тук) | 3–6 |
| 8 | Внедряване и 30-дневен тест | 7 |

---

## ЧАСТ 1 — Подготовка и схема

### P-01 Предпоставки в pipeline-а
- **Цел:** тестът да мери реалната production конфигурация.
- **Промени:**
  1. `row1/Sort & Select Top 20`: `LIMIT = 20`, премахва се TODO коментарът.
  2. Документиране в `supabase/paper_trading/README.md` на проверка **(П)**: кой тригер е активен (очаква се Schedule на 2h, 08:00–22:00) и дали `Supabase Signal Insert` е свързан на canvas-а.
- **Приемане:** `LIMIT = 20` в repo-то. Потребителят е потвърдил тригера и insert node-а **(П)**.

### P-02 Схема на базата (`001_schema.sql`)
- **Цел:** постоянни структури за позиции, събития, свещи и конфигурация.

**`paper_config`** — един ред, `id = 1`, CHECK `id = 1`:

| Поле | Тип | Default | Значение |
|---|---|---|---|
| enabled | bool | true | глобален ключ |
| initial_capital_usd | numeric | 1000 | начален виртуален капитал |
| sizing_mode | text | 'FIXED_MARGIN' | `FIXED_MARGIN` \| `PERCENT_EQUITY` |
| fixed_margin_usd | numeric | 50 | margin за позиция при FIXED |
| equity_pct | numeric | 5 | % от equity при PERCENT |
| leverage_override | int | NULL | ако е зададен, замества leverage-а от сигнала |
| max_leverage | int | 10 | горна граница |
| fee_rate | numeric | 0.00055 | на страна (taker), както в TP-SL CALCULATOR |
| entry_slippage_pct | jsonb | {"1":0.05,"2":0.10,"3":0.20} | по tier, в % |
| stop_slippage_pct | jsonb | {"1":0.05,"2":0.10,"3":0.20} | за SL, TIMEOUT и DATA_UNAVAILABLE |
| tp_slippage_pct | numeric | 0 | TP са limit ордери |
| maintenance_margin_rate | numeric | 0.005 | за цената на ликвидация |
| max_holding_hours | int | 72 | изход по време |
| max_open_positions | int | 10 | лимит на едновременните позиции |
| max_signal_age_minutes | int | 45 | stale праг |
| move_sl_to_breakeven_after_tp1 | bool | false | правило за BE |
| notify_telegram_on_exit | bool | false | известия от монитора |
| timezone | text | 'Europe/Sofia' | за дневната агрегация |
| config_version | int | 1 | увеличава се при всяка промяна |
| updated_at | timestamptz | now() | |

**`paper_positions`** — един ред на **всеки** сигнал (1:1):
- **Идентификация:** `id` bigserial, `signal_id` int UNIQUE с FK към `telegram_signals.id`, `scan_cycle_id`, `symbol`, `tier`, `category` (snapshot от категориите), `direction` ('LONG'|'SHORT').
- **Статус:** `status` ('OPEN'|'CLOSED'|'SKIPPED'|'REJECTED'), `status_reason` text, `related_position_id` (при дубликат).
- **Входни нива (snapshot от сигнала):** `signal_entry_price`, `entry_min`, `entry_max`, `stop_loss`, `tp1`, `tp2`, `tp3`, `alloc1`, `alloc2`, `alloc3` (в %), `signal_leverage`, `total_score`, `market_condition`, `tp_strategy`, `fee_adjusted_rr`.
- **Симулация:** `entry_fill_price`, `leverage`, `margin_usd`, `notional_usd`, `quantity`, `liquidation_price`, `effective_stop` (SL след проверка за ликвидация), `stop_capped_by_liquidation` bool, `be_active` bool, `config_snapshot` jsonb (целият `paper_config` при отваряне).
- **Време:** `opened_at` (= `telegram_signals.sent_at`), `eval_start_open_time` (= началото на следващия пълен час), `last_evaluated_open_time` (курсор, NULL в началото), `closed_at`.
- **Резултат (поддържа го оценителят):** `remaining_pct` (100 → 0), `tp_hits` (0–3), `realized_gross_usd`, `fees_usd`, `funding_usd` (default 0, резервирано), `realized_net_usd`, `return_on_margin_pct`, `exit_reason`, `exit_summary` (напр. `TP1+SL`), `duration_hours`, `has_data_gap` bool.
- **Индекси:** уникален частичен индекс върху `symbol` WHERE `status = 'OPEN'` (най-много една отворена позиция на символ); индекси върху `closed_at`, `status`, `(symbol, closed_at)`.

**`paper_position_events`** — по едно събитие на всеки fill или промяна:
- Полета: `id`, `position_id` FK, `event_type` ('OPENED'|'TP1'|'TP2'|'TP3'|'SL'|'BREAKEVEN_SL'|'TIMEOUT'|'LIQUIDATION'|'DATA_UNAVAILABLE'|'BE_ACTIVATED'|'DATA_GAP'|'ERROR'), `tranche` (1–3 или NULL), `candle_open_time`, `level_price`, `fill_price`, `qty`, `pct_of_position`, `gross_usd`, `fees_usd`, `net_usd`, `details` jsonb, `created_at`.
- **UNIQUE(position_id, event_type, tranche):** гарантира, че нищо не се изпълнява два пъти.

**`paper_candles`:** `symbol`, `open_time` timestamptz, `close_time`, `open`, `high`, `low`, `close`, `volume`, `ingested_at`, PK(symbol, open_time). Само 1h.

**`paper_symbol_categories`:** `symbol` PK, `category` text. Seed: BTCUSDT → BTC, ETHUSDT → ETH, SOLUSDT → SOL. Символ без запис получава `OTHER`.

**`paper_monitor_runs`:** `id`, `started_at`, `finished_at`, `status` ('OK'|'PARTIAL'|'ERROR'|'SKIPPED_LOCKED'), `positions_evaluated`, `candles_used`, `events_created`, `positions_closed`, `error` text.

- **Edge cases:**
  - Таблицата `telegram_signals` може да не съществува в живата база. Миграцията проверява това и спира с ясна грешка.
  - Цените се пазят като `numeric` без загуба на точност. Закръгляне има само при показване.
- **Приемане:** миграцията минава два пъти поред без грешки; всички таблици, индекси и seed-ове съществуват; `paper_config` има точно един ред.
- **Тест:** скрипт, който проверява структурата (броя колони, уникалните индекси, единствения ред в config).

### P-03 Решение за leverage (блокер, не е код)
- **Цел:** тестът не тръгва с винаги 1x, ако това не е съзнателен избор.
- **Промени:** агентът **не** променя `RISK-REWARD FILTER`. В README-то се описват две опции за потребителя:
  - **(а)** внедрява нов leverage модел преди теста (отделна задача извън тази спецификация);
  - **(б)** задава `paper_config.leverage_override` (напр. 3) за целия тест.
- **Приемане:** **(П)** потребителят е избрал опция и стойността е записана в `paper_config`.

---

## ЧАСТ 2 — Интеграция на сигналите

### P-04 Разширяване на `telegram_signals` (`002_signal_ingest.sql`)
- **Нови колони (nullable):** `entry_min`, `entry_max`, `tp1_allocation`, `tp2_allocation`, `tp3_allocation`, `sl_distance_pct`, `total_score`, `cycle_timestamp` timestamptz.
- **Уникален индекс `(scan_cycle_id, symbol)`:** повторно пускане на цикъла не създава дубликат. Ако в живите данни вече има дубликати, миграцията **не** ги трие: спира и извежда списъка им (правило 7).
- **Приемане:** миграцията е idempotent; старите редове остават непокътнати.

### P-05 Промени в `row4/SIGNAL LOGGER`
- **Добавят се в payload-а:** `entry_min`, `entry_max`, `tp1_allocation` до `tp3_allocation`, `sl_distance_pct`, `total_score`, `cycle_timestamp` (ако липсва, `null`).
- **Поправка на weights:** източникът е `data.applied_weights.<key>`, с резерва към `data.weight_<key>`. Агентът първо проверява в кода на Row 4, че `applied_weights` достига до logger-а непроменено (SCORE AGGREGATOR:322 → VOLUME PENALTY APPLICATOR → Row 4 pass-through).
- **Не се променя:** guard-овете, филтърът `selected_for_telegram` и подреждането на изходните items.
- **Приемане:** при изпълнение **(П)** payload-ът съдържа новите полета, а `score_snapshot.weights` има числови стойности. Telegram съобщенията са непроменени.

### P-06 Insert node (`SUPABASE SIGNAL INSERT — N8N CONFIG`)
- **Промени в документацията:**
  1. Ключът става **service_role**, съхранен като N8N Credential (Header Auth), а не като текст в node-а.
  2. URL: `…/rest/v1/telegram_signals?on_conflict=scan_cycle_id,symbol`, header `Prefer: resolution=ignore-duplicates,return=minimal`.
  3. Insert-ът е **първият** изход на SIGNAL LOGGER. Telegram е вторият (N8N изпълнява изходите поред).
  4. `Continue on Fail: ON` за insert-а, така че срив на Supabase не спира Telegram. Грешката се вижда в execution log.
- **Edge cases:**
  - Цикъл без сигнали: logger-ът не прикача payload, затова insert node-ът трябва да има условие `_signal_logger_count > 0`. Добавя се IF node, който е документиран.
- **Приемане (П):**
  - Нов цикъл създава N реда, а повторното му пускане не добавя нищо.
  - Telegram работи.
  - Anon ключът вече не може да пише в таблицата (виж P-23).

### P-07 Telegram като опционален канал
- **Решение:** без нови node-ове в основния workflow. Telegram се изключва с „Deactivate“ на node-а `Send to Telegram` в N8N UI. README-то описва това.
- **Известия от монитора:** управляват се от `notify_telegram_on_exit` (P-15).
- **Приемане:** документирано; позициите се създават и при деактивиран Telegram.

---

## ЧАСТ 3 — Двигател за позиции

### P-08 Trigger `paper_on_signal_insert` (AFTER INSERT ON `telegram_signals`, за всеки ред)
Последователност (фиксирана):

1. Чете `paper_config`. Ако `enabled = false`, записва позиция SKIPPED с причина `PAPER_DISABLED`.
2. **Валидация** (провал → REJECTED с причина):
   - `signal_direction` е LONG или SHORT;
   - `entry_price`, `stop_loss` и `tp1` са > 0;
   - за LONG: SL < entry < TP1 ≤ TP2 ≤ TP3;
   - за SHORT: SL > entry > TP1 ≥ TP2 ≥ TP3;
   - липсващи TP2 или TP3 се заменят с предходното ниво;
   - сумата на алокациите е 100 ± 0.5. Ако алокациите липсват, се използва 40/40/20 и `status_reason` получава `DEFAULT_ALLOCATION`. Ако са зададени, но не дават 100, сигналът е REJECTED.
3. **Stale:** ако `cycle_timestamp` не е NULL и `sent_at − cycle_timestamp > max_signal_age_minutes`, сигналът е REJECTED с причина `STALE_SIGNAL`.
4. **Дубликат:** ако има OPEN позиция за същия символ, независимо от посоката, се записва SKIPPED с причина `DUPLICATE_OPEN_POSITION` и `related_position_id`.
5. **Лимит:** ако броят OPEN позиции ≥ `max_open_positions`, се записва SKIPPED с причина `MAX_OPEN_POSITIONS`.
6. **Sizing** (P-09). При недостатъчен свободен капитал се записва SKIPPED с причина `INSUFFICIENT_VIRTUAL_BALANCE`.
7. **Изчисления** (P-10). Записва се OPEN позиция и събитие `OPENED`.
8. Цялото тяло е обвито в обработка на изключения. При грешка се записва ред в `paper_positions` със статус REJECTED, причина `INTERNAL_ERROR: <message>` и събитие ERROR. **Trigger-ът никога не проваля insert-а на сигнала.**

- **Конкурентност:** уникалният частичен индекс е последната защита. При конфликт по него, например два сигнала за един символ в един insert, вторият ред става SKIPPED `DUPLICATE_OPEN_POSITION`.
- **Приемане:** всеки ред в `telegram_signals` има точно един ред в `paper_positions` (тестове T09, T10, T16).

### P-09 Sizing
- `equity = initial_capital_usd + Σ realized_net_usd` (за CLOSED позициите).
- `used_margin = Σ margin_usd` (за OPEN позициите).
- `free = equity − used_margin`.
- **FIXED_MARGIN:** `margin = fixed_margin_usd`.
- **PERCENT_EQUITY:** `margin = equity × equity_pct / 100`.
- Ако `margin > free` или `margin ≤ 0`, позицията е SKIPPED (виж P-08, стъпка 6).
- **Leverage** = `clamp(coalesce(leverage_override, signal.suggested_leverage, 1), 1, max_leverage)`.

### P-10 Формули при отваряне
Означения: `s_e = entry_slippage_pct[tier] / 100`, `L` = leverage, `mmr = maintenance_margin_rate`.

| Величина | LONG | SHORT |
|---|---|---|
| entry_fill | entry × (1 + s_e) | entry × (1 − s_e) |
| notional | margin × L | същото |
| quantity | notional / entry_fill | същото |
| liquidation_price | entry_fill × (1 − 1/L + mmr) | entry_fill × (1 + 1/L − mmr) |
| effective_stop | max(stop_loss, liq) — по-високият | min(stop_loss, liq) — по-ниският |

- `stop_capped_by_liquidation = true`, ако ликвидацията е по-близо до входа от SL.
- `eval_start_open_time = date_trunc('hour', opened_at) + 1 час`. Частичният първи час **не се оценява**: защита от look-ahead и известна, документирана неточност.
- `tranche_qty_k = quantity × alloc_k / 100`.

### P-11 Жизнен цикъл
```
(сигнал) → REJECTED | SKIPPED          (крайни, без събития освен ERROR)
(сигнал) → OPEN [remaining 100%] → OPEN [remaining < 100%, tp_hits ≥ 1] → CLOSED
```
CLOSED е краен статус. Позиция не може да се отвори повторно.

---

## ЧАСТ 4 — Мониторинг и симулация на изходите

### P-12 `paper_get_monitor_targets()` → списък `{symbol, start_time_ms}`
- Връща по един ред на символ с OPEN позиция.
- `start` е най-ранната стойност сред позициите на символа от `greatest(eval_start_open_time, last_evaluated_open_time + 1 час)`.
- **Приемане:** без OPEN позиции връща празен масив.

### P-13 N8N workflow `PAPER MONITOR` (`monitor/PAPER MONITOR — N8N CONFIG`)
1. **Schedule Trigger:** на всеки час в минута 5; часовата зона на workflow-а е Europe/Sofia.
2. **HTTP POST** `rpc/paper_get_monitor_targets` (service credential).
3. **IF:** при празен резултат изпълнението приключва.
4. **HTTP GET** `https://api.binance.com/api/v3/klines?symbol={symbol}&interval=1h&startTime={start_time_ms}&limit=1000`.
   - Batching: 5 заявки в секунда.
   - Retry: 3 опита през 2 секунди.
   - `Continue on Fail: ON`, за да не спре целият run заради един символ.
5. **Code `PAPER CANDLE NORMALIZER`** (нов файл в `monitor/`):
   - превръща масивите на Binance в обекти `{symbol, open_time, close_time, open, high, low, close, volume}`;
   - **изхвърля** свещи с `close_time ≥ now` (незатворени);
   - изхвърля отговори с грешка, като записва символа в `failed_symbols`;
   - изходът е **един** item: `{candles: [...], failed_symbols: [...]}`.
6. **HTTP POST** `rpc/paper_ingest_candles` с `p_candles` → upsert по (symbol, open_time); връща броя.
7. **HTTP POST** `rpc/paper_evaluate_positions` → обобщение плюс списък на новите изходни събития.
8. **По желание:** ако `notify_telegram_on_exit` е true и има събития, изпраща кратко Telegram съобщение за всяко (символ, събитие, цена, net $).

- **Приемане (П):** ръчно изпълнение с една тестова OPEN позиция записва свещи и ред в `paper_monitor_runs`.

### P-14 `paper_evaluate_positions()` — алгоритъм (задължителен, без отклонения)

**Заключване:** функцията взима `pg_try_advisory_xact_lock(<константа>)`. Ако заключването не успее, записва run със статус `SKIPPED_LOCKED` и приключва.

**За всяка OPEN позиция** (подредени по `opened_at`; редът се заключва `FOR UPDATE`) се взимат свещите от `paper_candles` за символа, в които:
- `open_time ≥ eval_start_open_time`;
- `open_time > coalesce(last_evaluated_open_time, −∞)`;
- `close_time < now()`.

Свещите се обработват **по ред на `open_time`**. За всяка свещ `c`:

1. **Пропуск в данните:** ако има предходна свещ и `c.open_time − prev.open_time > 1 час`, се записва събитие DATA_GAP (веднъж на позиция) и `has_data_gap = true`. Обработката продължава.
2. **Активен стоп:**
   - Ако `be_active = false`, активният стоп е `effective_stop`.
   - Ако `be_active = true`: за LONG е `max(effective_stop, entry_fill)`, за SHORT е `min(effective_stop, entry_fill)`.
3. **Докосване на стопа:** за LONG `c.low ≤ стоп`, за SHORT `c.high ≥ стоп`.
4. **Ако стопът е докоснат, той има приоритет пред всякакви TP в същата свещ** (консервативно правило):
   - **Цена на изпълнение:**
     - gap-through (LONG `c.open ≤ стоп`, SHORT `c.open ≥ стоп`): изпълнение по `c.open`;
     - иначе: по стопа.
     - След това се прилага неблагоприятен slippage `s_x = stop_slippage_pct[tier]`: LONG × (1 − s_x), SHORT × (1 + s_x).
   - **Причина:**
     - `LIQUIDATION`, ако `stop_capped_by_liquidation` и стопът е `liquidation_price`;
     - `BREAKEVEN_SL`, ако е активен BE стоп;
     - иначе `SL`.
   - Затварят се **всички** оставащи транши; позицията става CLOSED; обработката на свещите спира.
5. **Иначе — TP нивата по ред** k = 1, 2, 3 (само неизпълнените):
   - LONG: `c.high ≥ tp_k`; SHORT: `c.low ≤ tp_k`.
   - При изпълнение траншът k се затваря по `tp_k × (1 ∓ tp_slippage)`. Дори при gap над нивото цената е `tp_k`, не по-добра.
   - Няколко TP в една свещ са позволени.
   - Спира се на първото неизпълнено ниво.
6. **Break-even:** ако `move_sl_to_breakeven_after_tp1` и TP1 е изпълнен в тази свещ, се записва `BE_ACTIVATED` и `be_active = true`. **Влиза в сила от следващата свещ**, без look-ahead.
7. **Пълно затваряне:** ако `remaining_pct = 0`, позицията става CLOSED с `exit_reason = TP3`.
8. **Изход по време:** ако остава отворен дял и `c.close_time ≥ opened_at + max_holding_hours`:
   - остатъкът се затваря по `c.close` с неблагоприятен stop slippage;
   - причината е `TIMEOUT`; позицията става CLOSED.
9. `last_evaluated_open_time = c.open_time`.

**След свещите:** ако позицията е OPEN, `now() − opened_at > max_holding_hours + 24 часа` и няма нито една свещ след `eval_start_open_time`:
- позицията се затваря по последния известен close от `paper_candles` или по `entry_fill`, ако няма такъв;
- причината е `DATA_UNAVAILABLE`.

**Обновяване на агрегатите** на позицията след всяко събитие: `remaining_pct`, `tp_hits`, `realized_gross_usd`, `fees_usd`, `realized_net_usd`, `return_on_margin_pct`, `exit_summary`, а при CLOSED и `closed_at = c.close_time` и `duration_hours`.

**Връща:** jsonb с полетата `evaluated`, `candles_used`, `events` (масив с новите изходни събития), `closed` и `status`. Записва ред в `paper_monitor_runs`.

### P-15 Формули при изход (на транш или остатък)
Означения: `q` = количество в изхода, `F` = `fee_rate`.

- **gross:** LONG `q × (exit_fill − entry_fill)`; SHORT `q × (entry_fill − exit_fill)`.
- **fees:** `q × entry_fill × F + q × exit_fill × F`. Входящият fee се отчита пропорционално към всеки изход.
- **net:** `gross − fees`.
- **LIQUIDATION:** `net = −(margin_usd × pct_of_position / 100)`. Целият margin на дяла се губи, а fees вече са включени в загубата.
- **На ниво позиция:**
  - `realized_net_usd = Σ net`;
  - `return_on_margin_pct = realized_net_usd / margin_usd × 100`;
  - движение на цената без leverage: `(среднопретеглен exit_fill / entry_fill − 1) × 100`, със знак −1 за SHORT.
- **Класификация:**
  - печеливша при `realized_net_usd > 0.01`;
  - губеща при `< −0.01`;
  - иначе BREAKEVEN.

### P-16 Еталонни примери (стават автоматични тестове с толеранс ±0.01 $)

**Пример 1 — LONG, Tier 1** (`s_e = s_x = 0.05%`, margin 50, L = 5, алокация 40/40/20):
- Entry 80 000 → entry_fill 80 040; notional 250.
- Нива: SL 78 800, TP1 81 200, TP2 81 600, TP3 82 000.
- **(1a) TP1 и после SL:**
  - траншът TP1 дава net +1.34;
  - остатъкът от 60% излиза на SL по 78 760.6 с net −2.56;
  - **позицията дава −1.22 $, −2.45%**; `exit_summary` = `TP1+SL`.
- **(1b) Двусмислена първа свещ** (Low 78 700, High 81 300):
  - прилага се SL за 100%;
  - **резултатът е −4.27 $**; TP1 **не** се отчита.

**Пример 2 — SHORT, Tier 3** (`s_e = 0.20%`, margin 50, L = 3, алокация 50/35/15):
- Entry 100 → entry_fill 99.8; notional 150.
- Нива: SL 104, TP1 97, TP2 95, TP3 92. Трите TP са ударени в отделни свещи.
- Net по транши: +2.02, +2.47 и +1.73.
- **Позицията дава +6.23 $, +12.45%**, причина `TP3`.
- Ликвидационната цена е 132.57, т.е. SL не е ограничен от ликвидацията.

---

## ЧАСТ 5 — История и аналитика (`004_analytics.sql`)

### P-17 Изглед `paper_positions_v`
- Позиции плюс категория, `closed_date_local = (closed_at AT TIME ZONE config.timezone)::date` и `outcome` (WIN, LOSS или BREAKEVEN).
- **Единственият** източник за списъци и детайли във frontend-а.

### P-18 RPC `paper_stats(p_from date, p_to date, p_symbols text[], p_categories text[], p_direction text, p_tiers int[])`

Отчитат се само CLOSED позиции, чийто `closed_date_local` е в интервала. Филтрите са NULL = всички.

| Показател | Формула |
|---|---|
| trades | брой CLOSED позиции |
| wins / losses / breakeven | по класификацията от P-15 |
| win_rate_pct | wins / trades × 100 (0 при trades = 0) |
| total_net_usd | Σ realized_net_usd |
| total_return_pct | total_net_usd / initial_capital_usd × 100 |
| avg_win_usd / avg_loss_usd | средно за печелившите / за губещите (NULL при 0 сделки) |
| profit_factor | Σ печалби / \|Σ загуби\| (NULL при липса на загуби) |
| expectancy_usd | total_net_usd / trades |
| avg_duration_hours | средно |
| open_positions | брой OPEN позиции при същите филтри, без филтър по дата |
| skipped / rejected | броеве в интервала по `opened_at` |

### P-19 RPC `paper_daily_pnl(p_month date, филтри)`
- Връща ред за **всеки** ден от месеца, включително без сделки: `day`, `trades`, `wins`, `losses`, `net_usd`, `cumulative_net_usd`.
- Кумулативът започва от 0 в началото на месеца.
- Месечното обобщение се взима с `paper_stats` за целия месец.

### P-20 Правила за агрегация
- **Ден на сделката = денят на пълното ѝ затваряне** в Europe/Sofia. Частично реализираната печалба на OPEN позиция не влиза в дневния P&L. Тя се показва отделно като „частично реализирано“.
- **Ориентировъчен нереализиран P&L** за OPEN позиции: по последния close в `paper_candles`, ясно маркиран като ориентировъчен. Не влиза в нито един показател.
- Всички изчисления са в SQL. Повторно извикване със същите данни дава същия резултат.

### P-21 Повторно изчисление `paper_recompute_position(p_id)` (само за service role)
- Трие събитията на позицията освен `OPENED`, нулира агрегатите и курсора и връща статус OPEN.
- След това позицията се оценява наново при следващото `paper_evaluate_positions`.
- Използва се при валидация и при доказана грешка в правилата. Всяко използване се отбелязва в `details` на ново събитие.

---

## ЧАСТ 6 — Dashboard и месечен календар (`dashboard/`)

### P-22 Основа
- **Stack:** Vite, React, TypeScript, `@supabase/supabase-js`, `react-router-dom`.
- Без UI framework, chart библиотеки и state management библиотеки.
- Календарът е собствен CSS grid.
- **Дизайн:** потребителят има готов дизайн. **Преди UI работата агентът спира и иска дизайн файловете.** Ако не бъдат предоставени, използва неутрален минимален layout с CSS променливи, за да може дизайнът да се приложи по-късно без пренаписване.
- **Конфигурация:** `VITE_SUPABASE_URL` и `VITE_SUPABASE_ANON_KEY` (anon ключът е публичен по дизайн; защитата е в RLS). Файл `.env.example`, без реални стойности в repo-то.
- **Достъп:** Supabase Auth с email magic link. Без вход се показва само екранът за вход.
- **Правило:** frontend-ът **не прави финансови изчисления**. Само форматира стойностите: USD с 2 знака, проценти с 2 знака, дати в Europe/Sofia.

### P-23 Сигурност (`005_security.sql`)
- RLS е включен за всички `paper_*` таблици и за `telegram_signals`.
- Политиките са само **SELECT** за `authenticated`.
- Няма INSERT, UPDATE или DELETE политики: пише само service role (N8N).
- Изтрива се старата anon insert политика на `telegram_signals`, ако съществува.
- RPC функциите за статистика са `SECURITY INVOKER`, с EXECUTE за `authenticated`.
- `paper_evaluate_positions`, `paper_ingest_candles` и `paper_recompute_position` имат EXECUTE само за `service_role`.
- **(П)** В Supabase Auth регистрациите са изключени и има създаден един потребител.

### P-24 Екрани
Глобална лента с филтри: символи (multi-select), категория, посока, tier. Филтрите се пазят в URL query параметрите и важат за всички екрани.

1. **„Ден“ (`/`, по подразбиране днес):**
   - Избор на дата.
   - KPI плочки от `paper_stats` за деня: сделки, печалби, загуби, win rate, net $, return %, средна печалба, средна загуба.
   - Таблица на затворените сделки с колони: символ, посока, вход, изход, резултат %, net $, продължителност, причина.
   - Клик на ред отваря модален прозорец с всички полета на позицията и хронология на събитията (време, тип, цена, net).
2. **„Календар“ (`/calendar`):**
   - Месечна мрежа. Всеки ден показва net $ и брой сделки.
   - Зелен фон при net > 0, червен при < 0, неутрален при 0 или без сделки.
   - Интензитетът е пропорционален на |net| спрямо максимума за месеца.
   - Над мрежата: месечен net, return %, брой сделки, win rate. Във всяка клетка с малък шрифт: кумулативен net.
   - Клик на ден отваря „Ден“ за тази дата. Навигация месец назад и напред.
3. **„Позиции“ (`/positions`):**
   - Раздел „Отворени“: символ, посока, вход, SL и TP с отметки за изпълнените, remaining %, часове, ориентировъчен P&L.
   - Раздел „История“: всички CLOSED, SKIPPED и REJECTED позиции с филтър по статус и сортиране.
   - Пагинация по 50.
4. **„Сравнение“** (част от „Позиции“, панел над таблицата):
   - `paper_stats` разбит по символ, категория, посока и tier за избран период.
   - Таблица с trades, win rate, net и profit factor.
   - Сегмент с под 20 сделки е маркиран „малка извадка“.

- **Състояния:** зареждане, празни данни („Няма сделки за периода“), грешка при заявка (съобщение и бутон „Опитай пак“), изтекла сесия (пренасочване към вход).
- **Responsive:** работи от 360 px ширина нагоре. На мобилен календарът минава в списък по дни.
- **Приемане:**
  - стойностите на екран съвпадат с директна SQL заявка за 3 произволни дни **(П)**;
  - филтрите променят KPI, календара и таблиците консистентно;
  - без вход данните са недостъпни (проверено с anon заявка без сесия).

---

## ЧАСТ 7 — Тестове, валидация и надеждност

### P-25 SQL сценарии (`supabase/paper_trading/tests/`)
- Всеки файл е самостоятелен и минава в транзакция с ROLLBACK.
- Всеки сам подготвя config, сигнал и свещи, извиква функциите и при разминаване прекратява с `RAISE EXCEPTION` с описание.
- `tests/README.md` описва как да се пуснат в SQL Editor-а на тестов проект или branch, **не** в production.

| ID | Сценарий | Очакване |
|---|---|---|
| T01 | Пример 1a | −1.22 $, `TP1+SL`, 2 изходни събития |
| T02 | Пример 1b, двусмислена свещ | −4.27 $, само събитие SL |
| T03 | Пример 2, SHORT с всички TP | +6.23 $, TP3 |
| T04 | TP1 и TP2 в една свещ | две събития, remaining 20% |
| T05 | Gap под SL (open < SL) | изпълнение по open със slippage |
| T06 | Нищо не е ударено за 72 часа | TIMEOUT по close на свещта, в която изтичат 72 часа |
| T07 | BE включен: TP1, после връщане до входа | BE не важи в свещта на TP1; в следващата е BREAKEVEN_SL |
| T08 | L = 20, SL отвъд ликвидацията | `stop_capped_by_liquidation`, LIQUIDATION, net = −margin на дела |
| T09 | Втори сигнал за символ с OPEN позиция; нов сигнал след затварянето ѝ | SKIPPED `DUPLICATE_OPEN_POSITION`; новият се отваря |
| T10 | Невалидни нива, грешна алокация, stale | REJECTED с правилната причина |
| T11 | `evaluate` два пъти; `ingest` на същите свещи два пъти | непроменени събития, P&L и брой свещи |
| T12 | Свещ с close_time в бъдещето | игнорира се |
| T13 | Позиция в 10:14; TP е ударен в свещта 10:00 | не се отчита; оценката започва от 11:00 |
| T14 | Курсор отпреди 10 часа | едно изпълнение наваксва 10 свещи коректно |
| T15 | Advisory lock е зает | `SKIPPED_LOCKED`, без промени |
| T16 | Принудителна грешка в trigger-а | сигналът е записан; позицията е REJECTED `INTERNAL_ERROR` |
| T17 | Статистика на зададен набор; сделка, затворена в 23:30 UTC | точни очаквани стойности; сделката е в **следващия** ден по София |
| T18 | PERCENT_EQUITY; недостатъчен баланс | правилен margin; SKIPPED `INSUFFICIENT_VIRTUAL_BALANCE` |
| T19 | Max open positions | SKIPPED `MAX_OPEN_POSITIONS` |
| T20 | `paper_recompute_position` | резултатът е идентичен с първоначалния |

### P-26 Frontend тестове
- **Unit (vitest):** форматиране на валута, процент и дата в Europe/Sofia; съпоставяне на URL филтрите с параметрите на RPC; оцветяване на календара.
- **E2E (ръчен чеклист в `dashboard/README.md`):** вход, навигация между трите екрана, филтри, модален прозорец, празен месец, мобилна ширина.

### P-27 Регресия на основния pipeline
- `git diff` спрямо началния commit засяга в `row*/` **само** `row4/SIGNAL LOGGER` и `row1/Sort & Select Top 20`.
- **(П)** Едно изпълнение на основния workflow след внедряването: Telegram съобщенията са идентични по формат; броят на сигналите в `telegram_signals` е равен на изпратените; всеки има позиция.

### P-28 Надеждност и наблюдение
- **Рестарт:** цялото състояние е в Supabase. Курсорът и уникалните ключове правят всяко повторно изпълнение безопасно (T11, T14).
- **Изгледът `paper_health_v`:**
  - последният успешен monitor run и възрастта му в часове;
  - OPEN позиции без оценка повече от 3 часа;
  - позиции с DATA_GAP;
  - REJECTED с `INTERNAL_ERROR` за последните 24 часа.
- Dashboard-ът показва предупредителна лента, ако последният успешен run е отпреди повече от 3 часа.

---

## ЧАСТ 8 — Внедряване и 30-дневен тест

### P-29 Ред на внедряване (П, по `supabase/paper_trading/README.md`)
1. Backup или export на `telegram_signals`.
2. SQL файлове 001 → 005 в SQL Editor-а; след всеки — проверката от README-то.
3. Сценариите от P-25 в Supabase **branch** или тестов проект, ако има такъв; иначе се пропуска стъпката и рискът се отбелязва.
4. N8N: service credential, промени по `SIGNAL LOGGER` и insert node-а (P-05, P-06), `LIMIT = 20`.
5. N8N: импорт и активиране на `PAPER MONITOR`.
6. Deploy на dashboard-а (Vercel или Netlify, env променливи), създаване на потребителя.
7. Задаване на `paper_config` по P-30.

### P-30 Начална конфигурация на теста
- **Капитал и размер:** initial 1000 $, FIXED_MARGIN 50 $.
- **Leverage:** по решението от P-03.
- **Разходи:**
  - fee 0.055% на страна;
  - slippage 0.05%, 0.10% и 0.20% по tier, за вход и за стоп;
  - TP slippage 0.
- **Ограничения:** max holding 72 часа; max open 10; BE изключен; stale праг 45 минути. Ако измерената продължителност на цикъла в N8N е по-голяма, прагът се коригира **преди** старта.
- **Фиксиране:** конфигурацията и стратегията се **замразяват** за 30-те дни. Всяка принудителна промяна увеличава `config_version` и се описва в `CHANGELOG`.

### P-31 Процедура на теста
- **Ден −2 до 0 (shadow run):** системата работи, но резултатите не се броят. Ръчно се сверяват 10–15 сделки с графика (TradingView, 1h): вход, всяко докосване на ниво, причина за изход. Изискването е **100% съвпадение** с правилата от P-14. При разминаване се спира, оправя, изпълнява се `paper_recompute_position` и сверката се повтаря.
- **Ден 1:** потребителят изтрива или архивира shadow позициите и започва официалният тест.
- **Всеки ден (5 минути):** `paper_health_v` е без предупреждения; броят на сигналите равен на броя позиции; няма `INTERNAL_ERROR`.
- **Всяка седмица:** преглед на `paper_stats` по сегменти, без промени по стратегията.

### P-32 Критерии за успех

**Технически (системата е надеждна):**
- 100% от сигналите имат позиция;
- 0 пропуснати изходи при седмичната случайна проверка на 5 сделки;
- нито един мониторинг пропуск над 3 часа, който не е наваксан автоматично;
- всички тестове T01–T20 минават.

**Търговски (стратегията заслужава реален капитал)** — праговете се потвърждават от потребителя преди старта:
- поне 100 затворени сделки;
- положителен expectancy след fees и slippage;
- profit factor ≥ 1.3;
- максимален drawdown на виртуалния капитал ≤ 20%;
- положителен резултат в поне 3 от 4 седмици.

**Оптимизация след теста:**
- Изводи се правят само за сегменти с поне 20 сделки.
- Последните 10 дни се третират като контролен период: правила, „настроени“ по първите 20 дни, трябва да се потвърдят там.
- Една промяна се прави за един нов тестов период, за да е ясно на какво се дължи разликата.

---

## 9. Зависимости и последователност

```
P-01 → P-02 → P-03(решение)
          └→ P-04 → P-05 → P-06 → P-07
                    └→ P-08 → P-09 → P-10 → P-11
                                         └→ P-12 → P-13 → P-14 → P-15 → P-16
                                                                     └→ P-17 → P-18 → P-19 → P-20 → P-21
                                                                                                  └→ P-22 → P-23 → P-24
P-25 се пише заедно с P-08…P-21 (тест преди следващата задача); P-26 с P-24; P-27…P-28 → P-29 → P-30 → P-31 → P-32
```

Задачите P-05 и P-06 могат да се внедрят в N8N след P-04. Позиции се отварят едва когато P-08 е в базата.

---

## 10. Definition of Done

Системата е готова за 30-дневния тест, когато:

1. Всички SQL файлове са idempotent и в repo-то, с README за реда на изпълнение.
2. Тестовете T01–T20 минават. Еталонните примери съвпадат до ±0.01 $.
3. Всеки сигнал в `telegram_signals` има точно един ред в `paper_positions` със статус и причина.
4. Мониторингът наваксва пропуснати часове. Повторното изпълнение не променя нищо. Конкурентно изпълнение се отказва безопасно.
5. TP, SL, BE, TIMEOUT, LIQUIDATION и двусмислените свещи се обработват точно по P-14. Няма look-ahead.
6. Дневните и месечните стойности в dashboard-а съвпадат с директни SQL заявки. Филтрите работят консистентно.
7. Данните са достъпни само след вход. Пише само service role.
8. Основният pipeline и Telegram работят без регресия. Промените в `row*/` са само посочените.
9. Shadow run-ът е преминат със 100% съвпадение при ръчната сверка.
10. Leverage решението и началната конфигурация са записани, а конфигурацията е замразена.
