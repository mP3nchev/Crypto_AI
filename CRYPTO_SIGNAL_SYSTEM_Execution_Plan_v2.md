**CRYPTO SIGNAL SYSTEM**

**IMPLEMENTATION EXECUTION PLAN**

Based on Audit Report — commit 2eb9fc9

# **SECTION 1 — ISSUE BREAKDOWN BY CATEGORY**

Data Integrity: A-02, A-03, A-04, A-05, A-06

Pipeline Architecture: A-01, A-07, A-08, A-10

Scoring Logic: T-02, T-03, T-04, T-06, T-08, T-10

Risk / Trading Logic: T-01, T-05, T-07, T-09

Tier Configuration: A-09

# **SECTION 2 — IMPLEMENTATION DIRECTIVES**

**A-01  TAAPI Secret Key Hardcoded in Separation of Requests**

**Problem Summary:**

TAAPI JWT secret is hardcoded as a string literal. Even after removal, the exposed key in git log remains valid until manually rotated.

**WHAT:**

Remove the hardcoded secret string entirely. Replace with N8N Credential or environment variable reference. Rotate current key immediately via TAAPI dashboard.

**WHERE:**

Row 2, Separation of Requests node, top of script where SECRET\_KEY is declared.

**HOW:**

* Source the secret from N8N Credential store or $env object — never inline string assignment.

* The value must not appear in any console.log statement.

* The value must not be included in any DB insert payload.

* If Credential is missing or undefined, node must throw explicit error and halt — not silently proceed.

**Edge Cases:**

Missing credential \= explicit halt. Not silent continuation with empty key.

**QA Validation:**

Search full N8N execution logs for key string pattern. Confirm no DB record contains key substring. Confirm TAAPI calls succeed after migration.

**System Impact:**

No downstream logic changes. Only key sourcing mechanism changes.

**A-02  Dual scan\_cycle\_id — Race Condition on Minute Boundary**

**Problem Summary:**

scan\_cycle\_id is generated independently in three nodes (Crypto Symbols Metadata, Bulk Requests Generator, Separation of Requests). Slow execution at minute boundary produces different IDs per node. Row 3 Fetch Data AFTER TAAPI may return 0 results or mix two cycles.

**WHAT:**

Generate scan\_cycle\_id exactly once in Crypto Symbols Metadata. Propagate as a data field through every subsequent node.

**WHERE:**

Row 1, Crypto Symbols Metadata (generation point). All downstream nodes that currently call new Date() to construct scan\_cycle\_id must read from upstream input instead.

**HOW:**

* Single authoritative scan\_cycle\_id generated from new Date() in Crypto Symbols Metadata, formatted YYYY-MM-DD\_HH:MM.

* Every item output by every subsequent node in Row 1 must carry this value unchanged in the json payload — including candle items produced by BINANCE CANDLE PROCESSOR and EXTRACT 1M PRICES AND MERGE.

* Bulk Requests Generator must read scan\_cycle\_id from its input items (the Top 20 symbol records output by Sort & Select Top 20), not generate a new one. Those items carry scan\_cycle\_id from Crypto Symbols Metadata via the item chain.

* Separation of Requests must read scan\_cycle\_id from its input items (which come from Merge SMA with Symbols, which gets symbol records from Crypto Symbols Insert — those records carry the original scan\_cycle\_id). No new Date() call.

* CRITICAL — Row 3 gap: Fetch Data AFTER TAAPI is the first node of Row 3 and queries Supabase for the current cycle. If this node constructs its WHERE clause using a fresh new Date() call instead of the scan\_cycle\_id from its incoming items (output of Final post to DB in Row 2), it will query the wrong minute. Fix: Fetch Data AFTER TAAPI must read scan\_cycle\_id from the items it receives and use that value in the DB query filter.

