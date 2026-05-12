# Design — Softening the Lips-break exit (Approach A)

**Date:** 2026-05-12
**Status:** approved, implementing
**Context:** Phase-8 backtest finding — see [CLAUDE.md](../CLAUDE.md) Phase-8 notes and the 12-month EURUSD-only backtest.

## Problem

The forced exit "close immediately when a closed 15M candle ends on the opposite side of the Alligator Lips" (spec §3.4, first bullet) is implemented in `CTradeManager::Decide` → `MA_CLOSE_LIPS`. The Lips is the Alligator's *fast* line (5-period SMMA shifted 3) and sits right on top of price, so a single noisy candle — sometimes a poke a fraction of a pip past the line — kills the trade before it can reach +1R (the break-even / trail trigger).

12-month EURUSD-only backtest (2025-05-12 → 2026-05-11): 53 trades, **38 of them closed by `MA_CLOSE_LIPS`**, almost all small losses (~−$3,330 net) — overwhelming the 9 take-profit wins (~+$2,363). Final balance $98,656 = **−1.34%**. Profit factor ≈ 0.70. All risk controls (daily-loss budget, total-DD emergency, 3-SL cycle lock) worked correctly — the problem is purely this one exit being too trigger-happy. Three failure patterns observed: (1) fractional-pip pokes across the line; (2) one fluke bar that immediately reverses; (3) a trade killed in its first 15–30 minutes before it could develop.

## Decision

Add three new tunable inputs that **soften** `MA_CLOSE_LIPS`. Each input's **default reproduces today's behaviour** (so the EA is identical to the spec until the inputs are dialled up; "code = spec §9" stays true — the tuned values live on the inputs panel + in the README, not in the code defaults). Then use the Strategy Tester's **optimizer** on the 12-month EURUSD data to find a stable combo that lifts profit factor, lock those onto the panel, confirm with a re-run, then proceed to the 9-symbol backtest. Approach C (pre-BE: tighten SL to the Lips instead of market-closing) is held in reserve if the optimizer can't get PF above 1.

Scope is **the Lips-break exit only** — no changes to entries, take-profit, break-even trigger, or any other exit.

## New inputs

| Input | Type | Default (= spec no-op) | Allowed | Effect when dialled up |
|---|---|---|---|---|
| `LipsBreak_ATR_Buffer` | `double` | `0.0` | `≥ 0` | A break counts only if `|close − Lips| ≥ LipsBreak_ATR_Buffer × ATR(14, M15)`. Kills fractional pokes. |
| `LipsBreak_Confirm_Bars` | `int` | `1` | `1 … 3` | Require the last N closed M15 candles **all** beyond the Lips (each by the buffer). Kills one-bar flukes. |
| `LipsBreak_Min_Hold_Bars` | `int` | `0` | `≥ 0` | Suppress the Lips-break exit while `bars_since_entry < LipsBreak_Min_Hold_Bars`. Other exits (trail-SL hit, Friday close, NY-open carryover) are unaffected. |

Placed in the trade-management section of the inputs, next to `BE_Trigger_R` / `Trail_ATR_Buffer`.

## Code changes

### `Include/TradeManager.mqh`

- `IsBeyondLips(is_buy, close, lips)` → **`IsBeyondLips(is_buy, close, lips, buffer)`**. BUY break = `close < lips − buffer`; SELL break = `close > lips + buffer`. With `buffer = 0` it is byte-for-byte today's logic.
- `ManageContext` gains:
  - `double lips_break_atr_buffer;` — the multiplier (Decide multiplies by `atr_m15_s1`)
  - `int    lips_break_confirm_bars;` — N (1–3)
  - `int    lips_break_min_hold_bars;`
  - `int    bars_since_entry;`
  - `double close_m15_s2; double lips_m15_s2;` — the bar before s1 (0 = not available / not needed)
  - `double close_m15_s3; double lips_m15_s3;` — two bars before s1
