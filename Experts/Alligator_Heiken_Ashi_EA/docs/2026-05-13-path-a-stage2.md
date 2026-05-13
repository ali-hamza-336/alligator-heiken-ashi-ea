# Path A — Stage 2: Exit-Side Rework

**Date:** 2026-05-13 (designed); 2026-05-14 (Tasks A/B/C shipped)
**Status:** **PARTIAL-SHIPPED — Tasks A/B/C done; D/E pending next session**

**Context:** Stage 1 shipped (−5.24% → −4.40%, still a loss). Stage 1.1 then shipped (commit `7fff5ae`) and re-baselined to **+2.47%** — first profitable config on this 12-mo sample. Stage 2 (this doc) is the exit-side rework on top of that baseline. Execution plan at `~/.claude/plans/continue-path-a-lets-radiant-muffin.md`. For Task D specifics + atomicity recipe, see [docs/2026-05-14-stage2-task-d-handoff.md](2026-05-14-stage2-task-d-handoff.md).

## Implementation status

| Task | Status | Commit(s) | Tests | Notes |
|---|---|---|---|---|
| Stage 1.1 prereq | ✅ Done 2026-05-13 | `7fff5ae`, `db3f650` | Test_PositionManager 41/41 | SL-side guard + Min_SL_ATR_Mult 1.0→0.3 + drop NAS100. Re-baseline +2.47% (was −4.40%). |
| Task A (state schema) | ✅ Done 2026-05-14 | `9a5d183` | Test_StateManager 39/39 | `partial_done` + `be_move_time` fields added with legacy-load pattern. |
| Task B (PartialLot) | ✅ Done 2026-05-14 | `5140924` | Test_PositionManager 49/49 | Pure helper with Fraction-spectrum + close-full fallback. |
| Task C (TightenLipsPrice + Decide rewrite) | ✅ Done 2026-05-14 | `72a7032`, `dd87453` | Test_TradeManager 68/68 | Enum + ManageContext + Decide rewrite. MA_MOVE_BE/MA_CLOSE_LIPS deprecated, kept temporarily for EA compilability. |
| Task D (EA wiring) | ⏳ Pending | — | — | See [Task D handoff doc](2026-05-14-stage2-task-d-handoff.md). Adds `entry_R_distance` schema field, 3 new inputs, dispatch logic with atomicity, removes deprecated enums. |
| Task E (re-baseline backtest) | ⏳ Pending | — | — | After Task D: Fraction=0.5 default + Fraction=1.0 sanity + 8mo/4mo walk-forward. |

## Problem

The Stage-1 re-baseline (12-month, 6-symbol effective after Stage 1.1, $100k) is **−4.40% / −$4,400**, decomposing into ~−$3.4k trade-P/L + ~−$1.0k swap. Audit identified two structural problems that no parameter tune at the existing knobs can fix:

1. **Lips-break exit bleeds tiny losses.** 38 of 53 EURUSD trades closed via `MA_CLOSE_LIPS`, mostly −$5 to −$50 each. The Phase-8 softening (3 `LipsBreak_*` knobs, best combo `Confirm_Bars=2`) cut the bleed ~80% but EURUSD still finished at −0.28% — i.e. softening *reduces* the wound, doesn't *close* it. Holding the position through a Lips poke would have let many of these recover.

2. **Asymmetric risk-reward is baked into spec §3.** SL = Jaw ± `ATR_SL_Buffer×ATR` (often <1R from entry in pip terms when the Alligator mouth is well-separated). Initial TP = `min(2R, nearest S/R within 5R)`. Average win:loss ≈ <2R : <1R, so profit factor must exceed ~1.5 just to break even. Tuning the knobs can't change the architecture.

A third related observation: the trailing stop fires immediately after the BE move at +1R, chopping winners before they can develop into the +3R / +5R runners that exist in the data but get capped.

## Decision

Three coordinated changes to the exit lifecycle — all rewrite `CTradeManager::Decide` and the EA's `EvaluateOpenPosition` dispatch; no entry, sizing, or filter changes. Entries stay untouched (Stage 3 if Stage 2 isn't enough).

### Change A — "Approach C": pre-BE Lips break **tightens** SL, doesn't market-close