* If items arrive with conflicting IDs after retry, log conflict and use the earliest value (the original cycle's ID).

**QA Validation:**

Log scan\_cycle\_id at start of Row 2 and Row 3\. Verify matches Row 1 value. Any mismatch is critical failure.

**System Impact:**

DB uniqueness constraint on (symbol\_id, scan\_cycle\_id) in scan\_results is only reliable after this fix. Three nodes must be changed: Bulk Requests Generator, Separation of Requests (remove new Date() calls), and Fetch Data AFTER TAAPI (use incoming scan\_cycle\_id in DB query). Without the Fetch Data fix, the Row 2 data is stored correctly but Row 3 queries the wrong cycle.

**A-03  GROUP CANDLE RESPONSES — Positional Matching Fragile on HTTP Retry**

**Problem Summary:**

Despite Map-fix comment, actual algorithm uses responsePointer for positional matching. requestMap provides only metadata. HTTP retry or parallel connections can reorder responses — causing silent symbol data swap (BTCUSDT indicators computed from ETHUSDT candles).

**WHAT:**

ARCHITECTURAL CONSTRAINT: N8N’s HTTP Request node does not natively propagate per-request metadata (symbol, interval) into the response object. The response body contains only the Binance API payload. There is no built-in mechanism to attach “this response belongs to BTCUSDT 2h” to the returned data. The original directive assumed this was configurable — it is not in standard N8N. Two concrete alternatives are described below.

**WHERE:**

Row 1, GROUP CANDLE RESPONSES node. Also Bulk Requests Generator — must embed symbol/interval in HTTP request parameters.

**HOW:**

* OPTION A (recommended — eliminates positional matching entirely): Replace the single Bulk HTTP node with 4 separate HTTP Request nodes, one per interval (2h, 1h, 15m, 1m). Each node receives all 20 symbols sequentially and processes only its designated interval. Symbol order within each node is deterministic (from Sort & Select Top 20). Interval identity is implicit from which node produced the response. GROUP CANDLE RESPONSES then receives 4 batches with known interval per batch — no positional matching required across interval boundaries.

* OPTION B (minimal change — adds count-based interval identification): Keep the current bulk approach but add interval identification from candle count in GROUP CANDLE RESPONSES. The limits are distinct: 2h=20, 1h=12, 15m=1, 1m=1. When a response batch arrives, its interval can be inferred from candle count (20 candles \= 2h, 12 candles \= 1h). For 15m and 1m (both limit=1), they are ambiguous by count alone — these must remain positionally separated in the request sequence, or one limit must be changed (e.g., 15m limit=2, 1m limit=1). Symbol identity still depends on request ordering being stable — this is only safe if N8N guarantees sequential HTTP execution without retry reordering, which it does not guarantee.

* DECISION REQUIRED: Option A requires adding 3 new HTTP nodes and restructuring GROUP CANDLE RESPONSES to merge 4 known-interval batches. Option B is a smaller change but retains the retry vulnerability for symbol ordering. If N8N is configured with retry disabled on the Binance HTTP nodes, Option B is acceptable. If retries are on, Option A is the only safe choice.

* Regardless of option chosen: the existing completeness check (all 4 intervals present per symbol) and COUNT\_MISMATCH logging must remain.

**Edge Cases:**

Fewer candles than requested: log COUNT\_MISMATCH, mark INCOMPLETE, exclude from TAAPI. Retry responses must still route to correct symbol.

**QA Validation:**

For Option A: verify that all 4 interval HTTP nodes produce non-empty output and that GROUP CANDLE RESPONSES correctly assigns each batch to its interval. For Option B: verify candle count per response matches expected limit before merging. In both cases: inject a forced retry for one symbol and verify no adjacent symbol receives misrouted data.

**A-04  DEBUG \+ DE-DUPLICATION Drops median\_volume Fields**

**Problem Summary:**

DEBUG \+ DE-DUPLICATION reconstructs candle objects with explicit field list that excludes median\_volume\_1h and median\_volume\_2h. Node even logs 'Records with median\_volume\_2h: 0'. VOLUME SCORE CALCULATOR falls back to cs\_volume/24 estimation.

**WHAT:**

Add median\_volume\_1h and median\_volume\_2h to the explicit field list in the validCandles push block.

**WHERE:**

Row 2, DEBUG \+ DE-DUPLICATION node, inside the validCandles.push({json:{...}}) construction block.

**HOW:**

* Output object for each valid candle must include median\_volume\_1h and median\_volume\_2h.

* Both values read from incoming candle item's json payload as attached by BINANCE CANDLE PROCESSOR.

* If either median field is absent or zero on incoming item, pass through as zero — do not default to null or omit.

* Log line 'Records with median\_volume\_2h' must show count \> 0 after fix — zero count is test failure.

**QA Validation:**

After fix, 'Records with median\_volume\_2h' log must show count \> 0\. Assert at least 15 of 20 symbols have non-zero median\_volume\_1h reaching VOLUME SCORE CALCULATOR.

**A-05  Candles Grouping & Latest 20 Mixes Intervals — SMA Corrupted**

**Problem Summary:**

Candles Grouping groups all intervals (2h+1h+15m+1m) by symbol only. Latest 20 by open\_time is dominated by 1m and 15m candles. SMA 20 Calculation receives multi-interval mixed set — mathematically meaningless value.

**WHAT:**

Filter input to only 2h interval candles before grouping and taking the latest 20\.

**WHERE:**

Row 2, Candles Grouping & Latest 20 per Symbol node, before the grouped Map construction.

**HOW:**

* Before any grouping logic, filter incoming candle items to only those where interval equals '2h'.

* All 1h, 15m, and 1m candles excluded from this node entirely.

* Grouping by symbol and taking latest 20 by open\_time then operates only on 2h candles.

* 2h candles already have limit 20 from Bulk Requests Generator.

**QA Validation:**

After the node, verify every candle item has interval equal to '2h'. Any other interval value present is a test failure.

**System Impact:**

Directly resolves A-06. SMA 20 Calculation will receive correct 20 2h candles.

**A-06  SMA 20 Skipped — Only 12 Candles Available**

**Problem Summary:**

Bulk Requests Generator sets limit:12 for 1h candles. SMA 20 Calculation requires exactly 20 and skips symbols with fewer. Result: sma\_20 \= null for all symbols every cycle.

**WHAT:**

After A-05 is implemented, 2h candles with limit 20 feed SMA — no change to Bulk Requests Generator needed. If 1h candles are used for SMA, increase 1h limit to minimum 20\.

**WHERE:**

Row 1, Bulk Requests Generator (only if 1h used for SMA). Row 2, SMA 20 Calculation — verify it reads interval='2h' after A-05 fix.

**HOW:**

* Authoritative resolution: after A-05, the 2h candles with limit 20 feed SMA 20 Calculation.

* 1h limit of 12 remains appropriate — it is used for median volume calculation from 12 hours.

* SMA 20 Calculation must not skip symbols at 20-candle threshold if pipeline is correctly configured.

* New listings with fewer than 20 2h candles: SMA is skipped — acceptable. Downstream Merge must treat null SMA as missing data, not zero.

**QA Validation:**

After fix, assert sma\_20 is non-null for at least 18 of 20 symbols per cycle.

**A-07  Cooldown after Batch 6 — setTimeout Unreliable in N8N Code Node**

**Problem Summary:**

Cooldown after Batch 6 uses 30-second setTimeout inside a Code node. N8N Cloud Code node execution timeout is typically 10 seconds. 30s setTimeout may be killed before resolve — cooldown silently does not fire. TAAPI rate limit hit from batch 7+.

**WHAT:**

Remove setTimeout-based cooldown from Code node. Replace with N8N native Wait node.

**WHERE:**

Row 2, loop body between Cooldown after Batch 6 and HTTP POST TAAPI BULK node.

**HOW:**

* Place an N8N Wait node at the same position in the loop body.

* Configure Wait node to pause 30 seconds when loop currentRunIndex equals 6\.

* Configure secondary conditional pause of 20 seconds at index 12\.

* Wait node must be conditional — activates only at specified batch indices, not every iteration.

* If N8N Wait node does not support conditional execution natively, use an IF node before Wait that routes batch 6 through Wait path and all others through pass-through.

**QA Validation:**

Check N8N execution timeline logs. Batch 7 must not begin until at least 30 seconds after batch 6 completes. Loop must complete all batches without TAAPI 429 errors.

**A-08  Duplicate Binance Call in Validate 72h History**

**Problem Summary:**

Validate 72h History makes a separate HTTP request to Binance for 36x2h candles for each of Top 50 symbols. Bulk Requests Generator then requests same 2h data for Top 20\. 50+ extra Binance API calls per cycle — rate limit risk.

**WHAT:**

Reduce validation request to a minimal existence check (1 candle only) instead of fetching 36\.

**WHERE:**

Row 1, Validate 72h History node, the httpRequest configuration.

**HOW:**

* Change validation request limit parameter from 36 to 1\.

* Symbol passes 72h validation if API returns non-empty array for 2h interval — one candle confirms endpoint is active.

* Count-based validation (response.length \>= 36\) replaced with: response is non-empty array with at least 1 element.

* Reduces Binance API calls by approximately 35 per validation per symbol.

**Edge Cases:**

Symbol with only 1-2 candles passes validation but fails later in scoring — acceptable, deeper validation happens downstream.

**A-09  ASSET TIER CALCULATOR — Boundaries Wrong for Top 20 Context**

**Problem Summary:**

Code defines Tier 1 \= rank 1-10, Tier 2 \= rank 11-40, Tier 3 \= rank 41+. With 20 symbols, Tier 3 is never assigned. Rank 16-20 receive Tier 2 parameters: SL 2.0x, ATR thresholds 6-10%, R/R floor 2.0 — instead of correct Tier 3 values (SL 2.5x, 10-15%, R/R 2.5). Stoploss hunt risk on small altcoins.

**WHAT:**

Update tier boundary definitions and their associated parameter configurations to match Top 20 system design.

**WHERE:**

Row 3, ASSET TIER CALCULATOR node, TIER\_CONFIG object and assignTier function. Also ATR Volatility Analyzer2 hardcoded thresholds must match.

**HOW:**

* Tier 1: rank 1-5 inclusive. ATR threshold low=3%, high=6%. SL multiplier=1.5x. R/R floor=1.5. Max leverage=10x.

* Tier 2: rank 6-15 inclusive. ATR threshold low=6%, high=10%. SL multiplier=2.0x. R/R floor=2.0. Max leverage=7x.

* Tier 3: rank 16-20 inclusive. ATR threshold low=10%, high=15%. SL multiplier=2.5x. R/R floor=2.5. Max leverage=5x.

* Any rank outside 1-20 defaults to Tier 3 as conservative fallback.

* If rank\_position is null or NaN, assign Tier 3\.

**QA Validation:**

Run a cycle and verify symbols ranked 16-20 receive tier=3, atr\_threshold\_low=10, atr\_threshold\_high=15, SL multiplier 2.5 in TP-SL Calculator output.

**System Impact:**

SL distances will increase for rank 16-20 symbols. Some signals that previously passed Hard Filters from rank 16-20 may now be correctly rejected.

**A-10  Merge Node — market\_condition and Weights Without COALESCE**

**Problem Summary:**

In Row 3 Merge SQL, market\_condition, adx\_strength, and all weight fields are taken directly from input1 without COALESCE. If ADX/Adaptive Weights branch fails, these fields are null and Score Aggregator silently uses default weights without signaling failure.

**WHAT:**

Add explicit null detection for weight fields in Score Aggregator. Halt or flag the signal if critical weighting data is absent.

**WHERE:**

Row 3, SCORE AGGREGATOR node, STEP 2 weight extraction block.

**HOW:**

* After extracting all five weight fields: check that all are non-null and greater than zero.

* If any weight field is null or zero, the signal must not proceed to weighted scoring — mark with WEIGHTS\_MISSING flag and exclude from output.

* Fallback to default weights (25/25/20/20/10) must be removed — silent fallback hides failures.

* In Merge SQL: add COALESCE with sentinel value (-1) for market\_condition so null is distinguishable from valid 'UNKNOWN'.

**QA Validation:**

Simulate Branch 2 returning zero results. Verify Score Aggregator outputs zero valid signals rather than signals with silent default weights.

**T-01  TP-SL CALCULATOR — Leverage Calculation Duplicated and Wrong**

**Problem Summary:**

TP-SL CALCULATOR calculates suggestedLeverage using hardcoded value 10 with unclear semantics. RISK-REWARD FILTER recalculates and overwrites it. For Tier 1 with typical SL distances, TP-SL calculation produces 1x leverage for all Tier 1 signals.

**WHAT:**

Remove leverage calculation entirely from TP-SL CALCULATOR. Correct target risk percentages in RISK-REWARD FILTER.

**WHERE:**

Row 4, TP-SL CALCULATOR (remove field). Row 4, RISK-REWARD FILTER (update targetRiskPct values).

**HOW:**

* TP-SL CALCULATOR must output only TP/SL price levels, distances, R/R ratios, and strategy metadata — no leverage field.

* In RISK-REWARD FILTER, leverage formula: floor(targetRiskPct / slDistancePct), minimum 1x, maximum per tier.

* Target risk percentages: Tier 1 \= 2.0%, Tier 2 \= 1.5%, Tier 3 \= 1.0%.

* Example: BTC with slDistancePct=0.83%: floor(2.0/0.83) \= 2x. Realistic for BTC.

* Max caps: Tier 1 \= 10x, Tier 2 \= 7x, Tier 3 \= 5x.

* If slDistancePct is zero (ATR failure): leverage \= 0, mark tpsl\_calculated=false — caught by entry\_calculated guard.

**QA Validation:**

For BTC signal with ATR=50 USDT, price=60000 USDT: slDistancePct \= (50x1.5)/60000x100 \= 0.125%. Expected leverage \= min(floor(2.0/0.125), 10\) \= 10x. Must not produce 1x.

**T-02  MOMENTUM SCORE CALCULATOR — Direction-Blind Scoring**

**Problem Summary:**

calculateMomentumScore awards points for bullish RSI without knowing signal\_direction. For SHORT signals: RSI=60 earns maximum 40/40 points — but RSI\>60 for SHORT is a contra-signal. ARCHITECTURAL CONSTRAINT: signal\_direction is computed inside TREND SCORE CALCULATOR, which runs as a parallel sibling branch to MOMENTUM SCORE CALCULATOR. Both receive the same data from Restore Full Data After Tier Insert. signal\_direction does not exist in the input data at the time MOMENTUM runs — the original directive to “pass signal\_direction into the function” was architecturally invalid as stated.

**WHAT:**

Two valid approaches exist depending on how much structural change is acceptable. Both are described. The choice must be made before implementation begins.

**WHERE:**

Option A: Row 3, SCORE AGGREGATOR — apply direction-aware correction after the Merge node, where both momentum\_score and trend\_direction are available simultaneously. Option B: Row 3, MOMENTUM SCORE CALCULATOR — derive provisional direction from upstream proxy indicators already present in the input data (macd\_histogram\_2h and EMA alignment).

**HOW:**

* OPTION A — Correction in SCORE AGGREGATOR (preferred, no branch restructuring needed): After the Merge node, SCORE AGGREGATOR has both momentum\_score (from MOMENTUM branch) and trend\_direction (from TREND branch) available in the same data object. Apply direction-aware momentum correction here: if trend\_direction is SHORT and momentum\_score is above 60 (indicating bullish RSI conditions), reduce the weighted momentum contribution by multiplying it by a correction factor of 0.5 before adding it to total\_score. If trend\_direction is LONG and momentum\_score is below 40 (indicating bearish RSI conditions), apply the same 0.5 correction. This correction is applied to the weighted contribution (momentum\_score x weight\_momentum), not to momentum\_score itself — preserving the raw score for audit purposes.

* OPTION B — Proxy direction in MOMENTUM SCORE CALCULATOR (more changes, earlier correction): Derive provisional direction from indicators already present in Restore Full Data After Tier Insert output: if macd\_histogram\_2h \> 0 AND close\_price \> ema\_20\_2h, treat provisional direction as LONG. If macd\_histogram\_2h \< 0 AND close\_price \< ema\_20\_2h, treat as SHORT. If the two disagree, treat as NEUTRAL (no direction adjustment). Apply this provisional direction in calculateMomentumScore using the same inversion rules described below. Limitation: this proxy will disagree with the authoritative trend\_direction from TREND branch in \~15-20% of cases (when MACD and EMA conflict with each other or with ADX). It is a best-effort approximation, not an exact match.

* DIRECTION INVERSION RULES (same for both options): For SHORT direction — RSI average \<= 40 earns maximum RSI points. RSI average \> 50 earns maximum 5 points. StochRSI: oversold (k \<= 20\) earns max 30 points; overbought (k \>= 80\) earns 5 points. Williams %R: oversold (-100 to \-80) earns max points; overbought (-20 to 0\) earns minimum. For NEUTRAL direction: current symmetric scoring applies unchanged.

* DECISION REQUIRED before implementation: Option A is architecturally cleaner and requires changes only in SCORE AGGREGATOR. Option B requires changes in MOMENTUM SCORE CALCULATOR but produces a correction earlier in the pipeline and keeps score components more meaningful individually. If the pipeline is ever refactored to run TREND before the parallel split, Option B becomes exactly correct — making it the better long-term choice despite the current proxy approximation.

**QA Validation:**

SHORT signal with RSI\_2h=70, RSI\_1h=65 and trend\_direction=SHORT: under Option A, weighted momentum contribution must be reduced by 50% in SCORE AGGREGATOR. Under Option B, proxy direction (SHORT from MACD+EMA) triggers inversion in MOMENTUM SCORE CALCULATOR — resulting momentum\_score must be below 40\. SHORT signal with RSI\_2h=35, RSI\_1h=38: momentum\_score must be above 65 under both options.

**System Impact:**

Option A: changes only SCORE AGGREGATOR — no impact on individual branch score outputs. Option B: changes MOMENTUM SCORE CALCULATOR — momentum\_score values will shift for SHORT signals, affecting Score Aggregator input and coherence check trigger frequency. In both cases: total\_score for SHORT signals with bullish momentum indicators will decrease on average — this is the correct behavior.

**T-03  VOLUME SCORE CALCULATOR — OBV Scoring Direction-Blind**

**Problem Summary:**

OBV threshold of 1,000,000 awards maximum score automatically for all mid/large caps. For SHORT: high OBV (buying pressure) is a contra-signal but receives maximum 30/100 points. Systematically inflates volume score for SHORT signals. ARCHITECTURAL CONSTRAINT: Same parallel branch problem as T-02 — VOLUME SCORE CALCULATOR runs in Branch 5, TREND SCORE CALCULATOR runs in Branch 4\. signal\_direction is not available in the input data to VOLUME SCORE CALCULATOR at runtime.

**WHAT:**

Same two options as T-02. The preferred fix (Option A) is in SCORE AGGREGATOR after the Merge. The alternative (Option B) uses a proxy direction from macd\_histogram\_2h and EMA alignment available in VOLUME SCORE CALCULATOR input.

**WHERE:**

Option A: Row 3, SCORE AGGREGATOR — apply OBV direction correction to weighted\_volume contribution after Merge. Option B: Row 3, VOLUME SCORE CALCULATOR, COMPONENT 2: OBV ANALYSIS block — use same proxy direction logic as T-02 Option B.

**HOW:**

* OPTION A — Correction in SCORE AGGREGATOR: After Merge, both volume\_score and trend\_direction are available. If trend\_direction is SHORT and obv\_1h is positive and above 500,000 (indicating net buying pressure), reduce the weighted volume contribution by multiplying it by 0.6 before adding to total\_score. If trend\_direction is LONG and obv\_1h is negative and below \-500,000, apply the same 0.6 reduction. This targets only the OBV sub-component of the volume score — it does not touch MFI or volume tier scoring. Limitation: volume\_score is a composite of OBV \+ MFI \+ volume tier; the SCORE AGGREGATOR correction is approximate since it adjusts the full weighted\_volume, not just the OBV sub-component.

* OPTION B — OBV direction in VOLUME SCORE CALCULATOR: Derive proxy direction from macd\_histogram\_2h and ema alignment (same proxy as T-02 Option B). Apply to OBV scoring: LONG-confirming \= positive OBV earns max points, negative OBV earns 5/30. SHORT-confirming \= negative OBV earns max points, positive OBV earns 5/30. OBV near zero (between \-500,000 and \+500,000) is ambiguous — award 15/30 regardless of direction. This corrects only the OBV sub-component, leaving MFI and volume tier scoring untouched.

* DECISION REQUIRED: T-02 and T-03 must use the SAME option (both A or both B) to keep the correction logic in one place. Mixing them creates two separate correction mechanisms that are hard to maintain and audit. Option B is more precise for OBV (corrects only the right sub-component) but requires proxy direction. Option A is cruder for OBV (adjusts full weighted\_volume) but is architecturally cleaner.

**QA Validation:**

SHORT signal with OBV=5,000,000 and trend\_direction=SHORT: under Option A, weighted\_volume in total\_score must be reduced. Under Option B, OBV sub-component must score 5/30. SHORT signal with OBV=-2,000,000: OBV sub-component must score 25-30/30 under both options.

**T-04  TREND SCORE CALCULATOR — EMA Block Nested Inside MACD if-Block**

**Problem Summary:**

COMPONENT 3 (EMA Alignment, 30 points) is physically nested inside the MACD if-block. When MACD data is absent: EMA component skipped, maxScore remains 40, formula produces trend\_score \= 40/40 \= 100\. Symbol with ADX=30 and no MACD/EMA gets trend\_score=100 — signal passes Hard Filters with corrupt data.

**WHAT:**

Move EMA Alignment block outside the MACD if-block so it executes independently.

**WHERE:**

Row 3, TREND SCORE CALCULATOR, calculateTrendScore function. The closing brace of the MACD if-block must come before the EMA Alignment section begins.

**HOW:**

* Three independent conditional blocks must exist: ADX (if adx\_2h \> 0), MACD (if macd data non-zero), EMA (if ema\_20\_2h \> 0 and close\_price \> 0).

* Each block adds to maxScore only if its data is available.

* MACD missing, EMA present: maxScore \= 70 (ADX 40 \+ EMA 30). totalScore from ADX and EMA determines score.

* Both MACD and EMA missing: maxScore \= 40, trend\_score reflects ADX contribution only.

* All three components missing: maxScore \= 0 — guard: return trend\_score=0, trend\_direction='NEUTRAL'.

**QA Validation:**

Test: macd\_value\_2h=0, macd\_signal\_2h=0, ema\_20\_2h=valid, adx\_2h=28. Expected: EMA block executes, maxScore=70, trend\_score is not 100\.

**System Impact:**

Inflated trend\_scores during TAAPI partial failures will be eliminated. Some signals that previously passed Hard Filters due to trend\_score=100 will now be correctly rejected.

**T-05  TP1 Ratio 1:1 — Negative Expected Value at Leverage**

**Problem Summary:**

tp\_ratios\[0\] \= 1.0 for all strategies. After fees of 0.11% total, fee-adjusted R/R for TP1 ≈ 0.89. 40-60% of the position closes at net loss on every trade. At 5x leverage with 40% TP1 allocation and 50% win rate: net loss after fees is systematic.

**WHAT:**

Increase minimum TP1 ratio to ensure positive fee-adjusted expected value.

**WHERE:**

Row 4, TP-SL CALCULATOR, getDynamicAllocation function, tp\_ratios array first element.

**HOW:**

* STRONG\_TREND strategy: TP1 ratio \= 1.5 (currently 1.0).

* MODERATE\_TREND strategy: TP1 ratio \= 1.3 (currently 1.0).

* WEAK\_RANGING strategy: TP1 ratio \= 1.2 (currently 1.0).

* Verification: TP1 at 1.5x risk for Tier 1 BTC: reward \= 112.5 USDT vs fees ≈ 66 USDT. Positive EV confirmed.

* TP2 and TP3 ratios remain unchanged (2.0 and tier-adjusted 2.5-4.5).

* Optional: reduce TP1 allocation in WEAK\_RANGING from 60% to 50% to allow more position to run to TP2.

**QA Validation:**

Calculate fee-adjusted R/R for TP1 across all tier/strategy combinations after fix. All results must be \> 1.0.

**System Impact:**

TP distances increase. ENTRY ZONE VALIDATOR's TP clearance check (minimum 0.5%) will pass more easily with larger TP distances.

**T-06  Price Action Score — Uses 1h Close Instead of 1m Price for VWAP**

**Problem Summary:**

Price Action Score Calculator uses data.close\_price (1h candle close) for VWAP distance calculation. 1m latest price can differ by 0.5-2% during volatile periods — sufficient to misclassify VWAP zones, especially the chop zone threshold of 0.3%.

**WHAT:**

Replace close\_price with latest\_1m\_price for VWAP distance calculation in Price Action Score Calculator.

**WHERE:**

Row 3, Price Action Score Calculator, COMPONENT 1: VWAP ANALYSIS block. The price variable used for vwapDistance calculation.

**HOW:**

* Price used for vwapDistance must be latest\_1m\_price if available and \> 0\.

* Fallback priority: latest\_1m\_price → close\_price (1h close) → reject component (0 points for VWAP if no valid price).

* Same price must be used consistently for all comparisons within VWAP component.

* Candle structure analysis (COMPONENT 2\) continues to use 1h OHLC data — not the 1m price.

* EMA20 positioning (COMPONENT 3\) continues to use close\_price for candle context consistency.

* Staleness check: if |cycle\_timestamp \- 1m candle open\_time| \> 300 seconds, treat 1m price as unavailable and fall back.

**QA Validation:**

Verify latest\_1m\_price is present in input data reaching Price Action Score Calculator. Check a volatile rank 16-20 symbol and confirm 1m price changes VWAP zone classification vs 1h close.

**T-07  HARD FILTERS ENFORCER — R/R Double-Check Logic Ambiguous**

**Problem Summary:**

R/R check: passed \= rrFilterPassed AND feeAdjustedRR \>= tierMinRR. If upstream flag is false but numeric R/R is valid (edge case at N8N merge error), signal is rejected despite correct R/R. Logic is confusing during debugging.

**WHAT:**

Simplify R/R check to use only numeric fee\_adjusted\_rr against tier-specific floor.

**WHERE:**

Row 4, HARD FILTERS ENFORCER, risk\_reward filter check definition.

**HOW:**

* Passed condition for risk\_reward: fee\_adjusted\_rr \>= tier-specific minimum R/R.

* Tier minimums: Tier 1 \= 1.5, Tier 2 \= 2.0, Tier 3 \= 2.5.

* The rr\_filter\_passed boolean flag is redundant and must be removed from the condition.

* Check must still verify tpsl\_calculated \= true before evaluating R/R (no TP/SL data \= R/R cannot be trusted).

* If fee\_adjusted\_rr is NaN or null: treat as 0 — will always fail tier floor check.

**QA Validation:**

Test: rr\_filter\_passed=false, fee\_adjusted\_rr=3.0, tpsl\_calculated=true, tier=2. Expected: signal passes R/R check (3.0 \>= 2.0).

**T-08  Dual volatility\_score — Non-Deterministic Scoring Path**

**Problem Summary:**

Two nodes calculate volatility\_score with different logic: ATR Volatility Analyzer2 (4-level) and Volatility Score Calculator1 (tier-aware ATR \+ BBW). Restore Full Data After Tier Insert overrides with DB-saved value from first node. Tier-aware BBW scoring may be silently discarded.

**WHAT:**

Designate Volatility Score Calculator1 as single authoritative volatility scorer. Remove volatility\_score from ATR Volatility Analyzer2. Prevent Restore node from overwriting Branch 3 score.

**WHERE:**

Row 3, ATR Volatility Analyzer2 (remove volatility\_score). Row 3, Restore Full Data After Tier Insert (do not copy volatility\_score from tierData).

**HOW:**

* ATR Volatility Analyzer2 must continue to output: volatility\_status, volatility\_warning, atr\_percentage\_1h, current\_atr\_1h, risk\_level, max\_suggested\_leverage.

* ATR Volatility Analyzer2 must NOT output: volatility\_score (the numeric 0-100 value).

* Volatility Score Calculator1 (Branch 3\) is sole producer of volatility\_score.

* In Restore Full Data, merge must include all tierData fields EXCEPT volatility\_score.

* If Volatility Score Calculator1 fails for a symbol: volatility\_score is null in Merge — Score Aggregator treats as 0 and logs missing data.

**QA Validation:**

After fix, log which node produced volatility\_score that reaches Score Aggregator. Confirm it is always from Volatility Score Calculator1, never from ATR Volatility Analyzer2.

**T-09  SIGNAL RANKING — Tier Diversification Score-Blind**

**Problem Summary:**

Tier diversification forces up to 2 Tier 3 signals regardless of scores. A Tier 3 signal scoring 56 can displace a Tier 2 signal scoring 72\. At 3x-5x leverage, this is direct user risk.

**WHAT:**

Add minimum score threshold below which a tier slot is not forcibly filled.

**WHERE:**

Row 4, SIGNAL RANKING & TOP 5 SELECTION, tier diversification logic block.

**HOW:**

* Before including any signal in selection, check its total\_score against minimum threshold relative to already-selected signals.

* Rule: a Tier 3 signal is only included if total\_score \>= (average score of already-selected signals) minus 15 points.

* If no higher-tier signals are selected yet, threshold is the absolute Hard Filters floor for that tier.

* If Tier 3 candidate does not meet threshold, skip it — do not fill the tier slot.

* Output fewer than 5 signals if needed — do not force inclusion.

* Exception: if only Tier 3 signals pass all Hard Filters in a cycle, include them regardless.

**QA Validation:**

Scenario: 4 Tier 2 signals at 80/78/75/72, 1 Tier 3 at 56\. Average of first two selected \= 79\. Threshold \= 64\. Score 56 \< 64\. Expected: 4 signals output (Tier 2 only).

**T-10  BBW Thresholds Not Tier-Aware — Tier 1 Structurally Underscored**

**Problem Summary:**

Volatility Score Calculator1 uses fixed BBW thresholds (\<=0.02=LOW, \<=0.05=OPTIMAL) regardless of tier. BTC structurally operates at lower BBW values than altcoins. BTC at BBW=0.02 receives 25pts (LOW), altcoin at BBW=0.04 receives 40pts (OPTIMAL).

**WHAT:**

Make BBW scoring thresholds tier-aware.

**WHERE:**

Row 3, Volatility Score Calculator1, Bollinger Bands Width (40 points max) section.

**HOW:**

* Before scoring BBW, determine tier from input data.

* Tier 1: squeeze (LOW) \<= 0.008, optimal \<= 0.015, elevated \<= 0.025, extreme \> 0.025.

* Tier 2: squeeze \<= 0.015, optimal \<= 0.04, elevated \<= 0.07, extreme \> 0.07.

* Tier 3: squeeze \<= 0.025, optimal \<= 0.06, elevated \<= 0.10, extreme \> 0.10.

* Scoring points per zone remain same (25/40/30/15) but applied against tier-correct thresholds.

* If tier missing or null: use Tier 2 thresholds as conservative default.

* If bbw\_1h is zero or NaN: skip this component — add 0 to both totalScore and maxScore.

**QA Validation:**

Calculate average BBW for BTC and a Tier 3 altcoin from a real cycle. Confirm both receive approximately 30-40 points (OPTIMAL zone) under new tier-aware thresholds.

**System Impact:**

Tier 1 volatility scores will increase on average. More high-quality Tier 1 signals may pass Hard Filters.

# **SECTION 3 — PIPELINE HARDENING RULES**

* Pipeline must not proceed past Row 1 if fewer than 10 symbols have all 4 required intervals (2h, 1h, 15m, 1m) marked as COMPLETE. Cycle with fewer than 10 valid symbols produces a scan-incomplete Telegram notification.

* Row 2 must not proceed to TAAPI batch processing if the candle data contains zero symbols with non-null median\_volume\_1h. This indicates A-04 or A-05 failure — scoring results will be unreliable.

* Score Aggregator must validate that all five component scores and all five weight fields are non-null before executing weighted sum. If any single field is null for a given symbol, that symbol must be excluded from output and logged.

* Hard Filters Enforcer must never output an error object into the pipeline to Signal Ranking. All error states must produce a clean no-signal notification object with telegram\_message\_type \= 'NO\_SIGNALS'.

* Every node that reads from a cross-row reference ($('NodeName').all()) must include an explicit length check. If the referenced node returns zero items, the current node must return an UPSTREAM\_DATA\_MISSING error object and halt processing for that branch.

# **SECTION 4 — DATA VALIDATION LAYER**

## **Symbol Rejection Criteria at Row 1 Exit**

* Symbol must have exactly 4 interval groups (2h, 1h, 15m, 1m).

* Symbol must have at least 18 candles in the 2h group.

* Symbol must have non-zero volume in at least 10 of the 1h candles used for median calculation.

## **Price Consistency Check at Row 3 Entry**

* latest\_1m\_price must be within 5% of close\_price (1h close). If deviation exceeds 5%, log HIGH\_PRICE\_DIVERGENCE flag on the symbol. Do not reject — ensure Price Action scoring uses 1m price (per T-06 fix).

* If latest\_1m\_price is zero or null, fall back to close\_price AND flag symbol as NO\_1M\_PRICE. Signals from flagged symbols must display a warning note in Telegram output.

## **TAAPI Data Freshness**

* All TAAPI indicators carry backtrack of 1 (last completed candle). This is intentional and correct — no validation change needed.

* If any indicator field (rsi\_2h, adx\_2h, etc.) arrives as null from TAAPI Response Processor for a symbol, that symbol must be excluded from scoring for that cycle and logged as TAAPI\_PARTIAL\_FAILURE.

## **Volume Ratio Baseline Integrity**

* If median\_volume\_1h is zero after A-04 fix, VOLUME SCORE CALCULATOR must use cs\_volume/24 as fallback AND log the fallback usage. Signals from this symbol must not be additionally penalized beyond normal graduated scale.

# **SECTION 5 — SCORING CORRECTIONS SUMMARY**

## **Input Selection After All Fixes**

* Momentum: RSI\_2h, RSI\_1h, StochRSI\_1h, WillR\_2h — direction-aware (T-02).

* Trend: ADX\_2h, MACD\_2h \+ 1h histogram, EMA\_20/50\_2h as independent components (T-04).

* Volatility: ATR\_1h and BBW\_1h with tier-aware thresholds, single source (T-08, T-10).

* Volume: cs\_volume tier buckets, OBV with direction awareness (T-03), MFI\_2h.

* Price Action: latest\_1m\_price for VWAP distance (T-06), 1h OHLC for candle structure, EMA\_20\_1h for positioning.

## **Weight Integrity**

* All five weights must sum to 1.0 before application. Score Aggregator normalization is correct and must remain.

* Null weights must halt scoring — not trigger silent fallback (A-10).

* Coherence check: |momentum\_score \- trend\_score| \> 20 → penalty \-15 remains as designed. After T-02 fix, will trigger more appropriately.

# **SECTION 6 — RISK AND TRADE SAFETY RULES**

* TP1 must achieve fee-adjusted R/R \> 1.0 (guaranteed at ratio 1.2 minimum after T-05 fix).

* Weighted R/R across TP1/TP2/TP3 by allocation must be \>= tier floor (1.5/2.0/2.5) for signal to pass Hard Filters.

* Leverage formula: floor(targetRiskPct / slDistancePct). targetRiskPct: Tier 1=2.0%, Tier 2=1.5%, Tier 3=1.0%. Hard caps: Tier 1=10x, Tier 2=7x, Tier 3=5x. Minimum: 1x.

* If slDistancePct is zero: leverage \= 0, signal excluded. This is the ATR=0 failure case.

* Minimum slDistancePct guard: if slDistancePct \< 0.3%, the calculated SL is dangerously close to entry given fees. Add this guard in HARD FILTERS ENFORCER or TP-SL CALCULATOR — reject such signals.

# **SECTION 7 — FAILURE MODES AND PROTECTIONS**

## **Binance API Returns Partial Candle Set**

* Prevention: Completeness check in GROUP CANDLE RESPONSES already exists. Symbol marked INCOMPLETE is excluded from TAAPI.

* Detection: Log line 'INCOMPLETE' symbols count \> 0 in GROUP CANDLE RESPONSES.

## **TAAPI Bulk Request Timeout**

* Prevention: TAAPI RESPONSE PROCESSOR skips items with no taapiArray. Those symbols receive no indicator data — excluded with TAAPI\_PARTIAL\_FAILURE flag.

* Detection: allResults.length in TAAPI RESPONSE PROCESSOR is less than batch size.

## **scan\_cycle\_id Mismatch — Row 3 Fetch Returns Zero Results**

* Prevention: After A-02 fix, single-source scan\_cycle\_id prevents mismatch.

* Detection: Fetch Data AFTER TAAPI returns 0 items despite successful Row 2 execution. Log and alert.

## **All 20 Signals Rejected by Hard Filters**

* Prevention: Dynamic tier-aware floors are already lenient at low end (50 points for Tier 3 in ranging market). Total rejection is valid in low-quality market conditions.

* Detection: Hard Filters Enforcer outputs a NO\_SIGNALS object — Signal Ranking produces Telegram NO\_SIGNALS message. Correct behavior.

## **ATR \= 0 (atr\_1h Missing or Zero)**

* Prevention: entry\_calculated guard (Filter 5 in Hard Filters Enforcer) catches this. Signal is rejected.

* Detection: entry\_calculated \= false in Hard Filters input.

# **SECTION 8 — DEPLOYMENT PLAN**

## **Phase 1 — Critical Safety and Structural Fixes (P0)**

1. A-01: Rotate TAAPI key. Configure N8N Credential. Update Separation of Requests.

2. T-04: Fix EMA block brace placement in TREND SCORE CALCULATOR.

3. A-09: Update tier boundaries in ASSET TIER CALCULATOR.

4. A-05: Filter to '2h' interval in Candles Grouping & Latest 20 per Symbol.

5. A-03: Implement content-based response matching in GROUP CANDLE RESPONSES.

## **Phase 2 — Data Integrity (P1 Architectural)**

6. A-02: Centralize scan\_cycle\_id in Crypto Symbols Metadata.

7. A-04: Add median volume fields to De-duplication output.

8. A-06: Verify SMA receives 2h candles after A-05 fix.

## **Phase 3 — Scoring Fixes (P1 Trading Logic)**

9. T-02: Direction-aware momentum scoring.

10. T-06: Use latest\_1m\_price in Price Action VWAP calculation.

11. T-01: Remove leverage from TP-SL Calculator. Fix targetRiskPct in R/R Filter.

12. T-05: Update TP1 ratios to 1.2/1.3/1.5.

## **Phase 4 — Remaining P1 and P2 Fixes**

13. T-08: Remove volatility\_score from ATR Volatility Analyzer2.

14. T-03: Direction-aware OBV scoring.

15. A-07: Replace setTimeout with N8N Wait node.

16. T-07: Simplify R/R double-check in Hard Filters.

17. A-08: Reduce Validate 72h History to limit 1\.

18. T-09: Add minimum score threshold for tier diversification.

19. A-10: Add null weight detection in Score Aggregator.

20. T-10: Tier-aware BBW thresholds in Volatility Score Calculator.

## **Monitoring Signals After Deployment**

* First 3 cycles: log all filter rejection counts per filter type and compare to pre-fix baseline.

* Watch for: zero-output cycles — investigate if occurring more than 1 in 5 cycles.

* Watch for: trend\_score=100 occurrences — must be zero after T-04 fix.

* Watch for: sma\_20=null count per cycle — must be 0-2 after A-05/A-06 fix.

## **Rollback Triggers**

* If cycle produces zero signals in 3 consecutive cycles after Phase 3 deployment: revert T-02 (direction-aware momentum) as most likely cause of signal drought.

* If TAAPI responses drop to \< 15 symbols per batch consistently: A-07 Wait node configuration is incorrect — revert and diagnose timing.

# **SECTION 9 — OPEN QUESTIONS**

**1\.**  A-03 resolution depends on whether N8N's HTTP Request node can pass request metadata (symbol, interval) through to the response object. Please confirm whether this is configurable in the current N8N version in use, or whether an alternative approach (individual HTTP nodes per symbol) is feasible.

**2\.**  A-02 requires scan\_cycle\_id generated in Crypto Symbols Metadata to be accessible in Bulk Requests Generator. Confirm that Bulk Requests Generator can reference Crypto Symbols Metadata output at execution time, or whether the ID must be passed through the item chain explicitly.

**3\.**  T-02 and T-03 parallel branch constraint is now addressed in the updated directives with two concrete options (A and B). A decision is required before implementation: Option A (correction in SCORE AGGREGATOR) vs Option B (proxy direction in individual calculators). Both T-02 and T-03 must use the same option. Please confirm which approach to implement.

**4\.**  T-09 tier diversification: should the system send 4 signals when the 5th slot cannot be filled by a quality Tier 3 candidate, or should it always send exactly 5 signals by relaxing the threshold? The current plan outputs 4 signals — please confirm this is acceptable for the Telegram channel audience.

**5\.**  raw\_candles\_data table has no defined cleanup policy. With 20 symbols x 4 intervals x multiple candles per 2-hour cycle, the table grows unboundedly. Please define a retention policy (e.g., keep last 30 days) to be implemented separately.

# **APPENDIX — PRIORITIZED ISSUE LIST**

| Priority | ID | Issue Name | Risk | Effort |
| :---- | :---- | :---- | :---- | :---- |
| **P0** | A-01 | TAAPI Secret key hardcoded in code | Compromised API credentials | Low |
| **P0** | T-04 | EMA block nested in MACD if | trend\_score=100 on missing data | Low |
| **P0** | A-09 | Tier boundaries wrong for Top 20 | Wrong SL/RR for rank 16-20 | Low |
| **P0** | A-03 | Positional response matching on retry | Silent symbol data swap | Med |
| **P0** | A-05 | Candles Grouping mixes intervals | SMA calculated from 1m candles | Low |
| **P1** | T-05 | TP1 ratio 1:1 negative EV | Systematically losing TP1 at leverage | Med |
| **P1** | A-02 | Dual scan\_cycle\_id race condition | Data corruption in DB | Med |
| **P1** | T-01 | Duplicate leverage calculation | 1x leverage for all Tier 1 | Low |
| **P1** | T-02 | Momentum scorer direction-blind | Inflated score for contra-trend SHORT | Med |
| **P1** | A-04 | De-duplication drops median volumes | Volume ratio estimation error | Low |
| **P1** | A-06 | SMA 20 skipped at 12 candles | Null SMA for all symbols | Low |
| **P1** | T-06 | Price Action uses 1h close not 1m | Wrong VWAP distance category | Low |
| **P2** | T-08 | Dual volatility\_score non-deterministic | Unclear scoring path | Med |
| **P2** | T-03 | OBV direction-blind | Inflated volume score for SHORT | Med |
| **P2** | A-07 | setTimeout unreliable in N8N Code node | TAAPI cooldown may not trigger | Low |
| **P2** | T-07 | R/R double-check logic ambiguous | Minor bypass risk on edge case | Low |
| **P2** | A-08 | Duplicate Binance call in Validate | Rate limit risk | Med |
| **P2** | T-09 | Tier diversification score-blind | Weak Tier 3 over strong Tier 2 | Low |
| **P2** | A-10 | market\_condition no COALESCE in Merge | Silent null on Branch 2 failure | Low |
| **P2** | T-10 | BBW thresholds not tier-aware | Tier 1 underscored in volatility | Low |