- `Decide` — replace the single `if(IsBeyondLips(...)) { MA_CLOSE_LIPS }` block (after the existing `if(ctx.close_m15_s1 <= 0.0) return d;` zero-close guard — that guard and the overall exit priority order are untouched) with:
  ```
  if(ctx.bars_since_entry >= ctx.lips_break_min_hold_bars)   // default 0 → always true
    {
     const double buf = ctx.lips_break_atr_buffer * ctx.atr_m15_s1;
     bool broken = IsBeyondLips(ctx.is_buy, ctx.close_m15_s1, ctx.lips_m15_s1, buf);
     if(broken && ctx.lips_break_confirm_bars >= 2)
        broken = IsBeyondLips(ctx.is_buy, ctx.close_m15_s2, ctx.lips_m15_s2, buf);
     if(broken && ctx.lips_break_confirm_bars >= 3)
        broken = IsBeyondLips(ctx.is_buy, ctx.close_m15_s3, ctx.lips_m15_s3, buf);
     if(broken)
       { d.action = MA_CLOSE_LIPS; d.reason = StringFormat("Lips break: close=%.5f %s lips=%.5f (buf=%.5f confirm=%d)",
            ctx.close_m15_s1, ctx.is_buy ? "<" : ">", ctx.lips_m15_s1, buf, ctx.lips_break_confirm_bars);
         return d; }
    }
  ```
  Notes: the buffer for the confirm bars reuses `atr_m15_s1` (ATR barely changes bar-to-bar — acceptable simplification, avoids passing atr_s2/s3); `close_m15_s2/s3 == 0` is harmless because they're only read when `confirm_bars ≥ 2/3` and a sane non-zero confirm count means the EA filled them.

### `EA_AlligatorHA.mq5`

