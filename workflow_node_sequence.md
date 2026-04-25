# 🔁 Crypto Signal System — N8N Workflow Node Sequence

> Пълна последователност на всички Nodes по редове, базирана на workflow диаграмата.

---

## ROW 1 — Data Ingestion & Candle Processing

```
When clicking 'Execute workflow'
  ---> Binance Fetch Symbols (GET: api.binance.com)
  ---> Filter USDT Pairs1
  ---> Sort QuoteVolume Top 50
  ---> Validate 72h History
  ---> Filtering Assets with 72h Candle History
  ---> Sort & Select Top 20
  ---> Crypto Symbols Metadata
  ---> Crypto Symbols Insert (POST)
  ---> Get Active Symbols (GET)
  ---> SYMBOL ACTIVITY MANAGER
  ---> Update Symbol Status (PATCH)
  ---> Bulk Requests Generator Binance Candles
  ---> Binance Candles (HTTP)
  ---> Group Candle Responses
  ---> BINANCE CANDLE PROCESSOR
  ---> EXTRACT 1M PRICES AND MERGE
```

---

**ROW 1 → ROW 2 transition:**

```
EXTRACT 1M PRICES AND MERGE (last of Row 1)
  -----> // DEBUG + DE-DUPLICATION (first of Row 2)
```

---

## ROW 2 — TAAPI Indicators Fetch & DB Write

```
// DEBUG + DE-DUPLICATION
  ---> HTTP Request Post (POST: fvoorhimkqwm...)
  ---> HTTP Request Get (GET: fvoorhimkqwm...)
  ---> Candles Grouping & Latest 20 per Symbol
  ---> SMA 20 Calculation
  ---> Merge SMA with Symbols
  ---> Separation of Requests
  ---> Loop Over Items1
       |
       |---> [loop body] ---> Cooldown after Batch 6
       |                          |
       |                     Wait1 (pause)
       |                          |
       |                     HTTP POST TAAPI BULK (POST: api.taapi.io/bulk)
       |                          |
       |                     TAAPI RESPONSE PROCESSOR
       |                          |
       |                     Final post to DB (POST: fvoorhimkqwm...)
       |
       [loop continues until all batches processed]
```

---

**ROW 2 → ROW 3 transition:**

```
Final post to DB (last of Row 2)
  -----> Fetch Data AFTER TAAPI (first of Row 3)
```

---

## ROW 3 — Tier Classification, Scoring & Aggregation

### ROW 3 Part 1 — Asset Classification & Data Preparation

```
Fetch Data AFTER TAAPI
  ---> ASSET TIER CALCULATOR
  ---> ATR Volatility Analyzer2
  ---> Prepare Tier Data
  ---> Supabase INSERT (POST)
  ---> Restore Full Data After Tier Insert
```

### ROW 3 Part 2 — Multi-Branch Scoring (Split → Merge)

```
Restore Full Data After Tier Insert
  --Split to 5 parallel branches-->

  * Branch 1: ADX Market Condition Detector1 ---> Adaptive Weights Calculator1
  * Branch 2: MOMENTUM SCORE CALCULATOR
  * Branch 3: Volatility Score Calculator1
  * Branch 4: TREND SCORE CALCULATOR
  * Branch 5: VOLUME SCORE CALCULATOR ---> Price Action Score Calculator

  [All 5 branches] ---> Merge (combineByS ql)
                            |
                        Score Aggregator
                            |
                        VOLUME PENALTY APPLICATOR
```

---

**ROW 3 → ROW 4 transition:**

```
VOLUME PENALTY APPLICATOR (last of Row 3)
  -----> TP-SL CALCULATOR (first of Row 4)
```

---

## ROW 4 — Risk Management, Filters & Signal Distribution

```
TP-SL CALCULATOR
  ---> RISK-REWARD FILTER
  ---> RISK-REWARD SCORE OUTPUT
  ---> Technical Level Identifier
  ---> Entry Zone Validator
  ---> HARD FILTERS ENFORCER
  ---> SIGNAL RANKING & TOP 5 SELECTION
  ---> Loop Over Items
       |
       [loop body] ---> Send to Telegram (POST: api.telegram.org)
```

---

## 📋 Merge Node — Input Mapping (Row 3 Part 2)

| Input | Node | Данни |
|-------|------|-------|
| input1 | Adaptive Weights Calculator1 | `weight_*`, `market_condition`, `adx_strength` |
| input2 | MOMENTUM SCORE CALCULATOR | `momentum_score`, `momentum_components` |
| input3 | Volatility Score Calculator1 | `volatility_score`, `volatility_status`, `atr_*` |
| input4 | TREND SCORE CALCULATOR | `trend_score`, `trend_components`, `trend_direction` |
| input5 | Price Action Score Calculator | `volume_score`, `price_action_score`, `volume_penalty` |

---

*Last updated: 2026-04-26*
