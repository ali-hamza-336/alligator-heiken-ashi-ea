# CLAUDE.md — Alligator + Heiken Ashi EA

Auto-loaded at session start. Read this first before answering anything.

## Project goal

Build an FTMO Swing 2-Step EA in MQL5 (MetaTrader 5). Multi-symbol trend-following on Alligator + Heiken Ashi. Target 3-5%/month on $100k account.

**Spec:** `EA_Action_Plan.md` — 629-line original spec in this directory. Its **architecture / FTMO compliance / state schema / edge-cases (§1–§8, §12) still hold and define the skeleton**; reference sections by number (e.g. "spec §4.5 = news filter"). **But as of Path A (2026-05-12) the spec's parameters and strategy details (§9 values, the §2 entry rules, §3 exit rules) are advisory, not law** — the EA was built faithfully to spec, backtested, found unprofitable on the 2025-26 sample, and is now in active strategy-tuning mode (user explicitly OK'd deviation). Don't re-litigate the module skeleton; do change entries/exits/SL/TP/risk/symbols as the data warrants.

**Execution roadmap:** `C:\Users\Ali Hamza\.claude\plans\i-have-md-plan-lovely-lobster.md` — phase-by-phase plan (Phases 1–7 done; Phase 8 in progress; Path A planned next). Read it for what's done, what's next, and per-phase scope.

## Project status (2026-05-12)

