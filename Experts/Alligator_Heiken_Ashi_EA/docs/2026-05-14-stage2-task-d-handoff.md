# Stage 2 Task D — handoff for next session

**Date:** 2026-05-14
**Status:** designed, ready to implement
**Audience:** the next session's Claude, picking this up cold

**Read this BEFORE starting Task D.** It captures design decisions made during the Task C dispatch + the Task-C code-quality review that wouldn't otherwise survive a session boundary. Skim the parent design [docs/2026-05-13-path-a-stage2.md](2026-05-13-path-a-stage2.md) first for the architectural overview.

## What Task D does (high-level)

Wires Tasks A/B/C into the EA orchestrator and removes the deprecated enum values now that the EA dispatch is updated. Six concrete sub-changes:

1. **State schema extension** — add `double entry_R_distance` to `EAState` (Task A added `partial_done` + `be_move_time` only; `entry_R_distance` was deferred to Task D). Same legacy-load pattern as `initial_balance` / `partial_done` / `be_move_time`.
2. **Three new EA inputs** with range-checked `ValidateInputs`.
3. **Two existing input defaults flipped** in `EA_AlligatorHA.mq5`.
4. **Snapshot `entry_R_distance` on entry** in `TryEnterSignal` (around line 458-464 of `EA_AlligatorHA.mq5`) and best-effort in `AdoptOpenPosition` (around line 477+).
5. **`EvaluateOpenPosition` dispatch rewrite** — populate the 5 Stage-2 `ManageContext` fields; dispatch the new actions `MA_PARTIAL_AND_BE` (three sub-cases) and `MA_TIGHTEN_SL_LIPS`; remove the dead `MA_MOVE_BE` and `MA_CLOSE_LIPS` branches.
6. **Remove deprecated enum entries** `MA_MOVE_BE` and `MA_CLOSE_LIPS` from `TradeManager.mqh`. Also remove the orphaned `FCR_LIPS_BREAK` from `StreakManager.mqh` and its handling in `OnForcedClose`.
7. **`ResolveClosedPosition` rewrite for partial-vs-runner** — detect `g_state.partial_done==true` → skip the streak hook (already booked at partial moment) but still call `ApplyRealizedProfit` for the runner's outcome + clear per-trade state.

Plus a live smoke test on the IC Markets demo to verify a real partial fires correctly (forced `Partial_Close_Trigger_R=0.3` and `Risk_Position1=0.05` temporarily so a real trade reaches +0.3R within minutes).

## Design decision: `entry_R_distance` must be a state field (not derivable)

Task C reads `R` from `ctx.entry_R_distance` instead of `MathAbs(entry - current_sl)`. Why this needs state-level persistence:

- **Pre-partial, pre-tighten:** `MathAbs(entry - current_sl)` = the original R. Works.
- **After `MA_TIGHTEN_SL_LIPS` fires** (pre-partial Lips break): `current_sl` moved closer to entry. `|entry - current_sl|` is now smaller than the original R. If we re-derived R here, the next `MA_PARTIAL_AND_BE` trigger would fire at a smaller price than +1R original.
- **After `MA_PARTIAL_AND_BE` fires:** `current_sl` ≈ entry. `|entry - current_sl|` collapses to ~2 pips (the `BE_Buffer_Pips`). Useless for any subsequent R-based calc.

`POSITION_TP` is also not a reliable proxy: the initial TP is `min(2R, nearest_SR_within_5R)`, so it might be anywhere from ~1R to 2R from entry depending on the S/R landscape. Cannot recover the original R from it.

**Decision: snapshot `entry_R_distance` at fill time, persist in state, never recompute.** Mirrors how `initial_balance` is handled (Phase 7 precedent).

### Schema change

Append to `EAState` in [Include/StateManager.mqh](Include/StateManager.mqh), after `be_move_time` and before `last_save_time`:

```mql5
   double   entry_R_distance;   // Stage 2: |entry - initial_sl|, snapshotted at fill; survives partial/tighten SL moves
```