A confirmed Lips break **before** the position reaches break-even now triggers a new action `MA_TIGHTEN_SL_LIPS`: move SL to `Lips ± Trail_ATR_Buffer × ATR(14, M15)` (gated by `IsImprovement`; never moves backward; clamped to not cross entry). Post-BE the existing `MA_TRAIL` already does the same thing, so the old `MA_CLOSE_LIPS` is **removed** entirely. The Lips-break tunables (`LipsBreak_ATR_Buffer`, `LipsBreak_Confirm_Bars`, `LipsBreak_Min_Hold_Bars`) carry over and gate **this** action.

### Change B(iv) — partial close at +1R, runner trails with no take-profit

When price reaches `entry ± Partial_Close_Trigger_R × R` (default +1R), a new action `MA_PARTIAL_AND_BE` fires: close `Partial_Close_Fraction × current_lot` (default 50%) at market AND move the runner's SL to `entry ± BE_Buffer_Pips`. The runner has **no take-profit** — exits via trail-SL, forced close (Friday / NY-open), or initial SL only. Subsumes the standalone `MA_MOVE_BE`. Streak/cycle: the moment-of-partial counts as a TP win; the runner's final close updates nothing.

### Change D — trail delay + buffer widening

After break-even, `MA_TRAIL` is gated by `bars_since_BE_move ≥ Trail_Delay_Bars` (new input, default `2` M15 bars). The existing `Trail_ATR_Buffer` default changes from `0.3` to `0.5` for more runner breathing room.

### Single-knob spectrum on `Partial_Close_Fraction`

| Value | Behavior at +1R | Effective strategy |
|---|---|---|
| `0.0` | No partial close; just move SL to BE | Pre-Stage-2 BE-only behavior |
| `0.5` *(default)* | Bank half, runner trails | Balanced — recommended starting point |
| `1.0` | Close full position | **1:1 fixed RR baseline** — every winner = +1R, every loser = −1R |

Lot fallback: if `(current_lot − partial_lot) < broker_vol_min` after `NormalizeLot`, close the full position (same outcome as Fraction=1.0). So `Fraction=1.0` and the broker-min-lot edge case converge to the same code path (close full, count as TP).

## New `TradeManager::Decide` priority order

1. `MA_CLOSE_NYOPEN` — unchanged
2. `MA_CLOSE_FRIDAY` — unchanged
3. **`MA_PARTIAL_AND_BE` (NEW)** — at `entry ± trigger_R×R`, when `!partial_done`. Subsumes old `MA_MOVE_BE`.
4. **`MA_TIGHTEN_SL_LIPS` (NEW)** — pre-BE Lips break (`LipsBreak_*` knobs gate this). Replaces `MA_CLOSE_LIPS`.
5. `MA_TRAIL` — gated by `bars_since_BE_move ≥ Trail_Delay_Bars`. Otherwise unchanged.
6. `MA_NONE`

