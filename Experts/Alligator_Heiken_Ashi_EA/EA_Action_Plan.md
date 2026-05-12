# Alligator + Heiken Ashi EA — Complete Action Plan

**Target Platform:** MetaTrader 5 (MQL5)
**Target Account:** FTMO Swing 2-Step Challenge ($100,000 default)
**Target Performance:** 3-5% per month
**Last Updated:** 2026-05-03

---

## 1. Strategy Overview

### 1.1 Core Concept
Multi-timeframe trend-following EA that uses the Bill Williams Alligator on 15M for entry signals, supported by Heiken Ashi candles, with 1H/4H support/resistance for context and 1H Alligator as a soft directional filter.

### 1.2 Instruments Traded
- **Forex Majors:** EURUSD, GBPUSD, USDJPY, USDCHF, AUDUSD, USDCAD, NZDUSD
- **Metals:** XAUUSD (Gold)
- **Indices:** NAS100 (US Tech 100 / NASDAQ)

### 1.3 Timeframes Used
- **Entry Signal:** 15M (primary)
- **Heiken Ashi:** 15M (matches entry timeframe)
- **Soft Trend Filter:** 1H Alligator
- **Support/Resistance:** 1H + 4H (auto-built from swing points)
- **ADX Symbol Selection:** 1H

### 1.4 Indicators
- **Bill Williams Alligator** — standard settings: Jaw 13 SMMA shift 8, Teeth 8 SMMA shift 5, Lips 5 SMMA shift 3
- **Heiken Ashi** — 15M
- **ATR(14)** — 15M, used for separation/buffers/dead market detection
- **ADX(14)** — 1H, used for symbol prioritization
- **Custom S/R levels** — auto-detected swing highs/lows on 1H and 4H

---

## 2. Entry Logic

### 2.1 Entry Type A — Mouth Opens (Trend Initiation)

**Conditions (BUY):**
1. On the most recently closed 15M candle, Alligator lines are now in correct order: Lips > Teeth > Jaw
2. On the previous 15M candle, lines were NOT in this order (this is the "opening event")
3. Separation check: `(Lips − Jaw) > ATR_Mouth_Open_Multiplier × ATR(14)` (default 0.4 × ATR)
4. 1H soft filter: 1H Alligator is NOT in opposite-direction open mouth
5. All other filters pass (ADX, ATR ratio, S/R block, news, spread)

**Conditions (SELL):** Mirror — Lips < Teeth < Jaw, was not in that order on previous candle, separation check.

**Entry:** Market order at close of the candle that opened the mouth.

**Stop Loss:** Below Jaw line (BUY) or above Jaw line (SELL), buffered by `ATR_SL_Buffer × ATR(14)` (default 0.2 × ATR).

**Important:** Only ONE Type A signal per mouth-opening event. While the mouth stays open, no further Type A entries until mouth closes and reopens.

---

### 2.2 Entry Type B — Mouth Closed Breakout

**Conditions (BUY):**
1. 15M Alligator lines are tangled/sleeping (lines NOT in clean Lips>Teeth>Jaw or opposite order). Use a tolerance band: if lines are within `0.3 × ATR` of each other, consider tangled.
2. Last 2 closed 15M Heiken Ashi candles are both green (bullish)
3. The 2nd (most recent) HA candle has no lower wick (or wick ≤ `HA_Wick_Tolerance_Pips`, default 1 pip)
4. Both HA candles closed ABOVE all three Alligator lines
5. 1H soft filter: 1H Alligator NOT in opposite-direction open mouth
6. All other filters pass

**Conditions (SELL):** Mirror — both red HA candles, 2nd has no upper wick, closes below all three Alligator lines.

**Entry:** Market order at close of 2nd HA candle.

**Stop Loss:** Below the lowest low of last 5 closed 15M candles (BUY) or above highest high (SELL), buffered by `0.2 × ATR(14)`.

---

### 2.3 Position Sizing

For each entry, calculate lot size so that **risk = X% of current account equity**, where X depends on streak position:
- Position 1: 0.30%
- Position 2: 0.50%
- Position 3: 0.70%