- `InitDefault`: zero it.
- `Serialize`: emit `"entry_R_distance": %.5f,` (or similar precision — matches `initial_balance` style) before the final `last_save_time` key.
- `Load`: optional pattern — `if(ExtractDouble(body, "entry_R_distance", l_dbl)) state.entry_R_distance = l_dbl;` after the `be_move_time` line. Pre-Task-D state files load with `entry_R_distance=0`; the EA detects this on adopt and re-snapshots best-effort (see "Adopt logic" below).

### `Test_StateManager` updates

- Add 2 asserts to `Test_InitDefault`: `entry_R_distance == 0` and verify it's `double` (already enforced by struct).
- Add 1 setter on `w` and 1 assert on `r` in `Test_Roundtrip`: `w.entry_R_distance = 0.00500; ... AssertEqDbl(r.entry_R_distance, 0.005, 1e-6, "entry_R_distance roundtrip");`
- Update `Test_LoadLegacyMissingFields`: add a fourth assertion that `r.entry_R_distance == 0` when the JSON omits the field.

Expected: Test_StateManager 39/39 → **43/43** asserts after this change.

## Three new EA inputs

In [EA_AlligatorHA.mq5](EA_AlligatorHA.mq5), declared in the trade-management block (alongside `BE_Trigger_R`, `Trail_ATR_Buffer`, etc.). Follow the input-label discipline from `db3f650` — inline `// comment` becomes the panel display name, so keep them short:

```mql5
//--- Stage 2: partial-close-at-+1R spectrum and trail-delay gate. See docs/2026-05-13-path-a-stage2.md.
input double  Partial_Close_Fraction  = 0.5;       // Fraction closed at +1R (0=BE only; 1=close full)
input double  Partial_Close_Trigger_R = 1.0;       // Partial fires at +N*R
input int     Trail_Delay_Bars        = 2;         // M15 bars post-BE before trail starts
```

`ValidateInputs` range-checks:

```mql5
if(Partial_Close_Fraction < 0.0 || Partial_Close_Fraction > 1.0)
   { Log.Error("Partial_Close_Fraction must be in [0.0, 1.0]"); return false; }
if(Partial_Close_Trigger_R < 0.5 || Partial_Close_Trigger_R > 3.0)
   { Log.Error("Partial_Close_Trigger_R must be in [0.5, 3.0]"); return false; }
if(Trail_Delay_Bars < 0 || Trail_Delay_Bars > 10)
   { Log.Error("Trail_Delay_Bars must be in [0, 10]"); return false; }
```

## Two existing input default flips

```
Trail_ATR_Buffer       0.3 → 0.5       (wider trail = more runner room)
LipsBreak_Confirm_Bars 1   → 2         (bakes Phase-8 tuned-good value into code)
```

The `LipsBreak_Confirm_Bars=2` flip means the **default** behavior of `MA_TIGHTEN_SL_LIPS` requires two consecutive M15 closes beyond Lips. This is intentional (per design doc), but the `Confirm_Bars=2` value was originally selected by optimizing on the same 12-mo EURUSD window — so there's mild over-fit risk. Walk-forward (Task E) is the mitigation.

## Snapshot `entry_R_distance` on entry

In `TryEnterSignal`, after `g_state.open_trade_ticket = res.ticket;` and before `State.Save(...)`, add:

```mql5
   g_state.entry_R_distance = MathAbs(plan.entry - plan.sl);  // pre-partial R for Stage-2 +trigger_R compute
   g_state.partial_done     = false;                            // belt-and-braces: clear stale flag
   g_state.be_move_time     = 0;
```

The `partial_done`/`be_move_time` resets are defensive — `ResolveClosedPosition` should already clear them, but if a previous close happened in an unusual path, these ensure a clean per-trade state.

## Adopt logic

In `AdoptOpenPosition`, when a live position is found that matches (or is reconciled to) `state.open_trade_ticket`, and `state.entry_R_distance <= 0`:

```mql5
   if(g_state.entry_R_distance <= 0)
     {
      const double entry_p  = PositionGetDouble(POSITION_PRICE_OPEN);
      const double sl_now   = PositionGetDouble(POSITION_SL);
      if(entry_p > 0 && sl_now > 0)
         g_state.entry_R_distance = MathAbs(entry_p - sl_now);
      // Best-effort: if SL has been modified mid-trade (BE/tighten/trail), this
      // underestimates the original R. Acceptable — adopt is a recovery path.
     }
```