- **Phase 1 — Foundation: ✅ COMPLETE.** Code compiles, 46/46 unit tests pass, EA boots cleanly, symbol resolution works, state persistence roundtrip verified on live MT5.
- **Phase 2 — Indicators & Data: ✅ COMPLETE.** 3 new test scripts (77/77 asserts green). 36 indicator handles per attach (9 symbols × 4 indicators: Alligator M15/H1, ATR M15, ADX H1). Heiken Ashi compute, auto S/R from swings, ATR-ratio dead-market check, per-symbol spread checker — all verified live on IC Markets demo. Diagnostic dump now gated behind `Phase2_Diagnostic_Dump` input (default off).
- **Phase 3 — Entry Signals: ✅ COMPLETE.** 2 new test scripts (Test_SignalEngine 42/42, Test_SymbolPrioritizer 8/8 green). Type A (mouth opens) + Type B (HA breakout), 1H Alligator soft filter, per-bar ADX/dead/spread/hedge/SR gates, ADX symbol ranking at startup. Verified live on IC Markets demo: 3 natural signals fired in a 35-min run (XAUUSD A_SELL → WOULD ENTER, USDCAD/EURUSD A_BUY → SKIPPED by ADX+SR). No orders placed.
- **Phase 4 — Sizing & Orders: ✅ COMPLETE.** 1 new test script (Test_PositionManager 30/30 green). Pure: PipValuePerLot, RiskPctForStreak, LotSizeFor, NormalizeLot (round-down to broker step), InitialTPPrice (closer-of-2R-or-S/R within 5R), SlippagePoints (per asset-class). Live: BuildPlan + Place via CTrade with bounded retry on REQUOTE/PRICE_CHANGED/PRICE_OFF. Verified live on IC Markets demo: real XAUUSD B_BUY ticket=1637035136 placed (lots=0.02, SL/TP attached, magic stamped), state file roundtrip atomic post-fill, clean detach with handle release + state flush.
- **Phase 5 — Trade Management: ✅ COMPLETE.** 2 new test scripts (Test_TradeManager 32/32, Test_SessionTime 8/8 green). New modules: `TradeManager.mqh` (pure: BE trigger/SL, trail SL, IsImprovement, IsBeyondLips, Decide composer with priority NY-open > Friday > Lips > trail > BE > none; live: ModifySL, CloseAtMarket via CTrade) and `SessionTime.mqh` (fixed-offset stub — replaced with DST-aware logic in Phase 6, signature locked). EA wiring: `AdoptOpenPosition()` at OnInit (orphan reconcile), `EvaluateOpenPosition()` orchestrator at top of OnNewM15Bar, `ResolveClosedPosition()` for broker-side TP/SL detection. Live verified on IC Markets demo: Adopt scenario A & B, Friday-close branch fired live (USDJPY ticket 1638127933 via `MA_CLOSE_FRIDAY`).
- **Phase 6 — Sessions, Streak & Daily-Loss: ✅ COMPLETE (2026-05-11).** 3 new pure modules + 1 extended + 4 EA wiring tasks. New: `SessionManager.mqh` (NY/Tokyo/London window predicates + `IsTradingAllowed` composer), `StreakManager.mqh` (`ETradingMode` DEFAULT/RECOVERY/LOCKED, `EForcedCloseReason`, cycle/streak state machine, `DeriveMode`), `DailyLossManager.mqh` (CET-date rollover, `WouldBreachLimit` pre-entry guard, `ApplyRealizedProfit` loss-only accumulator). Extended: `SessionTime.mqh` gained `IsUSInDST` / `IsBrokerInDST` / `DeriveOffsetHours` (pure DST calendar math) — `Server_To_NY_Offset_Hours` input now `0 = auto-derive` (non-zero = override). EA wiring: `CurrentNYOffset()` chokepoint, `MaybeRolloverCycle()` (NY-open cycle reset), `MaybeResetDailyLoss()` (00:00 CET reset + `g_day_start_equity` snapshot), full session/mode gate replacing the Phase-5 Friday stop-gap, streak hooks in `ResolveClosedPosition` (SL→`OnSLClose`, TP→`OnTPClose`, EXPERT→log-only) + `EvaluateOpenPosition` `MA_CLOSE_*` branch (`OnForcedClose` + `ApplyRealizedProfit` with `pre_close_profit` capture), pre-entry daily-loss budget check. Unit tests: Test_SessionTime 27/27, Test_SessionManager 30/30, Test_StreakManager 28/28, Test_DailyLossManager 14/14, Test_TradeManager 35/35 — all green. Live on IC Markets demo (2026-05-11): broker GMT offset auto-cached (+3h), session gate `entry-block` lines fire pre-NY-open, **cycle rollover `20260508_NY → 20260511_NY` fired exactly at NY 08:00**, daily-loss reset fired at init with `start_equity=100001.65`, Adopt A & B both worked. **Two pre-existing bugs found in long-run testing and fixed:** (A) per-symbol hedge block was insufficient — spec §7 requires global single-trade; `EvaluateOpenPosition` now returns `true` whenever any position is open (returns `false` only when `open_trade_ticket==0`). (B) `CTradeManager::Decide` misfired `MA_MOVE_BE` on the zero-close sentinel (sell-side `close <= trigger` is trivially true when close=0) — added `if(ctx.close_m15_s1 <= 0.0) return d;` guard after the time-based checks. Both fixes reviewed + unit-tested.
- **Phase 7 — Compliance & Safety: ✅ COMPLETE (2026-05-12).** 1 new module + 1 extended + 1 schema field + 5 EA wiring points. New: `NewsFilter.mqh` — pure `CurrenciesForSymbol` (FX pair → {base,quote}; XAU/XAG & indices → {USD}), `ImpactPasses` (High / Medium+ / All; NONE never passes), `IsWithinBlackout` (inclusive ±N min); live `IsBlocked(canonical, now, enabled, impact_filter, before, after, &reason)` — queries the MT5 economic calendar (`CalendarValueHistory`/`CalendarEventById`/`CalendarCountryById`) over the `[now−before, now+after]` window, blocks on the first high-impact event in a relevant currency; auto-skips when `MQLInfoInteger(MQL_TESTER)` (logs once); fail-open on any API error. Extended: `DailyLossManager.mqh` gained `static IsTotalDDBreached(equity, initial_balance, buffer_pct)` = `initial_balance>0 && equity < initial_balance*(1−buffer_pct/100)` (strict `<`; fail-open when baseline ≤0). Schema: `EAState` gained `double initial_balance` — snapshotted once on first run (`AccountInfoDouble(ACCOUNT_BALANCE)`), persisted in the JSON, parsed gracefully (legacy files lacking it load fine, stays 0). EA wiring: `#include NewsFilter.mqh`; OnInit snapshots/echoes the FTMO max-loss baseline + the `initial×(1−7%)` emergency line; `OnNewM15Bar` — total-DD emergency entry-block right after the session gate (`CDailyLossManager::IsTotalDDBreached(equity, g_state.initial_balance, Max_Total_DD_Buffer)` → `Log.Warn("entry-block: EMERGENCY total-DD …")` + return; **entry-block only, no force-close** per spec §7), per-symbol news block in the filter row (`news_clear = !CNewsFilter::IsBlocked(canon, TimeCurrent(), News_Filter_Enabled, News_Impact_Filter, News_Block_Min_Before, News_Block_Min_After, …)` → `filters: … news=OK/BLOCKED` log line + `news_reason` detail + `&& news_clear` in `all_pass`); Phase-6→7 labels bumped. Unit tests all green (2026-05-11): Test_DailyLossManager 22/22 (16 fns, +4 `IsTotalDD*`), Test_NewsFilter 24/24 (4 fns, new file), Test_StateManager 31/31 (+`initial_balance` roundtrip + `InitDefault zeros` asserts), Test_StreakManager 28/28 (regression — struct-field add didn't break it). EA compiles zero-error. **§7 FTMO checklist sweep done** — every rule maps to a file/function (Max Daily Loss → `WouldBreachLimit`; Max Loss 10% → `IsTotalDDBreached`+OnInit snapshot; news → `CNewsFilter`; hedging/max-orders → invariant #9 global single-trade; ≤2000 req/day → closed-bar gate; no-martingale → fixed `{0.30,0.50,0.70}`; weekend → Friday-15:00-NY force-close); the only non-code rule is "min 4 trading days" (spec §7 itself says not enforced as code). **Live verified on IC Markets demo (2026-05-12):** `===== EA Phase 7 startup =====`; `Initial balance snapshot: 100440.16 … emergency entry-block below 93409.35` on first run, then `FTMO max-loss baseline (from state): initial=100440.16 …` on the next attach (so `"initial_balance"` persists in `EA_State.json`); a one-shot `[NEWS-DIAG]` block (temporary, since removed) confirmed `CalendarValueHistory -> 371 value(s), err=0` (broker DOES populate the MT5 calendar), listed the real US CPI events (`2026.05.12 15:30 USD imp=3 CPI m/m / Core CPI m/m / CPI y/y / CPI`), and a live `CNewsFilter::IsBlocked("EURUSD", <future high-impact USD event time>)` returned `TRUE  reason=[news: USD 10-Year Note Auction at 2026.05.12 20:00 (impact=3)]` — the live calendar path works end-to-end; no `CalendarValueHistory error`, no spurious `entry-block: EMERGENCY total-DD`; `Cycle rollover 20260511_NY → 20260512_NY` + `Daily-loss reset … start_equity=100440.16`; clean `Adopt: … idle`. Note: this broker tags some non-data items HIGH (e.g. `10-Year Note Auction`), so the news filter is slightly conservative around bond auctions — that's the spec behaviour, not a bug. **Only organic confirmation left (not a blocker):** the live `news=BLOCKED` line on an actual entry-signal's `filters:` row (no signal happened to fire near a release during the verification windows; the mechanism itself is unit-tested 24/0 + the live `IsBlocked` path is proven). **Verification overrides still on the inputs panel** (revert before Phase 8): `Risk_Position1/2/3=0.05`, `ATR_Mouth_Open_Mult=0.10`, `SR_Block_Distance_Pips=1`, `Min_ADX_1H=5`, `Server_To_NY_Offset_Hours=0` (last one is the correct default).
- **Phase 8 — Test & Validate: 🔶 IN PROGRESS (2026-05-12).** Dev overrides reverted to spec §9 (✅). 3 tester-hardening edits shipped: broker-GMT-offset recomputed per call + EU-DST fallback in the tester (`CurrentBrokerGMTOffsetHr`; replaces the OnInit-cached `g_broker_gmt_offset_hr`); fresh state + no 900s heartbeat in the Strategy Tester (`MQLInfoInteger(MQL_TESTER)` guards); routine `entry-block: session` log demoted Info→Debug. README.md written. `EA_AlligatorHA.mq5`/`TradeManager.mqh` banners bumped to Phase 8. **12-month backtests run (IC Markets demo data, 2025-05-12→2026-05-11, every-tick-real-ticks, $100k):** EURUSD-only **−1.34%** (PF 0.70, 53 trades) at spec defaults; full 9-symbol basket **−5.24%** (305 trades). The strategy as specified does **not** have a positive edge on this period. → see "Phase 8 / Path A" heads-up below.
- **Lips-break exit softening — SHIPPED (2026-05-12), defaults = spec no-op.** Spec §3.4's "M15 close on the wrong side of the Lips → exit" closed 38/53 EURUSD trades, almost all at small losses (death by a thousand cuts). Added 3 tunable inputs to `TradeManager.mqh` + EA, **each a no-op at its default** so the EA = spec until dialled up: `LipsBreak_ATR_Buffer` (0.0; break needs `|close−Lips| ≥ mult×ATR`), `LipsBreak_Confirm_Bars` (1; require last N M15 closes all beyond Lips, N∈[1,3]), `LipsBreak_Min_Hold_Bars` (0; suppress this exit for the first N bars after entry — other exits unaffected). `IsBeyondLips` gained a buffer arg; `Decide`'s `ManageContext` gained the 3 settings + `bars_since_entry` + the prior 1–2 candles' close/Lips; EA `EvaluateOpenPosition` fills them (reads Lips at shift 2/3 only when confirm≥2/3, `bars_since_entry = (bar_time − POSITION_TIME)/900`); `ValidateInputs` range-checks. Test_TradeManager 28 tests / **48 asserts green**. Optimizer (90 combos, 12-mo EURUSD): best is `Confirm_Bars=2` (others 0/0) → EURUSD **−0.28%** (PF 0.94, still a loss; cut the bleed ~80% but didn't cross breakeven). The buffer mostly hurt; min-hold was inert. Design doc: `docs/2026-05-12-lips-break-exit-softening.md`.
- **Backtest verdict & root causes (2026-05-12):** on the 9-symbol run, per-symbol *trade* P/L roughly washes — GBPUSD +$1.4k, USDCHF +$1.1k, NZDUSD +$0.9k, USDJPY +$0.5k vs USDCAD −$3.4k, AUDUSD −$1.6k, EURUSD/XAUUSD ~flat (net ≈ −$1.4k) — but the account lost −$5.2k because **~$3.8k of it is swap** (overnight financing on multi-day leveraged swing holds; commission was $0 on this account). Two robustness bugs surfaced: (1) **NAS100 never trades** — `Spread_NAS100=2` (spec default) is far below this broker's USTEC spread (~90 pts), so every NAS100 signal is rejected on spread; (2) **~41 orders failed to place** (`Invalid stops` retcode 10016, a few `No money` 10019) when the Alligator was tangled and the computed SL distance was below the broker's minimum (and the matching lot size blew up) — those errors *prevented* trades, so they didn't cause the loss, but they're real defects.
- **Decision (2026-05-12): pursue "Path A" — a deeper strategy-tuning round.** User: "no give up." Scope is no longer the Lips exit alone — entries, SL, TP, risk management, swap mitigation, and symbol selection are all on the table. **The project is now in active strategy-development mode: the spec's parameters (`EA_Action_Plan.md` §9) are no longer rigid** (user explicitly OK'd deviation; the structural skeleton — modules, FTMO compliance, state, sessions — stays). Caveats to carry into Path A: the 12-month backtest is one regime (small sample — get more data when feasible); a swap-free account is an option but the goal is to be profitable *with* swap; re-optimize on the surviving symbol basket (not EURUSD-only) to avoid single-symbol over-fit; consider dropping the consistent losers (USDCAD, AUDUSD) and fixing the NAS100 spread default so it can trade; consider Approach C (pre-break-even: tighten SL to the Lips instead of market-closing — also makes winners proportionally bigger vs swap). Path A will be brainstormed → planned → implemented as its own cycle.