**Formula:**
```
Risk_Amount = AccountEquity * Risk_Percent / 100
SL_Distance_Pips = abs(EntryPrice - StopLossPrice) / Point
Pip_Value_Per_Lot = (calculated per symbol via SymbolInfoDouble)
Lot_Size = Risk_Amount / (SL_Distance_Pips * Pip_Value_Per_Lot)
Lot_Size = NormalizeDouble to broker's lot step, min, max
```

Position size automatically adjusts so the SL distance does not change risk %.

---

## 3. Exit Logic

### 3.1 Initial TP Target
Set initial TP as the closer of:
- Nearest 1H/4H S/R level in trade direction (auto-detected — see Section 6)
- 2R from entry (where R = SL distance)

If no valid S/R within 5R distance, default to 2R.

### 3.2 Break-Even Move
When unrealized profit reaches **+1R**, move SL to:
- BUY: Entry price + `BE_Buffer_Pips` (default 2 pips)
- SELL: Entry price − `BE_Buffer_Pips`

This locks in safety. SL is never moved backward.

### 3.3 Trailing Stop (After BE)
Once SL has reached BE+, on every closed 15M candle:
- BUY: Calculate `New_SL = Lips_value − Trail_ATR_Buffer × ATR(14)` (default 0.3 × ATR)
- SELL: Calculate `New_SL = Lips_value + 0.3 × ATR`

If `New_SL` is more favorable than current SL, update. Never move SL backward.

### 3.4 Forced Exit Conditions
Exit immediately at market if:
- 15M candle closes on opposite side of Alligator Lips (full trend break)
- Trail SL is hit
- Friday 15:00 NY (force-close all open trades)
- Next NY session opens with this trade still alive (force-close at next NY open per Option A — see Section 5.5)

### 3.5 Order Type for Exits
- **TP/SL hits:** Use exact level (limit/stop orders attached to position)
- **Trail/forced exits:** Market order with slippage tolerance

---

## 4. Filters & Skip Conditions

### 4.1 Spread Filter
For each symbol, check spread before entry. If `current_spread > Spread_<SYMBOL>`, skip entry. All values are configurable inputs (see Section 9).

### 4.2 ATR Liquidity Filter (Dead Market Protection)
Calculate `ATR_Now = ATR(14) on 15M closed candle`. Calculate `ATR_Avg_20 = average of ATR(14) over past 20 closed candles`. If `ATR_Now < Min_ATR_Ratio × ATR_Avg_20` (default 0.5), market is dead → skip entry.

### 4.3 ADX Filter (Symbol-Day Skip)
Compute 1H ADX(14) for each symbol at NY session start. If ALL symbols have `ADX < Min_ADX_1H` (default 20), no trades that day. Otherwise, the symbol with highest 1H ADX is the priority symbol.

### 4.4 Symbol Prioritization (First Valid Signal Wins)
EA monitors all 9 symbols. When a valid entry signal appears on ANY symbol, take the trade immediately if all filters pass. Do not wait to compare with potential signals on other symbols.

### 4.5 News Filter
Use MT5 built-in economic calendar. Block entries 15 minutes before and 15 minutes after any **High-impact** news event for currencies in the symbol pair.
- For XAUUSD: USD news blocks
- For NAS100: USD news blocks
- For EURUSD: USD or EUR news blocks
- (etc. — apply to all relevant currencies)

Already-open trades are NOT closed; only new entries are blocked.

### 4.6 Tokyo Session Spread Skip
Skip first `Tokyo_Skip_First_Minutes` (default 30) of Tokyo session, when spreads are widest.

### 4.7 Same-Instrument Hedge Block (FTMO Compliance)
Before sending any order, check for any existing open position on the same symbol with the EA's Magic Number. If exists, REJECT new entry. No simultaneous opposite trades, no pyramiding. Only one position per symbol at a time.

### 4.8 S/R Block (Entry Filter)
For BUY signals: scan 1H and 4H S/R levels above entry price. If nearest overhead resistance is within `SR_Block_Distance_Pips` (default 10 pips), skip entry — not enough room to TP.