Similar best-effort for `partial_done` and `be_move_time`: if `current_sl >= entry` (BUY) or `<= entry` (SELL), assume `partial_done=true` and `be_move_time = TimeCurrent()` (conservative — trail-delay starts now).

## `EvaluateOpenPosition` — `ManageContext` population

In `EvaluateOpenPosition` (around line 657+ of [EA_AlligatorHA.mq5](EA_AlligatorHA.mq5)), the existing population covers most fields. Add the Stage-2 fields:

```mql5
   //--- Stage 2: partial-close-and-BE + trail-delay context
   mctx.partial_done             = g_state.partial_done;
   mctx.partial_close_trigger_R  = Partial_Close_Trigger_R;
   mctx.trail_delay_bars         = Trail_Delay_Bars;
   mctx.entry_R_distance         = g_state.entry_R_distance;
   //  bars_since_BE_move: M15 bars between bar_time and the BE-move bar
   //  (g_state.be_move_time). If not yet BE'd (be_move_time == 0),
   //  bars_since_BE_move = 0 — won't fire MA_TRAIL anyway since gated by partial_done.
   if(g_state.be_move_time > 0 && bar_time > g_state.be_move_time)
      mctx.bars_since_BE_move = (int)((bar_time - g_state.be_move_time) / 900);
   else
      mctx.bars_since_BE_move = 0;
```

## `EvaluateOpenPosition` — dispatch the new actions

Replace the existing dispatch block (around lines 730-769 of `EA_AlligatorHA.mq5`) with:

```mql5
   const double tp = PositionGetDouble(POSITION_TP);
   const int    slip = CPositionManager::SlippagePoints(...);   // unchanged
   const double current_pos_lot = PositionGetDouble(POSITION_VOLUME);
   const double vol_min  = SymbolInfoDouble(pos_sym, SYMBOL_VOLUME_MIN);
   const double vol_step = SymbolInfoDouble(pos_sym, SYMBOL_VOLUME_STEP);

   bool action_ok = false;

   if(d.action == MA_TRAIL || d.action == MA_TIGHTEN_SL_LIPS)
     {
      //  Both are pure SL-modify actions. ModifySL preserves TP (passed in).
      Log.Info(StringFormat("MANAGE %s ticket=%I64u %s -> SL %.5f (%s)",
                             pos_sym, g_state.open_trade_ticket,
                             d.action == MA_TRAIL ? "TRAIL" : "TIGHTEN_SL_LIPS",
                             d.new_sl, d.reason), pos_sym);
      action_ok = CTradeManager::ModifySL(g_state.open_trade_ticket, d.new_sl, tp);
      if(!action_ok)
         Log.Error(StringFormat("MANAGE ModifySL failed ticket=%I64u", g_state.open_trade_ticket), pos_sym);
     }
   else if(d.action == MA_PARTIAL_AND_BE)
     {
      //  Three sub-cases by PartialLot result:
      const double partial_lot = CPositionManager::PartialLot(
         current_pos_lot, Partial_Close_Fraction, vol_min, vol_step);

      if(partial_lot <= 0.0)
        {
         //  Fraction=0.0 — skip the partial-close call, just ModifySL to BE+buffer (clear TP).
         Log.Info(StringFormat("MANAGE %s ticket=%I64u PARTIAL_AND_BE (Fraction=0, BE-only) -> SL %.5f (%s)",
                                pos_sym, g_state.open_trade_ticket, d.new_sl, d.reason), pos_sym);
         action_ok = CTradeManager::ModifySL(g_state.open_trade_ticket, d.new_sl, 0.0);  // TP=0 clears
         if(action_ok)
           {
            g_state.partial_done = true;
            g_state.be_move_time = bar_time;
           }
        }
      else if(partial_lot >= current_pos_lot - 1e-9)
        {
         //  Close-full path (Fraction=1.0 OR close-full fallback).
         //  Captures floating P/L before close; fires OnTPClose for streak; clears state inline.
         const double pre_close_profit = PositionGetDouble(POSITION_PROFIT);
         Log.Info(StringFormat("MANAGE %s ticket=%I64u PARTIAL_AND_BE (close-full at +%.1fR, P/L=%.2f)",
                                pos_sym, g_state.open_trade_ticket,
                                Partial_Close_Trigger_R, pre_close_profit), pos_sym);
         action_ok = CTradeManager::CloseAtMarket(g_state.open_trade_ticket, slip);
         if(action_ok)
           {
            CStreakManager::OnTPClose(g_state);
            CDailyLossManager::ApplyRealizedProfit(g_state, pre_close_profit, g_day_start_equity);
            g_state.open_trade_ticket   = 0;
            g_state.open_trade_cycle_id = "";
            g_state.partial_done        = false;   // trade is done; clear per-trade fields
            g_state.be_move_time        = 0;
            g_state.entry_R_distance    = 0.0;
            Log.Info(StringFormat("    partial-as-full-close: streak/cycle updated, daily_loss_pct=%.4f%%",
                                   g_state.daily_loss_pct));
           }
        }
      else
        {
         //  Normal split — atomic sequence: partial-close → ModifySL → flags → save.
         //  Capture pre-partial profit BEFORE the partial-close (POSITION_PROFIT is still on full lot).
         //  Scale to partial portion: pre_partial_profit ≈ POSITION_PROFIT × (partial_lot / current_lot).
         const double full_pos_profit  = PositionGetDouble(POSITION_PROFIT);
         const double partial_profit   = full_pos_profit * (partial_lot / current_pos_lot);
         Log.Info(StringFormat("MANAGE %s ticket=%I64u PARTIAL_AND_BE close=%.2f/%.2f at +%.1fR -> SL %.5f (P/L on partial=%.2f)",
                                pos_sym, g_state.open_trade_ticket,
                                partial_lot, current_pos_lot, Partial_Close_Trigger_R,
                                d.new_sl, partial_profit), pos_sym);

         //  Step 1: partial-close. Uses CTrade::PositionClosePartial. If a wrapper
         //  helper isn't already in PositionManager, add one with the same bounded-retry
         //  pattern as Place(). Otherwise call CTrade directly inline.
         CTrade trade;
         trade.SetExpertMagicNumber(Magic_Number);
         trade.SetDeviationInPoints(slip);
         const bool partial_ok = trade.PositionClosePartial(g_state.open_trade_ticket, partial_lot);
         if(!partial_ok)
           {
            Log.Error(StringFormat("    PartialClose FAILED retcode=%u %s",
                                    trade.ResultRetcode(), trade.ResultComment()), pos_sym);
            action_ok = false;
           }
         else
           {
            //  Step 2: ModifySL to BE+buffer, clear TP.
            const bool modify_ok = CTradeManager::ModifySL(g_state.open_trade_ticket, d.new_sl, 0.0);
            if(!modify_ok)
              {
               //  Half-state: partial booked but SL not moved. Log loud — DO NOT set partial_done
               //  in this branch (otherwise Decide would suppress future MA_TIGHTEN_SL_LIPS and
               //  the runner would be unprotected). Letting the next bar retry MA_PARTIAL_AND_BE
               //  is also wrong (would double-partial), so the safest move is:
               //  flag partial_done=true (consistent with the position's actual lot reduction),
               //  but record an explicit half-state log line so the user can manually fix the SL.
               //  Alternative: bias toward retry by NOT setting partial_done — accept the
               //  double-partial risk on the next bar. Decide which on first occurrence.
               Log.Error(StringFormat("    HALF-STATE: partial fired (lot %.2f closed) but ModifySL FAILED for ticket=%I64u — runner has no BE protection. Setting partial_done=true to avoid double-partial; please manually inspect.",
                                       partial_lot, g_state.open_trade_ticket), pos_sym);
               //  Still book the partial profit (the close actually happened):
               CStreakManager::OnTPClose(g_state);
               CDailyLossManager::ApplyRealizedProfit(g_state, partial_profit, g_day_start_equity);
               g_state.partial_done = true;
               g_state.be_move_time = bar_time;
               action_ok = true;   // partial actually happened — must persist state
              }
            else
              {
               //  Step 3: success. Book the partial as a TP win + apply realized profit + set flags.
               CStreakManager::OnTPClose(g_state);
               CDailyLossManager::ApplyRealizedProfit(g_state, partial_profit, g_day_start_equity);
               g_state.partial_done = true;
               g_state.be_move_time = bar_time;
               action_ok = true;
               Log.Info(StringFormat("    partial OK: streak +TP, daily_loss_pct=%.4f%%, runner=%.2f lots @ SL %.5f",
                                      g_state.daily_loss_pct,
                                      current_pos_lot - partial_lot, d.new_sl));
              }
           }
        }
     }
   else if(d.action == MA_CLOSE_FRIDAY || d.action == MA_CLOSE_NYOPEN)
     {
      //  Unchanged from pre-Stage-2 — time-based forced closes.
      const string label = (d.action == MA_CLOSE_FRIDAY) ? "CLOSE_FRIDAY" : "CLOSE_NYOPEN";
      const double pre_close_profit = PositionGetDouble(POSITION_PROFIT);
      Log.Info(StringFormat("MANAGE %s ticket=%I64u %s slip=%dpts (%s)",
                             pos_sym, g_state.open_trade_ticket, label, slip, d.reason), pos_sym);
      action_ok = CTradeManager::CloseAtMarket(g_state.open_trade_ticket, slip);
      if(action_ok)
        {
         const EForcedCloseReason fcr =
            (d.action == MA_CLOSE_FRIDAY) ? FCR_FRIDAY_CLOSE : FCR_NY_CARRYOVER;
         //  Stage 2: if partial_done is already true, the streak was booked at the partial moment.
         //  Forced-close on the runner only applies daily-loss, not streak. (Spec §5 — partial counts as the trade's outcome.)
         if(!g_state.partial_done)
            CStreakManager::OnForcedClose(g_state, fcr, Max_Streak_Length);
         CDailyLossManager::ApplyRealizedProfit(g_state, pre_close_profit, g_day_start_equity);
         g_state.open_trade_ticket   = 0;
         g_state.open_trade_cycle_id = "";
         g_state.partial_done        = false;
         g_state.be_move_time        = 0;
         g_state.entry_R_distance    = 0.0;
         Log.Info(StringFormat("    forced-close streak update: position=%d last_sl=%d (fcr=%d) profit=%.2f daily_loss_pct=%.4f%%",
                                g_state.streak_position, g_state.last_sl_count,
                                (int)fcr, pre_close_profit, g_state.daily_loss_pct));
        }
      else
         Log.Error(StringFormat("MANAGE CloseAtMarket failed ticket=%I64u", g_state.open_trade_ticket), pos_sym);
     }
   //  Note: no MA_MOVE_BE / MA_CLOSE_LIPS handlers — Decide never returns those post-Task-C,
   //  and Task D removes them from the enum.

   if(action_ok)
     {
      g_state.last_save_time = TimeGMT();
      State.Save(g_state, g_state_file);
     }
```