## Heads-up for the Phase 8 / Path A session

Read before drafting the Path A plan.

- **Dev overrides are reverted ✅** — code defaults in `EA_AlligatorHA.mq5` are already spec §9 verbatim; the MT5 inputs panel was reset 2026-05-12. (Historical: `Risk_Position1/2/3=0.05`, `ATR_Mouth_Open_Mult=0.10`, `SR_Block_Distance_Pips=1`, `Min_ADX_1H=5` were dev overrides; all back to `0.30/0.50/0.70`, `0.4`, `10`, `20`.) The new `LipsBreak_*` inputs default to their spec-no-op values (`0.0 / 1 / 0`); the tuned-but-insufficient finding was `Confirm_Bars=2`.
- **News filter is auto-disabled in the Strategy Tester** (`MQLInfoInteger(MQL_TESTER)` → `IsBlocked` returns false), so backtests are unaffected by it; `News_Filter_Enabled` only matters live.
- **Backtest setup that's been used:** Strategy Tester, EURUSD chart, M15, "Every tick based on real ticks", $100k, leverage 1:33 (broker max — sizing is risk-%-based so this doesn't matter), date 2025-05-12→2026-05-11, `Verbose_Logging=false` for long runs. `Trade_Symbols="EURUSD"` for the single-symbol baseline; the full 9-CSV for the basket run.
- **Spec is now advisory for parameters/strategy details** (Path A); `EA_Action_Plan.md` §1–§8/§12 (architecture, FTMO compliance, state schema, edge cases) still hold. Don't re-litigate the skeleton; do tune freely.