For SELL signals: mirror with overhead support.

---

## 5. Session Schedule & Streak Logic

### 5.1 Session Times (NY Local Time)
- **Tokyo:** 19:00 (prev day) — 04:00
- **London:** 03:00 — 12:00
- **New York:** 08:00 — 17:00 (EA trading window: **08:00 — 15:00**, last 2 hours skipped)

EA reads server time (GMT+2/GMT+3 CET) and converts to NY time internally.

### 5.2 Default Mode (Streak = 0)
Trade ONLY New York session (08:00 — 15:00 NY).
Skip Tokyo and London entirely.

### 5.3 Recovery Mode (Streak ≥ 1, No TP Yet in Cycle)
Expand trading window to ALL sessions (Tokyo + London + NY) until either:
- TP hits (cycle ends, no more trading until next NY)
- 3 consecutive SLs hit (streak resets, no more trading until next NY)

### 5.4 Cycle Definition
**One cycle = NY session start → next NY session start.**

At every NY session open:
- Streak counter resets to **Position 1**
- Recovery mode flag clears
- EA looks for fresh entry in NY

### 5.5 Trade Carryover (Option A — Force-Close at Next NY Open)
Trades run until SL/TP/trail closes them naturally, even across sessions and across CET midnight.

**EXCEPTION:** When the next NY session opens (08:00 NY) and a trade is STILL OPEN from the previous cycle:
1. Force-close that trade at market
2. Apply realized P/L to account
3. Result of force-close is irrelevant to streak (previous cycle already ended)
4. Begin new NY cycle with fresh Position 1

This guarantees clean separation between cycles.

