# EA_AlligatorHA — Alligator + Heiken Ashi multi-symbol EA (MT5)

A Bill Williams **Alligator + Heiken Ashi** trend-following Expert Advisor for MetaTrader 5, built to **FTMO Swing 2-Step** challenge rules. Monitors 9 instruments, takes the first valid signal that passes all filters, sizes by a fixed 0.30 / 0.50 / 0.70 % risk progression, and enforces FTMO's daily-loss, total-drawdown, hedging, news, and weekend constraints.

**Source of truth for the strategy is [`EA_Action_Plan.md`](EA_Action_Plan.md)** (629-line spec — entries, filters, risk math, FTMO compliance, all 50 inputs, state schema, edge cases). This README is build & operations only. Project status / phase log lives in [`CLAUDE.md`](CLAUDE.md).

---

## Files

```
Experts/Alligator_Heiken_Ashi_EA/
├── EA_AlligatorHA.mq5        # main EA — orchestrates the modules below
├── EA_Action_Plan.md         # the spec (do not modify)
├── CLAUDE.md                 # project status / phase log / invariants
├── README.md                 # this file
└── Include/
    ├── Logger.mqh            # severity-tagged Print() wrapper (DEBUG/INFO/WARN/ERROR), gated by Verbose_Logging
    ├── StateManager.mqh      # atomic JSON state persistence (spec §8) — write to .tmp, FileMove to final
    ├── SymbolResolver.mqh    # CSV parser + broker-suffix probing (EURUSD → EURUSD.m, NAS100 → USTEC, …)
    ├── IndicatorHub.mqh      # owns Alligator (M15 + H1), ATR (M15), ADX (H1) handles per symbol
    ├── HeikenAshi.mqh        # pure HA candle compute + live wrapper
    ├── SRDetector.mqh        # auto support/resistance from swing highs/lows + dedupe + touch counting
    ├── MarketFilters.mqh     # dead-market (ATR-ratio) check + per-symbol spread cap
    ├── SignalEngine.mqh      # Type A (mouth opens) + Type B (HA breakout) entry detection
    ├── SymbolPrioritizer.mqh # ADX-based symbol ranking at NY-session start
    ├── PositionManager.mqh   # position sizing, OrderPlan, CTrade order placement (bounded retry)
    ├── TradeManager.mqh      # break-even / trailing / forced exits — Decide() composer
    ├── SessionTime.mqh       # server→NY time conversion + US/EU DST calendar math
    ├── SessionManager.mqh    # NY / Tokyo / London window predicates + IsTradingAllowed composer
    ├── StreakManager.mqh     # trading-mode state machine (DEFAULT / RECOVERY / LOCKED), cycle = NY-to-NY
    ├── DailyLossManager.mqh  # FTMO daily-loss budget (CET reset) + 7% total-DD emergency check
    └── NewsFilter.mqh        # high-impact news blackout via the MT5 economic calendar

Scripts/Alligator_Heiken_Ashi_EA_Tests/   # *.mq5 unit-test scripts — drag onto a chart to run, paste the log
```