**Mostly-resolved carry-overs** (the 2026-05-12 backtests exercised these — all behaved): Lips-break / Friday-close forced exits fire; `Resolve: SL/TP` streak + daily-loss accounting works; cycle rollover (NY 08:00) + daily-loss reset (00:00 CET) fire; `Adopt:` reconcile works; the global single-trade rule held across 305 sequential trades; no `ModifySL failed` spam (Bug-B is clean). Still genuinely open: `MaybeRolloverCycle`/`MaybeResetDailyLoss` are skipped on bars while a position is open (early-return in `OnNewM15Bar`) — harmless (rollover is a no-op while a trade is live; daily-reset lag is ~15 min at a boundary); if Path A touches `OnNewM15Bar` it could hoist them. Live `news=BLOCKED` on an actual signal's `filters:` row never organically happened (the live `IsBlocked` path is otherwise proven; pure helpers unit-tested).

## Working directory layout

```
Experts/Alligator_Heiken_Ashi_EA/
├── EA_Action_Plan.md                # original spec (architecture/FTMO/state/edges still hold; params now advisory — Path A)
├── CLAUDE.md                        # this file — canonical project status
├── README.md                        # build / inputs / backtest / forward-test / VPS                [Phase 8]
├── EA_AlligatorHA.mq5               # main EA
├── docs/
│   └── 2026-05-12-lips-break-exit-softening.md   # design doc: the 3 LipsBreak_* knobs              [Phase 8]
└── Include/
    ├── Logger.mqh                   # severity-tagged Print wrapper          [Phase 1]
    ├── StateManager.mqh             # atomic JSON state persistence (§8)      [Phase 1; +initial_balance P7]
    ├── SymbolResolver.mqh           # CSV parser + broker-suffix probing      [Phase 1]
    ├── IndicatorHub.mqh             # owns Alligator/ATR/ADX handles          [Phase 2]
    ├── HeikenAshi.mqh               # pure HA compute + live wrapper          [Phase 2]
    ├── SRDetector.mqh               # auto S/R from swings + dedupe + touches [Phase 2]
    ├── MarketFilters.mqh            # dead-market (ATR ratio) + spread cap    [Phase 2]
    ├── SignalEngine.mqh             # Type A & B entry detection              [Phase 3]
    ├── SymbolPrioritizer.mqh        # ADX-based selection                     [Phase 3]
    ├── PositionManager.mqh          # sizing, OrderPlan, CTrade Place         [Phase 4]
    ├── TradeManager.mqh             # BE/trail/forced exits, Decide composer  [Phase 5; P6 zero-close guard; P8 LipsBreak_* softening — defaults = spec]
    ├── SessionTime.mqh              # ServerToNY + DST (IsUSInDST/IsBrokerInDST/DeriveOffsetHours) [Phase 5; DST in P6]
    ├── SessionManager.mqh           # NY/Tokyo/London windows + IsTradingAllowed [Phase 6]
    ├── StreakManager.mqh            # ETradingMode + cycle/streak state machine [Phase 6]
    ├── DailyLossManager.mqh         # FTMO loss limits: daily (CET reset, budget) + total-DD [Phase 6; +IsTotalDDBreached P7]
    └── NewsFilter.mqh               # high-impact news blackout: pure helpers + MT5 calendar query [Phase 7]

Scripts/Alligator_Heiken_Ashi_EA_Tests/
├── Test_StateManager.mq5            # 6 tests, 31 asserts                     [Phase 1; +2 P7 initial_balance]
├── Test_SymbolResolver.mq5          # 6 tests, 17 asserts (CSV parser)        [Phase 1]
├── Test_HeikenAshi.mq5              # 6 tests, 27 asserts                     [Phase 2]
├── Test_SRDetector.mq5              # 16 tests, 28 asserts                    [Phase 2]
├── Test_MarketFilters.mq5           # 8 tests, 22 asserts                     [Phase 2]
├── Test_SignalEngine.mq5            # 27 tests, 42 asserts                    [Phase 3]
├── Test_SymbolPrioritizer.mq5       # 3 tests, 8 asserts                      [Phase 3]
├── Test_PositionManager.mq5         # 21 tests, 30 asserts                    [Phase 4]
├── Test_TradeManager.mq5            # 28 tests, 48 asserts                    [Phase 5; +3 P6 zero-close; +13 P8 LipsBreak softening]
├── Test_SessionTime.mq5            # 18 tests, 27 asserts                    [Phase 5; +11 P6 DST]
├── Test_SessionManager.mq5          # 13 tests, 30 asserts                    [Phase 6]
├── Test_StreakManager.mq5           # 11 tests, 28 asserts                    [Phase 6]
├── Test_DailyLossManager.mq5        # 16 tests, 22 asserts                    [Phase 6; +4 P7 total-DD]
└── Test_NewsFilter.mq5              # 4 tests, 24 asserts                     [Phase 7]
```

