# Path A — Stage 1: cheap fixes + clean re-baseline

**Date:** 2026-05-12  **Status:** approved, implementing
**Context:** Phase-8 backtests showed the §9 strategy unprofitable (EURUSD-only ≈ −1.3%/yr; 9-symbol −5.24%). "Path A" = a staged tuning effort. Stage 1 = low-risk, low-effort fixes that remove bugs and trim the basket — *not* an edge change — then re-baseline before the bigger Stage 2+ work. See [CLAUDE.md](../CLAUDE.md) "Phase 8" + [docs/2026-05-12-lips-break-exit-softening.md](2026-05-12-lips-break-exit-softening.md).

## Scope — three changes only

### Fix A — `Spread_NAS100` (and `Spread_XAUUSD`) defaults
`Spread_NAS100 = 2` (points) is far below this broker's USTEC quote spread (~90 pts), so every NAS100 signal is rejected on the spread filter → NAS100 has never traded in any backtest. Bump the **code defaults**: `Spread_NAS100 2 → 200`, `Spread_XAUUSD 30 → 50` (Phase-2 flagged the gold one as tight too). These remain per-broker tunables; README notes that. **Verify in the re-run** that NAS100 actually places trades.

### Fix B — minimum SL distance + lot ceiling (the ~41 PLACE_FAILED bug)
A tangled-Alligator Type-B entry can put the Jaw (hence the structural SL = Jaw ± `ATR_SL_Buffer×ATR`) a fraction of a pip from the entry → (a) inside the broker's minimum stop distance → `OrderSend` returns `10016 Invalid stops`; (b) the risk-based lot `= risk$ / (SL_pips × pip_value)` blows up → `10019 No money`. Fix in `CPositionManager`:
- New pure helper `static double SLDistanceFloor(const long stops_level_pts, const double point, const double atr, const double min_sl_atr_mult)` → `MathMax(stops_level_pts × point, min_sl_atr_mult × atr)`.
- In `BuildPlan`, right after `sl_dist = |entry − SL|`: if `sl_dist < SLDistanceFloor(SYMBOL_TRADE_STOPS_LEVEL, point, atr, min_sl_atr_mult)` → **reject the signal** (`out.invalid_reason = "SL too tight (dist=… < floor=…)"`, `return false`). Rejecting (not widening) keeps the SL at its structural meaning; the EA already logs `>>> SKIPPED: <reason>`.
- In `BuildPlan`, cap the lot: `out.lots = NormalizeLot(MathMin(out.lot_raw, max_lot), vol_min, vol_max, vol_step)` — belt-and-braces against any future sizing blow-up; if that collapses below `vol_min` the existing `lots <= 0` check rejects.
- `BuildPlan` gains two args: `min_sl_atr_mult`, `max_lot`. EA passes the two new inputs.
- New EA inputs (trade-mgmt section): `Min_SL_ATR_Mult` (double, default `1.0`), `Max_Lot` (double, default `50.0`). `ValidateInputs`: `Min_SL_ATR_Mult >= 0`, `Max_Lot > 0`.
- `Test_PositionManager.mq5`: 2–3 asserts for `SLDistanceFloor` (ATR term dominates; stops-level term dominates when ATR tiny; zero-ATR edge).

### Fix C — symbol cull
Drop the two consistent losers from the `Trade_Symbols` **code default**: `USDCAD` (−$3.4k/yr trade-P/L) and `AUDUSD` (−$1.6k). New default: `"EURUSD,GBPUSD,USDJPY,USDCHF,NZDUSD,XAUUSD,NAS100"` (7 symbols). Keep XAUUSD (coin-flip, not a clear loser; may behave differently after Stage 2's exit rework). Update README's symbol list.

## After implementation
1. User compiles (0/0), runs `Test_PositionManager.mq5` → pastes green totals.
2. User runs the 12-month tester on the **7-symbol basket** (Strategy Tester, EURUSD chart, M15, every-tick-real-ticks, $100k, 1:33, 2025-05-12→2026-05-11, `Trade_Symbols` = the new default CSV, `LipsBreak_Confirm_Bars=2`, `Verbose_Logging=false`) → pastes the report + journal.
3. Claude: confirm NAS100 now trades, no more `Invalid stops`/`No money` clusters, and read the new net P/L vs the prior −$5.2k. Re-assess with the user → Stage 2 (exits / Approach C) or stop.

## Notes / risks
- Pure spec deviation: `EA_Action_Plan.md` §9 default values for `Spread_NAS100`, `Spread_XAUUSD`, `Trade_Symbols`; plus 2 new inputs not in §9. Sanctioned (Path A — params are advisory now).
- Dropping symbols on one 12-month backtest is mild over-fitting; revisit symbol selection after Stage 2 (a symbol that's bad with the current exit may be fine with Approach C).
- `Min_SL_ATR_Mult=1.0` also (incidentally) widens the *effective* minimum 2R-TP for Type-B trades, since TP = 2×SL_distance — acceptable, arguably good (a Type-B breakout that invalidates within <1×ATR was a low-quality setup anyway).
- This stage does **not** change the edge — if the 7-symbol re-run is still clearly negative, that's expected; Stage 2 (exits) is where the edge work happens.