### 5.6 Daily Loss Counter (FTMO Compliance Layer)
Independent of streak. Tracks % of equity lost since 00:00 CET (FTMO's daily reset).
- Hard rule: **never enter a trade if `current_day_loss + position_risk > Max_Daily_Loss` (default 1.50%)**
- This protects FTMO's 5% daily limit with a 3.5% safety buffer
- Counter resets at 00:00 CET automatically (broker server time)

### 5.7 Friday Close & Reset
At Friday 15:00 NY:
- Force-close all open trades
- Reset streak to Position 1
- Recovery mode flag cleared
- Monday begins with fresh state regardless of Friday's outcome

This protects against weekend gaps and avoids "Friday recovery trade" behavioral pattern.

### 5.8 State Machine Summary

```
STATE: Default (NY-only)
  Trigger: NY session active AND streak = 0
  Action: Look for entries during NY 08:00-15:00 only

STATE: Recovery (All sessions)
  Trigger: Streak ≥ 1 AND no TP yet in cycle
  Action: Look for entries in any active session

STATE: Cycle Done (No more trading)
  Trigger: TP hit OR 3 SLs hit
  Action: Wait until next NY open

STATE: At NY Open
  Action:
    1. If open trade exists from previous cycle → close at market
    2. Reset streak → Position 1
    3. Clear recovery mode flag
    4. Enter Default state
```

### 5.9 Walk-Through Examples

**Example 1 — Clean Win (Default Path):**
- Mon NY 10:00: Pos 1 entry, TP hits at 12:00. Cycle done.
- Mon afternoon, Tokyo (Tue), London (Tue): no trading.
- Tue NY: fresh Pos 1.

**Example 2 — Loss Streak with Recovery:**
- Mon NY: Pos 1 SL at 11:00, Pos 2 SL at 14:00. Streak = 2.
- Mon NY ends 15:00. Recovery mode active.
- Mon Tokyo (technically Tue 01:00 CET): Pos 3 entry, TP hits! Cycle done.
- Tue NY: fresh Pos 1.

**Example 3 — Full Bust:**
- Mon NY: Pos 1 SL, Pos 2 SL. Mon Tokyo: Pos 3 SL. Streak = 3 → reset.
- No trading rest of Tue Tokyo/London.
- Tue NY: fresh Pos 1.

**Example 4 — Carryover Force-Close:**
- Mon NY 14:30: Pos 1 entry. SL not hit by 15:00. Trade keeps running.
- Trade still open through Mon Tokyo (no new entries — trade already open).
- Tue NY 08:00: trade still open → force-close at market.
- Realize P/L. Reset streak to Pos 1. Look for fresh entry.

**Example 5 — Trade SLs in Off-Session:**
- Mon NY 14:30: Pos 1 entry. Trade runs into Tokyo and SLs at 02:00 CET.
- Streak advances to 2. Recovery mode activates immediately.
- Look for Pos 2 entry in Tokyo/London.

---

## 6. Auto Support/Resistance Detection

### 6.1 Algorithm
On each 1H and 4H closed candle, scan the past N bars (`SR_Lookback_Bars_1H` = 100, `SR_Lookback_Bars_4H` = 50) for swing highs/lows.

**Swing High definition:** A candle whose high is greater than the highs of the 3 candles before AND 3 candles after. (Total 7-bar window, the middle bar is the swing.)

**Swing Low:** Mirror — low less than 3 before and 3 after.

### 6.2 Level Storage
Store all detected swing highs as resistance, swing lows as support. De-duplicate: if two levels are within `0.5 × ATR(14)` of each other, merge into one (use the average).

### 6.3 Level Strength
Each level gets a strength score = number of times price touched within `0.3 × ATR` over lookback period. Stronger levels (touched 2+ times) take priority for TP targeting.

### 6.4 Usage
- **Entry block:** see Section 4.8
- **TP target:** see Section 3.1

---

## 7. FTMO Compliance Checklist

| Rule | Implementation |
|------|---------------|
| Max Daily Loss 5% | EA caps at 1.50% (3.5% buffer) |
| Max Loss 10% | Cumulative tracking; EA blocks all entries if equity < starting balance × 0.93 (safety buffer) |
| Min 4 trading days | EA naturally trades most days; not enforced as code rule |
| Server time GMT+2/+3 | All time logic uses TimeCurrent() (broker server time) |
| News restrictions | None on Swing, but EA still applies news filter for safety |
| Hedging across instruments | Block opposing trades on same symbol (Section 4.7) |
| Max 200 open orders | Never more than 1 trade open at a time |
| Max 2000 server requests/day | EA does NOT poll on tick — only checks on new 15M candle close (max ~96 candles/day × 9 symbols × 3 actions = ~2,592 baseline, optimize by checking only relevant symbol per signal) |
| No martingale/gambling | Risk progression 0.30→0.50→0.70 (1.67x ratio, NOT 2x) |
| Realistic lot sizing | Position size based on % equity, not arbitrary |
| Weekend holds | Allowed on Swing, but EA closes Friday 15:00 NY anyway |

### 7.1 Server Request Optimization
Critical: do NOT update SL/TP on every tick. Only:
- On new 15M candle close: check entry signals, update trailing SL
- On position open: set SL and TP once
- On break-even trigger: update SL once
- Periodic state save (every 15 min): write to file

This keeps server requests well under 2,000/day.

---

## 8. State Persistence (File System)

### 8.1 What Gets Saved
A file `EA_State_<MagicNumber>.json` written to `MQL5/Files/`:
```json
{
  "streak_position": 2,
  "current_cycle_id": "20260503_NY",
  "tp_hit_in_cycle": false,
  "daily_loss_pct": 0.45,
  "daily_loss_date": "2026-05-03",
  "last_sl_count": 2,
  "trades_taken_today": 2,
  "open_trade_ticket": 12345678,
  "open_trade_cycle_id": "20260503_NY",
  "last_save_time": "2026-05-03T14:30:00Z"
}
```

### 8.2 When State is Saved
- After every closed trade (SL/TP/trail)
- After every new entry
- Every 15 minutes (heartbeat)
- On EA shutdown (OnDeinit)

### 8.3 When State is Read
- On EA initialization (OnInit)
- After VPS restart / EA reload
- After MT5 platform restart

### 8.4 State Recovery Logic
On EA start:
1. Read state file (if exists)
2. Validate `daily_loss_date` — if not today (CET), reset daily counter
3. Check open positions by Magic Number — if open trade exists but no record in state, log warning and adopt the trade
4. Resume normal operation

If state file missing or corrupted: start fresh with Pos 1, daily loss 0, no cycle in progress.

---

## 9. Input Parameters (All User-Configurable)

```mql5
// === ACCOUNT & RISK ===
input double  AccountSize_Reference  = 100000.0;  // For documentation only; live uses real equity
input double  Risk_Position1         = 0.30;      // % per first trade
input double  Risk_Position2         = 0.50;      // % per second trade
input double  Risk_Position3         = 0.70;      // % per third trade
input double  Max_Daily_Loss         = 1.50;      // % — hard stop for the day
input int     Max_Streak_Length      = 3;         // SLs before streak reset
input double  Max_Total_DD_Buffer    = 7.00;      // % below initial — emergency block

// === SESSION TIMES (NY local) ===
input int     NY_Start_Hour          = 8;
input int     NY_End_Hour            = 15;        // last 2hr of NY skipped
input int     Tokyo_Skip_First_Min   = 30;
input int     Friday_Close_Hour_NY   = 15;

// === ALLIGATOR (Standard BW) ===
input int     Jaw_Period             = 13;
input int     Jaw_Shift              = 8;
input int     Teeth_Period           = 8;
input int     Teeth_Shift            = 5;
input int     Lips_Period            = 5;
input int     Lips_Shift             = 3;

// === ATR-BASED FILTERS ===
input int     ATR_Period             = 14;
input double  ATR_Mouth_Open_Mult    = 0.4;       // Lips-Jaw separation
input double  ATR_SL_Buffer          = 0.2;       // beyond Jaw/swing
input double  ATR_Tangle_Tolerance   = 0.3;       // for "mouth closed" detection
input double  Min_ATR_Ratio          = 0.5;       // dead market filter
input double  Trail_ATR_Buffer       = 0.3;
input double  BE_Trigger_R           = 1.0;
input double  BE_Buffer_Pips         = 2.0;

// === TREND/STRENGTH FILTERS ===
input int     ADX_Period             = 14;
input double  Min_ADX_1H             = 20.0;

// === SUPPORT/RESISTANCE ===
input int     SR_Lookback_Bars_1H    = 100;
input int     SR_Lookback_Bars_4H    = 50;
input int     SR_Block_Distance_Pips = 10;
input int     SR_Swing_Bars_Each_Side = 3;        // for swing detection

// === HEIKEN ASHI ===
input double  HA_Wick_Tolerance_Pips = 1.0;       // max opposing wick

// === SPREAD LIMITS (per symbol) ===
input double  Spread_EURUSD          = 1.5;
input double  Spread_GBPUSD          = 1.5;
input double  Spread_USDJPY          = 2.0;
input double  Spread_USDCHF          = 2.0;
input double  Spread_AUDUSD          = 2.0;
input double  Spread_USDCAD          = 2.0;
input double  Spread_NZDUSD          = 2.0;
input double  Spread_XAUUSD          = 30.0;      // 30 cents = 30 pips on gold
input double  Spread_NAS100          = 2.0;       // points

// === SLIPPAGE ===
input int     Slippage_FX_Pips       = 3;
input int     Slippage_Gold_Cents    = 50;
input int     Slippage_NAS_Points    = 5;

// === NEWS FILTER ===
input bool    News_Filter_Enabled    = true;
input int     News_Block_Min_Before  = 15;
input int     News_Block_Min_After   = 15;
input string  News_Impact_Filter     = "High";    // High, Medium+, All

// === SYMBOLS (CSV list) ===
input string  Trade_Symbols          = "EURUSD,GBPUSD,USDJPY,USDCHF,AUDUSD,USDCAD,NZDUSD,XAUUSD,NAS100";

// === SYSTEM ===
input long    Magic_Number           = 20260503;
input bool    Verbose_Logging        = true;
input string  State_File_Name        = "EA_State.json";
```

---

## 10. Build Phases (Recommended Implementation Order)

### Phase 1: Foundation (Week 1)
- [ ] Create main EA file structure with OnInit, OnTick, OnDeinit
- [ ] Define all input parameters (Section 9)
- [ ] Implement state persistence (file read/write JSON)
- [ ] Implement Magic Number enforcement
- [ ] Implement basic logging system
- [ ] Set up symbol list parsing from CSV input

### Phase 2: Data & Indicators (Week 1-2)
- [ ] Multi-symbol indicator handles (Alligator, ATR, ADX) for all 9 symbols
- [ ] 15M, 1H, 4H timeframe data access
- [ ] Heiken Ashi calculation function
- [ ] Auto S/R detection (Section 6)
- [ ] Spread checking per symbol
- [ ] ATR ratio (dead market) calculation

### Phase 3: Entry Logic (Week 2)
- [ ] Entry Type A — mouth opens detection
- [ ] Entry Type B — mouth closed breakout detection
- [ ] 1H Alligator soft filter
- [ ] All filters integrated (ADX, ATR, S/R block, spread, news)
- [ ] Symbol prioritization (first valid signal)
- [ ] Same-instrument hedge block

### Phase 4: Position Sizing & Order Management (Week 2-3)
- [ ] Position size calculator (per-symbol pip value)
- [ ] Order placement with proper SL/TP
- [ ] Slippage handling
- [ ] Order rejection handling and retry logic

### Phase 5: Trade Management (Week 3)
- [ ] Break-even logic at +1R
- [ ] Trailing stop after BE (Lips ± ATR buffer)
- [ ] Forced exit conditions (Lips break, Friday close, NY open carryover)
- [ ] Initial TP setting (S/R or 2R)

### Phase 6: Streak & Session Logic (Week 3-4)
- [ ] Cycle definition (NY-to-NY)
- [ ] Streak counter (reset every NY)
- [ ] Daily loss counter (reset midnight CET)
- [ ] Default vs Recovery mode state machine
- [ ] Friday close + reset
- [ ] Trade carryover force-close at NY open

### Phase 7: Compliance & Safety (Week 4)
- [ ] Max daily loss enforcement (1.50%)
- [ ] Max total DD safety buffer (block at -7%)
- [ ] News filter via MT5 calendar
- [ ] Server request optimization (no per-tick polling)
- [ ] All FTMO checks (Section 7)

### Phase 8: Testing (Week 4-5)
- [ ] Unit testing each function with print-debugging
- [ ] Strategy Tester backtest on 1 symbol (EURUSD) over 6 months
- [ ] Multi-symbol backtest
- [ ] Stress test with deliberate edge cases
- [ ] Forward test on demo for 2 weeks minimum

---

## 11. Backtest & Validation Protocol

### 11.1 Backtest Settings
- **Period:** Most recent 12 months
- **Modeling:** Every tick based on real ticks (highest accuracy)
- **Initial deposit:** $100,000
- **Leverage:** 1:30 (matches FTMO Swing)
- **Spreads:** Use current/realistic, not minimum

### 11.2 Pass Criteria (Backtest)
- Profit factor > 1.5
- Max drawdown < 8%
- Win rate > 30% (since 2R targets, even 30% is profitable)
- Average wins per month: 3-7
- No more than 2 cycles per month with 3 consecutive SLs (no full bust days)
- No FTMO rule violations (daily loss never exceeds 1.50%)

### 11.3 Forward Test (Demo)
2 weeks minimum on FTMO demo account before going live on challenge.
- Verify state persistence across restarts
- Verify session timing
- Verify spread/news filtering
- Verify same-instrument hedge block
- Manual log review for unexpected behavior

### 11.4 Go-Live Checklist
- [ ] Backtest passes all criteria
- [ ] Forward test 2 weeks passed
- [ ] State file persists correctly
- [ ] All input parameters tested for sensitivity
- [ ] VPS hosting verified (24/7 uptime)
- [ ] Broker symbol names verified (some brokers use "EURUSD.m" or "GOLD" etc.)

---

## 12. Edge Cases Handled

| Case | Handling |
|------|----------|
| EA crashes mid-trade | State file restores on restart; open trade adopted by Magic Number |
| Broker disconnects | OnTick checks connection; resumes when restored |
| Spread spike at entry time | Spread filter rejects; signal skipped |
| News event surprise | News filter blocks 15min around high-impact |
| Symbol unavailable (delisted) | Skip symbol, log warning, continue with rest |
| Insufficient margin | Order rejection logged; streak does not advance |
| Opposite signal during open trade | Ignored — only one position per symbol |
| New 15M candle missed (lag) | Logic uses closed candle data, not real-time |
| Friday close coincides with open trade | Force-close at 15:00 NY, P/L realized |
| NY open with leftover trade | Force-close at market, fresh cycle starts |
| Daily loss approaching 1.50% | Block any trade where `current + risk > 1.50%` |
| Total DD approaching 7% | Block ALL new trades (emergency stop) |
| State file corrupted | Reset to fresh state, log error, continue |
| Symbol has zero recent ATR (data gap) | Skip symbol that day |

---

## 13. File Structure for Claude Code

```
EA_AlligatorHA/
├── EA_AlligatorHA.mq5              # Main EA file
├── Include/
│   ├── StateManager.mqh             # JSON state file read/write
│   ├── SignalEngine.mqh             # Entry A & B detection
│   ├── PositionManager.mqh          # Sizing, BE, trailing
│   ├── SessionManager.mqh           # NY/Tokyo/London + cycle logic
│   ├── StreakManager.mqh            # Streak counter logic
│   ├── DailyLossManager.mqh         # Daily counter, FTMO compliance
│   ├── SRDetector.mqh               # Auto S/R from swings
│   ├── HeikenAshi.mqh               # HA calculation
│   ├── NewsFilter.mqh               # MT5 calendar interface
│   ├── SymbolPrioritizer.mqh        # ADX-based selection
│   └── Logger.mqh                   # Verbose logging
├── Files/
│   └── EA_State.json                # Persistent state (auto-created)
└── README.md                         # Build & deploy instructions
```

Each include file should have a clear single responsibility. Main EA file orchestrates by calling these modules.

---

## 14. Critical Reminders for Claude Code

1. **Do NOT use martingale-style sizing.** Risk progression is fixed at 0.30/0.50/0.70 — never compute as `prev × 2`.

2. **Always use closed candle data** for signals, never current/forming candle. Use `iClose(symbol, PERIOD_M15, 1)` not `iClose(symbol, PERIOD_M15, 0)`.

3. **Server time is broker time** (TimeCurrent()), GMT+2/GMT+3. Translate to NY time via offset (typically GMT-5/GMT-4) — handle DST transitions.

4. **Same-instrument lock is FTMO-critical.** Failure to block opposite trades = potential rule violation.

5. **State persistence must be atomic.** Write to temp file, then rename, to avoid corruption on power loss.

6. **Magic Number is the EA's identity.** All position checks use it. If user runs multiple instances, each needs unique Magic.

7. **Optimize server requests.** No SL/TP modification on every tick. Only on candle close events.

8. **Test in MT5 Strategy Tester first.** Never deploy to live FTMO challenge without 12-month backtest + 2-week forward test.

9. **Symbol name normalization.** Some brokers append suffixes (e.g., "EURUSD.m"). Read symbol from input as base, then resolve actual broker symbol.

10. **Input validation in OnInit.** If any parameter is out of valid range (e.g., negative risk %), refuse to start and log error.

---

## 15. Open Questions / User Discretion (Future Tuning)

These are items that should be tuned during forward testing:

- ATR multipliers (mouth open separation, SL buffer, trail buffer) — start with defaults, adjust per symbol if needed
- Min ADX threshold — may need higher value for ranging instruments
- Spread limits — verify against actual broker spreads after first week of demo
- Position 1/2/3 risk values — may want to flatten to 0.40/0.40/0.40 if recovery rarely succeeds
- BE trigger R — could test 0.8R or 1.2R variants
- HA wick tolerance — broker pip definition may differ for indices

---

## End of Action Plan

**This document is the single source of truth.** Any deviation during implementation must be flagged and discussed before code changes. Every decision in this plan was reached through detailed discussion — nothing here is arbitrary.

**Next step:** Hand this file to Claude Code for implementation, starting with Phase 1.