Test scripts include from a relative path: `..\..\Experts\Alligator_Heiken_Ashi_EA\Include\X.mqh`. They run as MT5 Scripts (drag onto chart). The repo is git-rooted at `MQL5/` with a `.gitignore` scoped to just `Experts/Alligator_Heiken_Ashi_EA/` + `Scripts/Alligator_Heiken_Ashi_EA_Tests/` (so the GitHub repo mirrors the live MT5 layout).

## Locked-in user decisions

| Decision | Value | Why |
|---|---|---|
| Build cadence | Phase-by-phase, review gate after each | Lower risk on a 629-line spec |
| Broker for dev | **IC Markets demo** (this terminal) | User has an active FTMO challenge running; can't risk it |
| Symbol resolution | Generic CSV → runtime probe via `SymbolSelect()` | Portable across brokers |
| Tunable defaults | ~~Spec §9 verbatim~~ → **now actively tuned (Path A)** | The §9 config backtested unprofitable; tuning entries/exits/SL/TP/risk/symbols via the inputs panel + Strategy Tester optimizer |
| Testing form | `.mq5` Script files with `Assert()` macro | No jest/pytest in MQL5; user runs script, pastes log |
| Source control | git-rooted at `MQL5/`, `.gitignore` scoped to this project's two folders; pushed to GitHub | Backup + history; repo mirrors the live MT5 layout |
| Goal bar | Profitable *with* swap on the FTMO-Swing config (12-mo backtest must hit §11.2) before any live use | Swap-free accounts exist but the EA should stand on its own |