## `ResolveClosedPosition` — partial-vs-runner detection

In [EA_AlligatorHA.mq5](EA_AlligatorHA.mq5) around line 788+, the existing function handles broker-initiated SL/TP closes. Update to check `g_state.partial_done` and skip the streak hook for runner closes:

```mql5
      if(reason == DEAL_REASON_EXPERT)
        {
         //  Our own forced close — Friday flatten / NY carryover / partial close-full.
         //  The dispatch branch in EvaluateOpenPosition already updated streak inline.
         Log.Info("Resolve: EA-side close (already accounted)");
        }
      else if(g_state.partial_done)
        {
         //  Stage 2: runner closed (initial SL hit, trail SL hit, or TP hit on a leftover TP).
         //  Streak was booked at the partial moment — don't double-count. But DO apply realized
         //  profit for daily-loss tracking.
         CDailyLossManager::ApplyRealizedProfit(g_state, profit, g_day_start_equity);
         Log.Info(StringFormat("Resolve: ticket=%I64u runner closed by %s P/L=%.2f — streak unchanged (booked at partial)",
                                ticket, reason_str, profit));
        }
      else if(reason == DEAL_REASON_TP)
        {
         //  Pre-partial TP hit (the close-full path via Fraction=1.0 reaches here via DEAL_REASON_EXPERT,
         //  so this is the unmodified original-TP-hit path).
         CDailyLossManager::ApplyRealizedProfit(g_state, profit, g_day_start_equity);
         CStreakManager::OnTPClose(g_state);
         Log.Info("Resolve: TP -> cycle locked (mode now LOCKED)");
        }
      else if(reason == DEAL_REASON_SL)
        {
         CDailyLossManager::ApplyRealizedProfit(g_state, profit, g_day_start_equity);
         CStreakManager::OnSLClose(g_state, Max_Streak_Length);
         const ETradingMode m = CStreakManager::DeriveMode(g_state, Max_Streak_Length);
         Log.Info(StringFormat("Resolve: SL -> streak_position=%d last_sl=%d mode=%s",
                                g_state.streak_position, g_state.last_sl_count,
                                m == MODE_LOCKED ? "LOCKED" :
                                (m == MODE_RECOVERY ? "RECOVERY" : "DEFAULT")));
        }
```