- Declare `LipsBreak_ATR_Buffer = 0.0`, `LipsBreak_Confirm_Bars = 1`, `LipsBreak_Min_Hold_Bars = 0` in the trade-management input block.
- In `EvaluateOpenPosition`, when `same_sym` (the new-bar event is for the open position's symbol), after filling `close_m15_s1` / `lips_m15_s1` / `atr_m15_s1`:
  - `mctx.lips_break_atr_buffer = LipsBreak_ATR_Buffer;`
  - `mctx.lips_break_confirm_bars = LipsBreak_Confirm_Bars;`
  - `mctx.lips_break_min_hold_bars = LipsBreak_Min_Hold_Bars;`
  - `bars_since_entry = clamp0( (int)(((long)bar_time - (long)PositionGetInteger(POSITION_TIME)) / 900) );`
  - if `LipsBreak_Confirm_Bars >= 2`: `mctx.close_m15_s2 = iClose(pos_sym, PERIOD_M15, 2);` and `Hub.GetAlligator(pos_sym, PERIOD_M15, 2, jaw, teeth, lips) → mctx.lips_m15_s2`
  - if `LipsBreak_Confirm_Bars >= 3`: same at shift 3 → `mctx.close_m15_s3` / `mctx.lips_m15_s3`
  - when `!same_sym`, leave all the new context fields at 0 / spec defaults along with the existing `close_m15_s1 = 0` sentinel — `Decide` already early-returns on that sentinel before reaching the Lips block, so the new fields are never read.
- `ValidateInputs`: refuse to start if `LipsBreak_ATR_Buffer < 0`, or `LipsBreak_Confirm_Bars < 1 || > 3`, or `LipsBreak_Min_Hold_Bars < 0`.

### `Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_TradeManager.mq5`

- Update the existing `IsBeyondLips(...)` calls to the 4-arg form (pass `0` as the buffer → existing assertions unchanged).
- New asserts:
  - **Buffer:** BUY, close 0.5 pip below Lips, `buffer = 1 pip` → not a break; close 2 pip below, `buffer = 1 pip` → break. Mirror for SELL.
  - **Confirm-bars:** `Decide` with `confirm_bars = 2`: s1 beyond Lips but s2 not → `MA_NONE` (or whatever the next-priority action is — assert it is NOT `MA_CLOSE_LIPS`); s1 and s2 both beyond → `MA_CLOSE_LIPS`.
  - **Min-hold:** `Decide` with `min_hold_bars = 4`, close clearly beyond Lips: `bars_since_entry = 2` → not `MA_CLOSE_LIPS`; `bars_since_entry = 5` → `MA_CLOSE_LIPS`. Also: min-hold does NOT suppress `MA_CLOSE_FRIDAY` / `MA_CLOSE_NYOPEN` (they have higher priority and are checked above the Lips block anyway).
  - **All-defaults regression:** `buffer = 0, confirm = 1, min_hold = 0, bars_since_entry = anything` → identical decisions to the pre-change behaviour (the existing test cases already cover this once the signatures compile).
- Bundle test + implementation in one delivery (per the `feedback_no_red_handoff_for_mechanical_fails` memory) — never a RED handoff for a signature-change compile error.

### `README.md`

Add the three knobs to the Inputs table with their defaults and a one-line note that defaults reproduce spec §3.4 behaviour; mention the recommended tuned values once the optimizer run picks them.

## After implementation

1. User compiles (zero errors/warnings), runs `Test_TradeManager.mq5` → pastes green totals.
2. User runs the Strategy Tester in **optimization mode**: EURUSD M15, every-tick-real-ticks, 12 months, $100k, optimize `LipsBreak_ATR_Buffer` (e.g. 0.0→1.0 step 0.1), `LipsBreak_Confirm_Bars` (1→3 step 1), `LipsBreak_Min_Hold_Bars` (0→8 step 1), maximize Profit Factor (or balance, or a custom criterion). Pastes the top results.
3. Together we pick a **stable region**, not the single peak. Set those values on the inputs panel; re-run the plain 12-month EURUSD test; confirm profit factor > 1 (ideally toward 1.5) and drawdown still < 8%.
4. Proceed to the 9-symbol backtest (Phase-8 Task 7) with those panel values.
5. If step 3 still can't clear PF > 1 → escalate to Approach C.

## Invariants / risks

- Spec-default no-op: with `LipsBreak_ATR_Buffer = 0`, `LipsBreak_Confirm_Bars = 1`, `LipsBreak_Min_Hold_Bars = 0`, behaviour is byte-for-byte identical to the current EA. (Verified by the regression assertions.)
- Exit priority order (NY-open carryover > Friday > Lips break > trail > BE) is unchanged; min-hold/buffer/confirm only gate the Lips-break branch, not the higher-priority ones.
- The zero-close sentinel guard (invariant #10) stays above the Lips block — unchanged.
- Code defaults remain spec §9 verbatim; tuned values are panel-only + documented. Don't bake optimized values into the code defaults.
- Risk of over-fitting the optimizer to one 12-month EURUSD window — mitigated by (a) picking a stable parameter region not a peak, (b) re-validating across the 9-symbol run, (c) the 2-week demo forward test still being the final gate.

## Result (2026-05-12) — shipped; helped, not enough alone

Implemented, all 28 Test_TradeManager tests / 48 asserts green, EA compiles 0/0. Optimizer over the 3 knobs on the 12-month EURUSD data (90 combos): the best was **`LipsBreak_Confirm_Bars = 2`** (the other two at default) → EURUSD-only profit **−$284 (−0.28%)**, profit factor **0.94**, 53 trades — i.e. it cut the bleed from the −$1,344 / PF 0.70 baseline by ~80%, but did not cross breakeven. The ATR buffer mostly *hurt* (every non-zero value was worse); the min-hold was effectively inert in this data. **No combination was profitable.** The subsequent 9-symbol run with `Confirm_Bars = 2` was **−$5,243 (−5.24%)** — the other symbols, plus ~$3.8k of swap, dominate. → Conclusion: the Lips-exit was the biggest single bleeding wound and this fix largely stops it, but the strategy needs deeper work (entries / SL / TP / risk / swap / symbol culling — "Path A"); Approach C (pre-break-even: tighten SL to the Lips rather than market-close) remains in reserve. The 3 inputs stay (no-op at default); `Confirm_Bars = 2` is the current best-known value but not yet a final answer — Path A will re-optimize the whole package on the surviving symbol basket.