Known broker mapping: NAS100 → **USTEC** on IC Markets (and `Spread_NAS100=2` default is far too tight for it — fix in Path A). All other 8 symbols match exactly.

## Cross-cutting invariants (enforce in every phase)

1. **Closed candles only.** Never `iClose(s, tf, 0)`; always shift `>= 1`. (spec Critical Reminder #2)
2. **No per-tick order modification.** SL/TP changes only inside the new-M15-bar handler in `OnTick`. (#7)
3. **Magic Number gate** — every position lookup filters by `Magic_Number`. (#4, #6)
4. **Atomic state writes** — write to `.tmp`, then `FileMove` to final. (#5)
5. **Risk progression is fixed array** `{0.30, 0.50, 0.70}`, never computed. (#1)
6. **Centralized time conversion** — one `ServerToNY(datetime)` helper handling DST; no scattered offsets. (#3)
7. **Never move SL backward** — every SL modify gated by `CTradeManager::IsImprovement`. (Phase 5)
8. **Server→NY offset auto-derived per call** via `CurrentNYOffset()` → `CSessionTime::DeriveOffsetHours`; `Server_To_NY_Offset_Hours` input is override-only (0 = auto). (Phase 6)
9. **Max 1 trade open at a time, globally** — not per-symbol. `EvaluateOpenPosition` returns `true` (suppress all entries) whenever any position by `Magic_Number` is open; returns `false` only when `open_trade_ticket==0`. The per-symbol `hedge_clear` check is now redundant belt-and-braces. (Phase 6, spec §7)
10. **`CTradeManager::Decide` ignores the zero-close sentinel** — `if(ctx.close_m15_s1 <= 0.0) return d;` after the time-based exits, before the price-based ones. Caller passes 0s for `close/lips/atr` when the bar event belongs to a different symbol than the open position. (Phase 6)
11. **Streak/cycle/daily-loss state mutates in exactly two places** — `ResolveClosedPosition` (broker close: SL→`OnSLClose`, TP→`OnTPClose`) and `EvaluateOpenPosition` `MA_CLOSE_*` branch (`OnForcedClose` + `ApplyRealizedProfit`). Both followed by atomic `State.Save`. (Phase 6)
12. **Two new entry gates in `OnNewM15Bar`, both block-only (never force-close):** (a) total-DD emergency — `CDailyLossManager::IsTotalDDBreached(equity, g_state.initial_balance, Max_Total_DD_Buffer)` right after the session gate, returns before any signal work; (b) per-symbol news — `CNewsFilter::IsBlocked(canon, TimeCurrent(), News_Filter_Enabled, …)` in the filter row, contributes `news_clear` to `all_pass`. News auto-skips in the Strategy Tester and is fail-open on calendar API errors. Both gates sit below `EvaluateOpenPosition`'s early return, so they only run when flat — correct, since they gate *entries*. (Phase 7, spec §4.5 / §7)
13. **`EAState.initial_balance` is the FTMO max-loss baseline, snapshotted once and never recomputed** — set in `OnInit` from `AccountInfoDouble(ACCOUNT_BALANCE)` only when ≤0 (fresh state / legacy file), then persisted. `IsTotalDDBreached` fails open when it's ≤0. Do not derive it from equity, high-water marks, or the `AccountSize_Reference` input. (Phase 7)
14. **Server→NY offset is recomputed per call, not cached** — `CurrentBrokerGMTOffsetHr(now)` does `MathRound((TimeTradeServer()−TimeGMT())/3600)` each call (so a mid-run DST flip is picked up without restarting, and 12-month backtests stay correct across the whole period); in the Strategy Tester, if that comes out 0 (some MT5 builds make `TimeGMT()==TimeTradeServer()` there), it falls back to the EU-DST calendar via `CSessionTime::IsBrokerInDST` → +2/+3. `CurrentNYOffset(now)` = `Server_To_NY_Offset_Hours` if non-zero, else `DeriveOffsetHours(now, CurrentBrokerGMTOffsetHr(now))`. The old `g_broker_gmt_offset_hr` global is gone. (Phase 8)
15. **Strategy Tester runs from fresh state and skips the heartbeat timer** — `MQLInfoInteger(MQL_TESTER)` guards both: `State.InitDefault(g_state)` instead of `State.Load` (so a previous run's `EA_State_<magic>.json` in the agent dir doesn't leak streak/daily-loss/ticket across runs), and `EventSetTimer(900)` is only armed when *not* in the tester (OnDeinit flushes anyway). Live behaviour unchanged. (Phase 8)
16. **The Lips-break exit is softenable but defaults to the spec** — `LipsBreak_ATR_Buffer=0`, `LipsBreak_Confirm_Bars=1`, `LipsBreak_Min_Hold_Bars=0` reproduces spec §3.4 exactly. `CTradeManager::Decide` applies them in order: min-hold gate (`bars_since_entry >= min_hold`) → `IsBeyondLips(...,buf)` where `buf = mult×atr_m15_s1` → N-bar confirm (require s1 [+s2 [+s3]] all beyond). The zero-close sentinel guard (#10) stays above this block. EA fills the prior bars' Lips only when `confirm ≥ 2/3`. Don't bake tuned values into the code defaults — keep code = spec, set tuned values on the panel. (Phase 8)

## TDD pattern in MQL5

- Test scripts live in `MQL5/Scripts/Alligator_Heiken_Ashi_EA_Tests/`.
- Pattern: define `Assert(cond, label)`, `AssertEqInt`, `AssertEqStr`, `AssertEqDbl(got, exp, tol, label)` at top of script. `OnStart` calls test functions, prints `===== Done. passed=N failed=M =====`.
- Write the test **before** the include implementation. Pure-logic modules get full TDD; broker-integration parts (`SymbolsTotal()`, `iTime()`, `OrderSend`) are integration-tested via attaching the EA.
- Claude can't compile MQL5. The user is the test runner — they compile, drag-to-chart, paste output.

## Resume protocol for a new session

When starting fresh in this project, the new Claude session will auto-load this file. The new session should:

1. **This file (CLAUDE.md) is the canonical project status** — the "Project status" section above tells you what's done and what's next. Do **NOT** read the whole plan file (`~/.claude/plans/i-have-md-plan-lovely-lobster.md`) on resume — its top ~95 lines (context + status notes + Phases 7-8 sketch) is all you need; the Phase 7 *detailed* sub-plan sits mid-file under `## Phase 7 — Compliance & Safety (DETAILED)` (read it only if revisiting Phase 7), and the Phases 2-6 detailed sub-plans are archived in `~/.claude/plans/archive-alligator-ea-phases-2-6-detailed.md` (~5K lines) — **never read the archive on a normal resume**. When you execute Phase N, grep the plan file for `## Phase N — ` and read only that section (or one archive section if you need a format reference).
2. If user says "continue Phase N" → invoke `superpowers:writing-plans` first to draft the per-phase sub-plan; append it to the plan file *below the existing detailed sub-plans* (not the archive); get user OK; then implement. Consider `superpowers:subagent-driven-development` for the execution loop (one subagent per task + spec/quality review per task) — that's how Phases 6-7 were done.
3. Use `superpowers:test-driven-development` for any new module with pure logic. Tests first, in `Scripts/Alligator_Heiken_Ashi_EA_Tests/`. Bundle test + impl per delivery (see `feedback_no_red_handoff_for_mechanical_fails` memory).
4. Use `superpowers:verification-before-completion` before claiming any phase done. Hand-off pattern: write code → user compiles + runs tests + attaches EA → user pastes log → Claude verifies green before marking phase complete.
5. When a phase ships, add a one-paragraph `Phase N — ...: ✅ COMPLETE` line to the "Project status" section above, add a `## Phase N status: ✅ COMPLETE (date)` note near the top of the plan file, and if the plan file is getting long, archive the Phase-N detailed sub-plan into the archive file.
6. **Never** suggest deploying to the FTMO terminal during dev. IC Markets demo only until Phase 8 forward test.

## Key spec sections by topic (quick lookup)

| Topic | Spec § |
|---|---|
| Strategy overview, instruments, timeframes | §1 |
| Entry Type A (mouth opens) | §2.1 |
| Entry Type B (HA breakout) | §2.2 |
| Position sizing formula | §2.3 |
| Initial TP / break-even / trailing / forced exit | §3 |
| Spread / ATR-liquidity / ADX / news / S/R-block / hedge-block filters | §4 |
| Sessions, streak logic, recovery mode, cycle = NY-to-NY | §5 |
| Daily loss counter (FTMO compliance layer) | §5.6 |
| Friday close & reset | §5.7 |
| Auto S/R detection | §6 |
| FTMO compliance checklist | §7 |
| State persistence schema | §8 |
| All input parameters (verbatim) | §9 |
| Build phases (Week 1-5 plan) | §10 |
| Backtest & validation protocol | §11 |
| Edge cases handled | §12 |
| Critical reminders for implementer | §14 |

## Tone / output preferences

- Be terse. Stop narrating.
- Use markdown link syntax for file refs: `[file.mqh](Include/file.mqh)`.
- Don't add comments to code unless WHY is non-obvious.
- Don't claim work is done without compile + test evidence from the user.