After dispatch, also ensure the per-trade state fields are cleared. The caller (`EvaluateOpenPosition`'s "position no longer exists" branch around line 625) clears `open_trade_ticket`/`open_trade_cycle_id` already — extend it to also clear `partial_done`, `be_move_time`, `entry_R_distance`.

## Remove deprecated enum entries

In [Include/TradeManager.mqh](Include/TradeManager.mqh) lines 27-37, remove `MA_MOVE_BE = 1` and `MA_CLOSE_LIPS = 3`. The remaining values can keep their integer slots or be renumbered — renumbering is cleaner but unnecessary (no serialization of `EManageAction` exists). Updated enum:

```mql5
enum EManageAction
  {
   MA_NONE              = 0,
   MA_TRAIL             = 2,
   MA_CLOSE_FRIDAY      = 4,
   MA_CLOSE_NYOPEN      = 5,
   MA_PARTIAL_AND_BE    = 6,
   MA_TIGHTEN_SL_LIPS   = 7,
  };
```

Drop the DEPRECATED comments. The `Test_Decide_NeverReturnsDeprecatedEnums` test in `Test_TradeManager.mq5` should now be removed (or left as a guard against future regressions — the assertions `d.action != MA_MOVE_BE` and `d.action != MA_CLOSE_LIPS` won't compile if the enum values are gone). **Decision: remove the test entirely** — Task D's removal of the enum values makes the test trivially true at compile time, not a useful assertion.

## Remove `FCR_LIPS_BREAK` from `StreakManager.mqh`

In [Include/StreakManager.mqh](Include/StreakManager.mqh) lines 20-24, remove `FCR_LIPS_BREAK = 0`. Also remove the branch in `OnForcedClose` (line 102: `if(r == FCR_LIPS_BREAK) OnSLClose(state, max_streak);`). The remaining `FCR_FRIDAY_CLOSE` and `FCR_NY_CARRYOVER` are no-ops for streak (existing behavior) — `OnForcedClose` becomes effectively just a log-tracker after the FCR_LIPS_BREAK branch is gone. Consider whether `OnForcedClose` is still useful at all — Task D should leave it in place since the EA still calls it for Friday/NY-open forced closes (it's just a no-op for streak now). Don't refactor it away.

## Test updates summary

| Test file | Pre-D | Post-D | Delta |
|---|---|---|---|
| Test_StateManager | 39 | 43 | +4 (entry_R_distance: 1 init + 1 roundtrip + 1 legacy + sanity) |
| Test_PositionManager | 49 | 49 | 0 (no new pure helpers in Task D; `PartialLot` is already tested) |
| Test_TradeManager | 68 | 67 | −1 (remove `Test_Decide_NeverReturnsDeprecatedEnums` — assertion becomes compile-time) |
| Test_StreakManager | 28 | 28 (or 27) | 0 or −1 (if any test referenced `FCR_LIPS_BREAK`; check before removing) |

**Total post-D: ~330 asserts across the 14 test scripts** (Stage 1.1 baseline was ~285).

## Acceptance for Task D

User must compile + run all 14 test scripts; all green. Plus:

1. **Live smoke test on IC Markets demo:**
   - Attach EA, verify 3 new inputs appear on panel with correct defaults (`0.5`, `1.0`, `2`).
   - Verify `EA_State.json` contains `"partial_done": false`, `"be_move_time": "1970-01-01T00:00:00Z"`, `"entry_R_distance": 0.000` after first save.
   - Set `Partial_Close_Trigger_R=0.3` and `Risk_Position1=0.05` (temporary) so a trade reaches +0.3R within a few bars on any active pair.
   - Wait for a partial to fire. Expected log line: `MANAGE … PARTIAL_AND_BE close=0.01/0.02 at +0.3R -> SL …`. Verify state file updates: `partial_done: true`, `be_move_time` set, `entry_R_distance` retains the original value.
   - Wait 2+ bars after the partial. Expected: `MA_TRAIL` starts firing once `bars_since_BE_move ≥ 2` (with the default `Trail_Delay_Bars=2`).
   - Force-close the runner (e.g. manually) → verify `Resolve: ticket=... runner closed by … — streak unchanged (booked at partial)` log line.
   - Revert the overrides before any production work.

2. **Compile `EA_AlligatorHA.mq5` clean** (0 errors / 0 warnings). All 14 test scripts compile clean.

3. **Smoke test from a fresh state file** (delete `EA_State_*.json` first): verify the EA boots, runs, and the legacy-load path works for the new field.

4. **Backwards-compat smoke** (optional): copy a Stage-1.1 `EA_State.json` (which lacks `partial_done`/`be_move_time`/`entry_R_distance`) into the Files directory; attach the EA; verify `Adopt:` log shows best-effort `entry_R_distance` snapshot from `POSITION_PRICE_OPEN`/`POSITION_SL`.

## Task E — re-baseline backtest (after Task D)

Strategy Tester, EURUSD chart, M15, every-tick-real-ticks, $100k, 1:33, 2025-05-12 → 2026-05-11, `Verbose_Logging=false`, `Trade_Symbols`=6-symbol default.

**Two passes:**

1. `Partial_Close_Fraction = 0.5` (default recommended config). Document: final balance, PF, max DD, win rate, trade count, total swap, per-symbol P/L, exit-mode distribution, Type A/B mix, worst losing streak.

2. `Partial_Close_Fraction = 1.0` (1:1 RR sanity check). Same metrics. Tells us if the runner is adding value at all — if Fraction=1.0 outperforms Fraction=0.5, the no-TP runner design is hurting more than helping and we should pin Fraction at 1.0 (effectively reverting to "close at +1R, no runner").

**Walk-forward** (informational, not the headline): split into 8mo train + 4mo test. Train Stage 2 on the first 8mo with `Fraction=0.5`; freeze inputs; backtest the remaining 4mo. If the test period falls apart vs train, that's an over-fit signal — most likely from the `LipsBreak_Confirm_Bars=2` default flip.

Document everything in [docs/2026-05-13-path-a-stage2.md](2026-05-13-path-a-stage2.md) at the "Result" section.

## Parser trick: read .xlsx reports without copy-paste

This session demonstrated that the user's MT5 Strategy Tester `.xlsx` reports can be parsed directly without copy-pasting journal text. Use this pattern instead of asking the user to paste data:

```powershell
# Extract xlsx (it's a zip) to a temp dir
$xlsx = "<path>\<filename>.xlsx"
$tmp = Join-Path $env:TEMP ("xlsx_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($xlsx, $tmp)

# Parse sheet1.xml using shared-strings pool
$sheet = [xml](Get-Content "$tmp\xl\worksheets\sheet1.xml" -Raw)
$strings = [xml](Get-Content "$tmp\xl\sharedStrings.xml" -Raw)
$sstable = @($strings.sst.si | ForEach-Object {
   if ($_.t -is [System.Xml.XmlElement]) { $_.t.InnerText }
   elseif ($_.t) { $_.t }
   else { ($_.r | ForEach-Object { $_.t }) -join '' }
})

# Iterate rows. Each cell: $c.r=cell-ref, $c.t='s' means shared-string (lookup), else inline number.
# Filter rows by type:
#   - Settings rows: 1-69 (inputs)
#   - Results rows: 70-95 (PF, DD, win rate, trade count, etc.)
#   - Orders section: rows 115-744-ish (lots, prices, types)
#   - Deals section: after orders (in/out events with profit, swap, balance)
#
# For deals, filter on $cells['E'] == 'in' or 'out' (NOT a numeric volume — orders section has "0.16 / 0.16" there).
# Cast J/K/L to [double] ONLY inside the deals branch — order rows have datetime strings in J, which can't cast.
```

User's reports live in `MQL5/Experts/Alligator_Heiken_Ashi_EA/Reports/`. No need to read the journal for headline numbers — the trade list alone has everything (per-symbol P/L by summing deal profits grouped by symbol; exit-mode distribution by parsing the `M` column comment for `^sl ` / `^tp ` / blank).

## Open questions for next session

1. **Half-state on `ModifySL` failure after a successful partial close** — the dispatch above bias-sets `partial_done=true` and books the partial profit. The alternative (don't set partial_done, retry next bar) risks double-partial. The current design prioritizes correctness over recovery. If you encounter this in a real run, log it loudly and prefer the bias-set + manual-fix-required behavior. Revisit if the smoke test reveals a better recovery pattern.

2. **Should `Test_Decide_NeverReturnsDeprecatedEnums` be removed or kept as a regression guard?** The assertions become compile-time once the enum values are gone. Removing is cleaner. Keeping requires keeping the enum values too (just hidden behind comments) — defeats the point of Task D's cleanup. **Recommend: remove.**

3. **Trail buffer split** — code-quality review (Task C) flagged that `TightenLipsPrice` and `CalcTrailSL` share `Trail_ATR_Buffer`. Defensible (one knob, both behaviors), but if Task E backtest shows the tighten is too tight (premature SL hit pre-BE) or the trail is too loose (chops runners), consider splitting into two inputs. Not Task D's job — flag for the post-E review.

4. **`Test_StateManager` update for `entry_R_distance`** — the brief above asks for +4 asserts (init + roundtrip + legacy + sanity). Verify final count is 43 — that matches the test-file count math in the table above.

## File list for Task D

| File | Type of change |
|---|---|
| [Include/StateManager.mqh](Include/StateManager.mqh) | +1 field, +1 line each in InitDefault/Serialize/Load |
| [Include/TradeManager.mqh](Include/TradeManager.mqh) | Remove 2 enum values + DEPRECATED comments |
| [Include/StreakManager.mqh](Include/StreakManager.mqh) | Remove `FCR_LIPS_BREAK` value + its branch in `OnForcedClose` |
| [EA_AlligatorHA.mq5](../EA_AlligatorHA.mq5) | 3 new inputs + 2 default flips + ValidateInputs + entry_R_distance snapshot in 2 places + ManageContext population + dispatch rewrite + ResolveClosedPosition update |
| [../../Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_StateManager.mq5](../../../Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_StateManager.mq5) | +4 asserts for entry_R_distance |
| [../../Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_TradeManager.mq5](../../../Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_TradeManager.mq5) | Remove `Test_Decide_NeverReturnsDeprecatedEnums` + its OnStart() registration |
| [../../Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_StreakManager.mq5](../../../Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_StreakManager.mq5) | Remove any test that referenced `FCR_LIPS_BREAK` (verify by grep first) |
| [CLAUDE.md](../CLAUDE.md) | Update post-D — mark Tasks D done, add invariant updates if needed |
| [docs/2026-05-13-path-a-stage2.md](2026-05-13-path-a-stage2.md) | Fill in the "Result" section after Task E completes |

Estimated lines changed: ~250 across 7 files. ~5-10 lines of mechanical config; ~150 lines of dispatch logic in `EvaluateOpenPosition`; ~30 lines of new test fixtures; the rest is enum/struct cleanup.

## Pointers

- Parent design: [docs/2026-05-13-path-a-stage2.md](2026-05-13-path-a-stage2.md)
- Original execution plan: `~/.claude/plans/continue-path-a-lets-radiant-muffin.md`
- Project canonical status: [CLAUDE.md](../CLAUDE.md)
- Stage 1.1 design (for the input-label convention demonstrated in commit `db3f650`): [docs/2026-05-12-path-a-stage1.md](2026-05-12-path-a-stage1.md)
- Original spec: [EA_Action_Plan.md](../EA_Action_Plan.md) — architecture / FTMO / state / edges hold; params + strategy details advisory under Path A