**State file:** `<terminal data folder>/MQL5/Files/EA_State_<Magic_Number>.json` — one file per Magic Number (so multiple instances don't collide). Written atomically (to `EA_State_<magic>.tmp`, then `FileMove` to the final name) on a 15-minute heartbeat, after every fill, and on shutdown. If missing or corrupt the EA logs a warning and starts fresh. In the **Strategy Tester** the EA ignores any persisted file and always starts from fresh state (and skips the heartbeat timer).

---

## Build

1. Open `EA_AlligatorHA.mq5` in MetaEditor (it's under `MQL5/Experts/Alligator_Heiken_Ashi_EA/`).
2. Compile (F7). Expect **zero errors, zero warnings**.
3. The `Include/*.mqh` files are referenced by relative path (`#include "Include\\X.mqh"`) — keep the folder layout intact. The test scripts include the EA's headers via `..\..\Experts\Alligator_Heiken_Ashi_EA\Include\X.mqh`, so they only compile if the EA folder is where it's expected.
4. To run the unit tests: in MetaEditor compile each `Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_*.mq5`, then in MT5 drag the script onto any chart. It prints `===== Done. passed=N failed=M =====` to the Experts log.

---

## Inputs

The full list of ~50 inputs and their spec-default values is **spec §9**. The code defaults in `EA_AlligatorHA.mq5` match §9 verbatim. Tune via the EA Properties → Inputs panel (or the Strategy Tester's Inputs tab) — there's no separate config file. Notable ones:

| Input | Notes |
|---|---|
| `Magic_Number` | The EA's identity. Every position lookup filters by it. **Use a unique value per running instance.** |
| `Trade_Symbols` | CSV of canonical names — default `"EURUSD,GBPUSD,USDJPY,USDCHF,NZDUSD,XAUUSD,NAS100"` (7 symbols; `USDCAD` & `AUDUSD` dropped in Path A — consistent losers in the 12-month backtest). Resolved to broker symbols at `OnInit` via `SymbolSelect()` probing; the EA refuses to start (with a clear log) if any name is unresolvable. Known broker alias: **`NAS100` → `USTEC` on IC Markets**; the others match exactly. For a single-symbol backtest set this to just `"EURUSD"`. |
| `Server_To_NY_Offset_Hours` | `0` = auto-derive (broker GMT offset, recomputed per call, + US DST calendar). Set a non-zero value only if the auto-derived offset is wrong on your broker. The EA logs the boot value: `Broker GMT offset (boot): +Nh -> NY offset -Mh …`. |
| `Spread_EURUSD` … `Spread_NAS100` | Per-symbol max spread (entry skipped if `current_spread > limit`). **Path A bumped `Spread_NAS100 2 → 200` and `Spread_XAUUSD 30 → 50`** (the old NAS100 default rejected every USTEC signal — ~90-point spread on IC Markets). Still per-broker tunables — watch the per-bar `filters: … spread=OK/NO …` log lines and adjust. (The Strategy Tester models its own spreads, so these only matter live.) |
| `Min_SL_ATR_Mult` / `Max_Lot` | Path A order-safety guards. `Min_SL_ATR_Mult` (default `1.0`): a signal is rejected if its structural stop-loss is closer to entry than `Min_SL_ATR_Mult × ATR` (or the broker's minimum stop distance, whichever is larger) — stops the tangled-Alligator "Invalid stops" / "No money" rejections. `Max_Lot` (default `50`): hard ceiling on any single position's lot size — belt-and-braces against a sizing blow-up. |
| `News_Filter_Enabled` | `true` live = block entries ±`News_Block_Min_Before/After` minutes around high-impact news for the symbol's currencies (via the MT5 calendar; fail-open if the calendar is unavailable). **Auto-disabled in the Strategy Tester** regardless of this setting. |
| `Verbose_Logging` | `true` for forward-testing (you want the per-bar diagnostics and `entry-block: session …` lines). `false` for long backtests (suppresses the DEBUG-level chatter; the routine session-block lines are DEBUG-level too). |
| `LipsBreak_ATR_Buffer` / `LipsBreak_Confirm_Bars` / `LipsBreak_Min_Hold_Bars` | Soften the "close on the wrong side of the Lips → exit" rule (spec §3.4). **Defaults `0.0 / 1 / 0` reproduce the spec behaviour exactly.** Dialled up: `ATR_Buffer` requires the close to be past the Lips by ≥ mult × ATR (kills fractional pokes); `Confirm_Bars` (1–3) requires the last N M15 closes all beyond the Lips (kills one-bar flukes); `Min_Hold_Bars` suppresses this exit for the first N M15 bars after entry (lets a trade breathe — other exits unaffected). Tune these with the Strategy Tester optimizer; recommended values are TBD pending that run. |
| `Risk_Position1/2/3` | Fixed `0.30 / 0.50 / 0.70`. **Not** martingale — never derived as `prev × 2`. |
| `Max_Daily_Loss` / `Max_Total_DD_Buffer` | FTMO guards: pre-entry block when `current_daily_loss% + next_risk% > Max_Daily_Loss` (1.50%); emergency entry-block (no force-close) when equity falls `Max_Total_DD_Buffer%` (7%) below the persisted initial balance. |

---

## Running a backtest

Spec §11 is the protocol. In short:

1. **View → Strategy Tester.** Expert = `EA_AlligatorHA`, Symbol = `EURUSD`, Timeframe = `M15`, Model = **"Every tick based on real ticks"** (highest accuracy), Date range = the most recent 12 full months, Deposit = `100000`, Leverage = `1:30` (matches FTMO Swing), Spreads = **current/realistic** (not "minimum").
2. **Inputs tab:** all params at spec §9 defaults (the tester's input set is independent of any chart). For the single-symbol baseline set `Trade_Symbols = "EURUSD"`; for the full multi-symbol run set the 9-symbol CSV (slower — the tester loads and ticks all 9 symbols; run on the EURUSD chart because its dense tick stream drives the EA's per-symbol new-bar detection). Set `Verbose_Logging = false` for long runs.
3. **The news filter auto-disables in the tester** (`MQLInfoInteger(MQL_TESTER)`), so backtests are unaffected by it.
4. **Pass criteria — spec §11.2:** profit factor > 1.5, max drawdown < 8 %, win rate > 30 %, ~3–7 winning trades/month, ≤ 2 cycles/month with 3 consecutive stop-losses, no FTMO rule violations (daily loss never exceeds 1.50 %).
5. Tunables to revisit if criteria miss (spec §15): `Min_ADX_1H`, `ATR_Mouth_Open_Mult`, `ATR_Tangle_Tolerance`, `Min_ATR_Ratio`, `SR_Block_Distance_Pips`, the session window hours. Tune on the Inputs tab — don't edit the code defaults.

---

## Forward test (demo)

Spec §11.3 — **minimum 2 weeks on an FTMO _demo_ account before the live challenge** (never the live challenge during testing):

- Attach the EA to a `EURUSD M15` chart with `Trade_Symbols` = the 9-symbol CSV, `Verbose_Logging = true`, all other inputs at §9 defaults, a unique `Magic_Number`.
- Verify: state persistence across a manual MT5 restart (the open trade is re-adopted by Magic Number at `OnInit` — look for `Adopt: …`); session timing (`Cycle rollover … -> …` at NY 08:00, `Daily-loss reset …` at 00:00 CET); spread + news filtering (`filters: … spread=NO …` on a wide-spread tick; `news=BLOCKED` + a `news: …` line if a signal fires near a high-impact release); the global single-trade rule (a 2nd signal on another symbol while one trade is live produces nothing).
- Manual Journal review for anything unexpected.

---

## Go-live checklist (spec §11.4)

- [ ] 12-month backtest passes all §11.2 criteria
- [ ] 2-week demo forward test clean
- [ ] State file persists correctly across restarts
- [ ] Input sensitivity checked (vary the key tunables, confirm the EA isn't fragile)
- [ ] VPS hosting verified (24/7 uptime)
- [ ] Broker symbol names verified on the target broker (some use `EURUSD.m`, `GOLD`, `US100`, etc.)

---

## VPS notes

- **24/7 uptime required** — the EA acts only on closed M15 bars, but a missed window means a missed trade.
- **Reboot-safe.** State lives in `EA_State_<magic>.json`; on restart the EA reloads it and re-adopts any open position by Magic Number. A VPS reboot won't lose the trade or the streak/daily-loss state.
- **Only external dependency:** the MT5 economic calendar (news filter). It degrades fail-open — if the calendar is unavailable the EA does not block entries and logs the condition. The calendar is populated by the broker's data feed; in the Strategy Tester it returns nothing and the news filter is skipped entirely.
- Keep MT5 logged in to the broker server. A VPS in or near the broker's datacentre minimises order-placement latency.

---

## Status

Phases 1–7 complete (foundation → indicators → entry signals → sizing/orders → trade management → sessions/streak/daily-loss → compliance/safety). Phase 8 (test & validate) **in progress**: the EA was built faithfully to the spec, then 12-month backtested — and the spec's strategy is **not yet profitable** on that sample (EURUSD-only ≈ −1.3% / year; the 9-symbol basket worse, dragged down mainly by swap costs on multi-day holds). It's now in active strategy-tuning ("Path A": entries / stop-loss / take-profit / risk / swap mitigation / symbol selection). **Do not run this live yet.** The infrastructure (entries, sizing, BE/trail, sessions, streak/daily-loss, FTMO compliance, state, news) is complete and well-tested; the *strategy parameters* are being worked. See [`CLAUDE.md`](CLAUDE.md) for the canonical status, the cross-cutting invariants, and [`docs/`](docs/) for design notes.