**Removed:** `MA_CLOSE_LIPS`, `MA_MOVE_BE`. The zero-close sentinel guard (invariant #10) stays as the first line after the time-based checks.

## New / changed inputs

| Input | Type | Default | Allowed | Effect |
|---|---|---|---|---|
| `Partial_Close_Fraction` | `double` | `0.5` | `0.0 … 1.0` | Fraction of position closed at +1R. `0.0`=just BE move; `1.0`=close full (1:1 RR). |
| `Partial_Close_Trigger_R` | `double` | `1.0` | `0.5 … 3.0` | At how many R does the partial fire. |
| `Trail_Delay_Bars` | `int` | `2` | `0 … 10` | M15 bars after the BE move before trail starts firing. |
| `Trail_ATR_Buffer` (existing) | `double` | **`0.5`** (was `0.3`) | `0.0 … 2.0` | Wider trail = more runner room. |
| `LipsBreak_Confirm_Bars` (existing) | `int` | **`2`** (was `1`) | `1 … 3` | Matches Phase-8 tuned-good value. |
| `LipsBreak_ATR_Buffer` (existing) | `double` | `0.0` (unchanged) | `≥ 0` | Now gates SL-tighten (Approach C), not market-close. |
| `LipsBreak_Min_Hold_Bars` (existing) | `int` | `0` (unchanged) | `≥ 0` | Same — gates Approach C now. |

Two existing defaults flipped to bake the Phase-8 + Path-A learnings into the code rather than rely on panel overrides ([CLAUDE.md](../CLAUDE.md) explicitly says the spec params are advisory under Path A).

## Code changes

### `Include/StateManager.mqh`

- Add `bool partial_done` to `EAState`. Serialize as `"partial_done": <bool>`; legacy files (no field) load as `false` (mirror the Phase-7 `initial_balance` legacy-load pattern).
- `InitDefault` zeros it. Set `false` whenever a new position is opened; the closed-position cleanup already wipes per-trade state.
- (Optional) Add `datetime be_move_time` if we end up tracking the BE-move bar explicitly rather than inferring it from SL position. Implementation will pick whichever is cleaner.

### `Include/TradeManager.mqh`

- Add enum values: `MA_PARTIAL_AND_BE`, `MA_TIGHTEN_SL_LIPS`. Remove `MA_CLOSE_LIPS`, `MA_MOVE_BE`.
- New pure helper: `static double TightenLipsPrice(bool is_buy, double lips_s1, double atr_m15_s1, double trail_buf_mult, double entry_price)`. Returns the new SL clamped to not cross entry (BUY: `min(lips − buf, entry − point)`; SELL: `max(lips + buf, entry + point)`). Caller still gates with `IsImprovement`.
- `ManageContext` gains: `partial_close_fraction`, `partial_close_trigger_R`, `trail_delay_bars`, `bars_since_BE_move`, `partial_done`, `entry_R_distance` (= `|entry − initial_SL|`), `vol_min`, `vol_step`.
- `Decide` body rewritten to the new priority order. The zero-close sentinel guard (`if(ctx.close_m15_s1 <= 0.0) return d;`) stays where it is.

### `Include/PositionManager.mqh`

- New pure helper: `static double PartialLot(double current_lot, double fraction, double vol_min, double vol_step)`.
  - Compute `lot = round_to_step(fraction × current_lot, vol_step)`.
  - If `fraction ≤ 0`: return `0.0` (caller skips the partial close; just moves SL to BE).
  - If `lot < vol_min` OR `(current_lot − lot) < vol_min`: return `current_lot` (fallback: close full).
  - Else return `lot`.
- New live helper: `bool ApplyPartialClose(ulong ticket, double lot_to_close, double new_sl_price, ...)`. Wraps `CTrade::PositionClosePartial` + `ModifySL` with the bounded REQUOTE/PRICE_CHANGED/PRICE_OFF retry pattern from `Place()`. Logs ticket / lot-closed / runner-lot / new-SL on success.

### `EA_AlligatorHA.mq5`

- Declare the three new inputs in the trade-management block; flip the two existing defaults.
- `ValidateInputs`: range-check the new three.
- `EvaluateOpenPosition`:
  - Compute `bars_since_entry` (existing), `bars_since_BE_move` (track via `g_state.be_move_time` set when `MA_PARTIAL_AND_BE` fires, OR infer from SL ≥ entry for BUY / SL ≤ entry for SELL), `partial_done = g_state.partial_done`.
  - Fill `entry_R_distance` from `|PositionGetDouble(POSITION_PRICE_OPEN) − g_state.open_initial_sl|` (need to persist `open_initial_sl` if not already — check existing state schema).
  - Dispatch:
    - `MA_PARTIAL_AND_BE`: `PartialLot(...)` → if `0.0` skip partial; else `PositionClosePartial` → `ModifySL` to BE+buffer → `g_state.partial_done = true` → `g_state.be_move_time = now` → `State.Save`.
    - `MA_TIGHTEN_SL_LIPS`: `TightenLipsPrice(...)` → `ModifySL` if `IsImprovement`.
- `ResolveClosedPosition`:
  - Detect a partial close via deal volume < position volume on the magic+ticket pair. On partial: call `OnTPClose` (streak treats as TP win), mark `partial_done` if not already. On the runner's final close: streak unchanged (already counted at partial); just clear per-trade state.
  - Implementation detail: scan `HistoryDealSelect`-style deal history after `PositionClosePartial` returns to confirm the partial booked; or use `OnTradeTransaction` if cleaner. Pick whichever matches the existing close-detection pattern.

### Test scripts

**`Test_StateManager.mq5`** — add asserts: `partial_done` JSON roundtrip; legacy load → `false`; `InitDefault` zeros.

**`Test_PositionManager.mq5`** — add `PartialLot` asserts:
- `PartialLot(0.02, 0.5, 0.01, 0.01) == 0.01` (clean half-split)
- `PartialLot(0.01, 0.5, 0.01, 0.01) == 0.01` (runner would be sub-min → close full)
- `PartialLot(0.03, 0.5, 0.01, 0.01) == 0.01` (`0.015` rounds down to `0.01`)
- `PartialLot(0.10, 1.0, 0.01, 0.01) == 0.10` (fraction=1.0 → full close)
- `PartialLot(0.10, 0.0, 0.01, 0.01) == 0.00` (fraction=0.0 → no partial, just BE)

**`Test_TradeManager.mq5`** — add asserts:
- `Decide` returns `MA_PARTIAL_AND_BE` when BUY position at price ≥ `entry + 1R` AND `!partial_done`; mirror SELL.
- Priority: `MA_PARTIAL_AND_BE` wins over `MA_TIGHTEN_SL_LIPS` when both trigger on the same bar (positive event wins over defensive).
- `Decide` returns `MA_TIGHTEN_SL_LIPS` when pre-BE AND confirmed Lips break (N-bar confirm honoured via existing `LipsBreak_Confirm_Bars` logic).
- `Decide` returns `MA_TRAIL` only when `bars_since_BE_move ≥ Trail_Delay_Bars`; returns `MA_NONE` for the first `Trail_Delay_Bars` bars post-BE.
- `Decide` does NOT return `MA_CLOSE_LIPS` (enum value removed).
- `TightenLipsPrice` BUY: `lips=1.1000, atr=0.0010, buf=0.5, entry=1.1020` → `1.1000 − 0.0005 = 1.0995`; clamp test: `entry=1.0998` → clamped to `1.0998 − point`.
- `TightenLipsPrice` SELL: mirror.
- Zero-close sentinel still works (`close_m15_s1 ≤ 0` → no price-based action).

Bundle test + impl per task (the `feedback_no_red_handoff_for_mechanical_fails` memory): never a RED handoff for a signature-change compile error.

## After implementation

1. User compiles `EA_AlligatorHA.mq5` (zero errors / warnings).
2. User runs each updated `Test_*.mq5` as a chart script → pastes green totals (expect ~52 new asserts across 3 scripts; the other 10 scripts must stay green).
3. **Live smoke test on IC Markets demo** — attach EA, verify new inputs appear on panel with correct defaults; verify `EA_State.json` contains `"partial_done": false` after first save; with `Partial_Close_Trigger_R=0.3` and `Risk_Position1=0.05` (temporary), wait for a real trade to reach +0.3R and observe the partial-close log line + state-file update + runner remaining with BE stop. Revert overrides.
4. **Re-baseline backtest** — 12-month, 6-symbol (Stage-1.1 default basket, no NAS100), Strategy Tester, EURUSD chart, M15, every-tick-real-ticks, $100k, 1:33, 2025-05-12 → 2026-05-11, `Verbose_Logging=false`. Two passes:
   - `Partial_Close_Fraction = 0.5` (recommended config)
   - `Partial_Close_Fraction = 1.0` (1:1 RR baseline; sanity check)
   - Compare to Stage-1.1 baseline (~−4.40%). Document EURUSD-only and full-basket numbers (net P/L, PF, max DD, win rate, swap).
5. **Walk-forward sanity** — split 12 months into 8mo train + 4mo test; verify Stage 2 doesn't fall apart out-of-sample. Catches over-fitting on the headline run.
6. Re-assess with user → Stage 3 (entries) if needed, or stop here if Stage 2 alone gets us to consistent profit.

## Invariants / risks

- **Critical invariants preserved:** #1 (closed candles only), #2 (no per-tick order mods — both new actions fire inside `EvaluateOpenPosition` which only runs on a new M15 bar), #3 (magic gate), #4 (atomic state), #7 (never move SL backward — both new actions use `IsImprovement` or equivalent clamp), #9 (max 1 trade globally — partial doesn't violate, runner is still part of the same position), #10 (zero-close sentinel), #11 (state mutation only in `EvaluateOpenPosition` + `ResolveClosedPosition`), #16 (LipsBreak softening still default no-op at the buffer/min-hold knobs — only `Confirm_Bars` default flips).
- **Spec deviation:** 3 new inputs not in §9; 2 existing defaults flipped; whole `MA_CLOSE_LIPS` mechanism replaced by tightening; standalone `MA_MOVE_BE` subsumed; runner has no TP. Sanctioned (Path A — params and strategy details are advisory now per [CLAUDE.md](../CLAUDE.md)).
- **Swap exposure could grow.** Without a TP cap on the runner, big winners may hold for several days → more overnight financing. ~$1k/yr current swap; could go to ~$1.3-1.5k. Friday-15:00-NY close clears positions weekly. A `Max_Hold_Bars` cap is a clean Stage 5 lever if it gets out of hand.
- **Trail performance becomes load-bearing.** Without a TP, the trail is the sole exit for a winning runner. Mitigated by the `Trail_Delay_Bars` gate and the wider `Trail_ATR_Buffer` default. If the trail still chops runners on Stage-2 backtests, dial both knobs up on the panel and re-run.
- **Streak accounting under partial close:** the partial-fired moment counts as the trade's "TP win" for streak/cycle purposes; the runner's final close does not re-update the streak. This matches spec §5 semantics — one trade, one streak outcome — even though the position closes in two pieces.
- **Walk-forward risk:** the Phase-8 `Confirm_Bars=2` value was found by optimizing on this same 12-month EURUSD window. Re-baking it into the code default risks subtle over-fitting on top of Path-A tuning. Documented; the walk-forward sanity check above is the mitigation.
- **Not in scope:** entry rules (Type A / Type B / filters / ADX / S/R / news), per-trade risk progression, symbol basket, session windows, swap mitigation. Those are the Stages 3-5 levers — see [docs/2026-05-13-path-a-roadmap.md](2026-05-13-path-a-roadmap.md).

## Result (post-Task-E)

**TBD** — Task E (re-baseline backtest) hasn't run yet. Fill this in after Task D ships and the backtest completes.

### Stage 1.1 baseline (pre-Stage-2, for comparison)

- **+2.47%** ($102,474 final, 12-mo, 6-symbol, $100k start)
- PF 1.046, max DD 5.65% equity, 372 trades, 45.7% WR
- Per-symbol: XAUUSD +$1,528 (139t, 56%WR), USDCHF +$1,443 (32t), NZDUSD +$1,286 (23t), EURUSD +$491 (27t), USDJPY −$700 (82t), GBPUSD −$1,574 (69t)
- Entry mix: 72.3% Type A (269 trades), 27.7% Type B (103 trades)
- Exit modes: 21.2% SL, 36.3% TP, **42.5% BLANK** (MA_CLOSE_LIPS = the bleed Stage 2 targets)
- Per-type expectancy: Type A $6.08/trade, Type B $8.17/trade. Type B 52.4% WR; Type A 42.4% WR.
- Worst streak: 11 losses for −$3,499 over 10 days (May-30 → Jun-9 2025). USDJPY ate 5 of 11.
- Avg hold time 1h 30min, 96.8% same-day exits, total swap −$3.73 (essentially zero — Type-A intraday mix collapsed the multi-day swap drag from ~$1k/yr).

The exit-mode distribution is the smoking gun for Stage 2: 158 of 372 trades (42.5%) closed via the old `MA_CLOSE_LIPS` market-close. Stage 2's Approach C converts those to SL-tighten + `IsImprovement` fall-through (some trades will then exit on the original SL, runner profile, or forced-close). If Stage 2 cuts the small-loss cluster without giving up too much winner-side, PF should lift from 1.046 toward 1.5+.

### Expected Task E outputs

After Task D ships, run two passes in the Strategy Tester (EURUSD chart, M15, every-tick-real-ticks, $100k, 1:33, 2025-05-12 → 2026-05-11, `Verbose_Logging=false`):

1. **`Partial_Close_Fraction=0.5`** (default) — bank half at +1R, runner trails. Compare to baseline +2.47%.
2. **`Partial_Close_Fraction=1.0`** (sanity) — close full at +1R = 1:1 RR baseline. Tells us if the runner adds value at all.

Per pass, document: final balance, PF, max DD, win rate, trade count, total swap, per-symbol P/L, exit-mode distribution (SL / TP / FORCED), Type-A vs Type-B breakdown, worst losing streak.

Then run **walk-forward**: 8mo train (2025-05-12 → 2026-01-11) vs 4mo test (2026-01-12 → 2026-05-11). Catches over-fitting on the headline year.

Goal bar: cross PF > 1.5 OR at least preserve +2.47% with a materially better profile (higher avg-win, smaller max-DD-cluster). If Stage 2 is flat or worse than +2.47%, Stage 3 (entry tightening) is the next lever — but think hard about whether to keep tuning vs stop.
