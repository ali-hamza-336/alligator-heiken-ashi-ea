# Stage 2 Approach C Revert — Plan for Next Session

**Date:** 2026-05-15
**Status:** designed, ready to implement
**Audience:** next session's Claude, picking this up cold

**Read before starting:**
1. [docs/2026-05-13-path-a-stage2.md](2026-05-13-path-a-stage2.md) — **Result section first** (the 3-way audit that motivates this revert).
2. [CLAUDE.md](../CLAUDE.md) "Project status" — current Stage 2 Task D state.

## Why this revert exists

Stage 2 shipped 9 commits (`7ca91e4` → `643de78`) over Task D + cleanup + input-label work. Task E's backtest then proved Stage 2 is a −$4,213 regression vs Stage 1.1 (`+$2,474 → −$1,739` at Approach C alone, files 9–12 in `Reports/`). The 3-way audit isolated `MA_TIGHTEN_SL_LIPS` (Approach C) as the dominant cost.

The revert restores **Stage 1.1's `MA_CLOSE_LIPS` market-close behaviour** as the action for confirmed Lips breaks. The Stage-2 partial-close + trail-delay infrastructure stays in the codebase (state schema, dispatch sub-cases, tests) but goes **dormant by default** so it can be re-enabled cleanly for future experiments without ripping out the plumbing.

## Heads-up: most of the revert is already done in the working tree (unstaged)

A previous Claude session got stuck but completed ~90% of the code revert before stopping. As of session start, **3 files have unstaged edits** matching this plan:

- `Include/TradeManager.mqh` — enum change (1) + Decide rewrite (1) done.
- `Include/StreakManager.mqh` — enum change (2) + OnForcedClose branch (2) done.
- `EA_AlligatorHA.mq5` — default flips (4) + dispatch branch (3) done. The dispatch piece is integrated into the existing `MA_CLOSE_FRIDAY || MA_CLOSE_NYOPEN` block rather than as a standalone `else if(MA_CLOSE_LIPS)` — same end behaviour, less code duplication.

Run `git diff` on those 3 files before doing anything. The edits are coherent, follow the same style as surrounding code, and match this plan's intent. **What's NOT done:** tests (change 5) + acceptance verification.

**Recommended path:** keep the unstaged edits, do the test updates (below), compile + run tests + backtest, commit as one bundle. If on inspection the diff doesn't look right, `git checkout` the 3 files and start fresh from this plan — the cost is rewriting ~60 lines of code.

## Required changes (full list)

### 1. `Include/TradeManager.mqh` (`EManageAction` enum + `Decide`)

**Enum:** restore `MA_CLOSE_LIPS = 3`. Mark `MA_TIGHTEN_SL_LIPS` as dead code (kept in enum so existing dispatch + tests still compile, but `Decide` never returns it). Mark `MA_PARTIAL_AND_BE` as "dormant at default" (still functional, just never fires when `Partial_Close_Trigger_R=3.0`).

```mql5
enum EManageAction
  {
   MA_NONE              = 0,
   MA_TRAIL             = 2,
   MA_CLOSE_LIPS        = 3,   // Stage 1.1 (restored 2026-05-15): market close on confirmed Lips break
   MA_CLOSE_FRIDAY      = 4,
   MA_CLOSE_NYOPEN      = 5,
   MA_PARTIAL_AND_BE    = 6,   // Stage 2: dormant at Trigger_R=3.0 default (no trade reaches +3R)
   MA_TIGHTEN_SL_LIPS   = 7,   // Stage 2: DEAD CODE — Decide no longer returns this (Approach C reverted)
  };
```

**Decide():** rewrite the Lips-break branch (post-`MA_PARTIAL_AND_BE` gate, pre-`MA_TRAIL` gate) to return `MA_CLOSE_LIPS`. Drop the `IsImprovement` / `TightenLipsPrice` call. Keep all Phase-8 softening gates (`bars_since_entry >= min_hold`, `IsBeyondLips(...,buf)`, N-bar confirm).

```mql5
   if(!ctx.partial_done && ctx.bars_since_entry >= ctx.lips_break_min_hold_bars)
     {
      const double lb_buf = ctx.lips_break_atr_buffer * ctx.atr_m15_s1;
      bool broken = IsBeyondLips(ctx.is_buy, ctx.close_m15_s1, ctx.lips_m15_s1, lb_buf);
      if(broken && ctx.lips_break_confirm_bars >= 2)
         broken = IsBeyondLips(ctx.is_buy, ctx.close_m15_s2, ctx.lips_m15_s2, lb_buf);
      if(broken && ctx.lips_break_confirm_bars >= 3)
         broken = IsBeyondLips(ctx.is_buy, ctx.close_m15_s3, ctx.lips_m15_s3, lb_buf);
      if(broken)
        {
         d.action = MA_CLOSE_LIPS;
         d.new_sl = 0.0;
         d.reason = StringFormat("Lips break -> market close: close=%.5f %s lips=%.5f (buf=%.5f confirm=%d)",
                                 ctx.close_m15_s1, ctx.is_buy ? "<" : ">", ctx.lips_m15_s1,
                                 lb_buf, ctx.lips_break_confirm_bars);
         return d;
        }
     }
```

**Note:** `TightenLipsPrice()` helper stays in the file as dead code. Removing it would also require removing its tests. Cheaper to leave it; flag for cleanup if you also rip out `MA_TIGHTEN_SL_LIPS` from the enum later.

### 2. `Include/StreakManager.mqh` (`EForcedCloseReason` enum + `OnForcedClose`)

**Enum:** restore `FCR_LIPS_BREAK = 0`.

```mql5
enum EForcedCloseReason
  {
   FCR_LIPS_BREAK   = 0,   // Stage 1.1 (restored 2026-05-15): forced close on Lips break advances streak as a loss
   FCR_FRIDAY_CLOSE = 1,
   FCR_NY_CARRYOVER = 2,
  };
```

**OnForcedClose():** restore the `FCR_LIPS_BREAK → OnSLClose` branch.

```mql5
void CStreakManager::OnForcedClose(EAState &state, const EForcedCloseReason r,
                                   const int max_streak)
  {
   if(r == FCR_LIPS_BREAK) OnSLClose(state, max_streak);
   //  FCR_FRIDAY_CLOSE / FCR_NY_CARRYOVER: no-op for streak.
   //  NOTE: when adding new EForcedCloseReason values, add an explicit else-if here.
  }
```

### 3. `EA_AlligatorHA.mq5` (`EvaluateOpenPosition` dispatch)

Currently has branches for `MA_TRAIL || MA_TIGHTEN_SL_LIPS`, `MA_PARTIAL_AND_BE` (three sub-cases), and `MA_CLOSE_FRIDAY || MA_CLOSE_NYOPEN`. **Add a `MA_CLOSE_LIPS` branch** between the partial branch and the Friday/NY branch.

```mql5
   else if(d.action == MA_CLOSE_LIPS)
     {
      const double pre_close_profit = PositionGetDouble(POSITION_PROFIT);
      Log.Info(StringFormat("MANAGE %s ticket=%I64u CLOSE_LIPS slip=%dpts (%s)",
                             pos_sym, g_state.open_trade_ticket, slip, d.reason), pos_sym);
      action_ok = CTradeManager::CloseAtMarket(g_state.open_trade_ticket, slip);
      if(action_ok)
        {
         //  Stage 1.1 semantic: Lips break advances streak as a loss (FCR_LIPS_BREAK -> OnSLClose).
         //  Skip when partial_done is already true (runner close after a partial; streak booked at partial).
         if(!g_state.partial_done)
            CStreakManager::OnForcedClose(g_state, FCR_LIPS_BREAK, Max_Streak_Length);
         CDailyLossManager::ApplyRealizedProfit(g_state, pre_close_profit, g_day_start_equity);
         g_state.open_trade_ticket   = 0;
         g_state.open_trade_cycle_id = "";
         g_state.partial_done        = false;
         g_state.be_move_time        = 0;
         g_state.entry_R_distance    = 0.0;
         Log.Info(StringFormat("    Lips-break close: streak position=%d last_sl=%d profit=%.2f daily_loss_pct=%.4f%%",
                                g_state.streak_position, g_state.last_sl_count,
                                pre_close_profit, g_state.daily_loss_pct));
        }
      else
         Log.Error(StringFormat("MANAGE CloseAtMarket failed ticket=%I64u", g_state.open_trade_ticket), pos_sym);
     }
```

This mirrors the existing `MA_CLOSE_FRIDAY || MA_CLOSE_NYOPEN` block's structure verbatim, just with `FCR_LIPS_BREAK` and a different log label.

### 4. Flip defaults to make Stage-2 infrastructure dormant

In the inputs block of `EA_AlligatorHA.mq5`:

```mql5
input double  Trail_ATR_Buffer       = 0.3;       // was 0.5; Stage 1.1 default restored
input int     LipsBreak_Confirm_Bars = 2;         // unchanged from Stage 2 (Phase-8 tuned-good)

//--- Stage 2 infrastructure (kept in code, dormant by default after Approach C revert)
input double  Partial_Close_Fraction  = 0.5;      // unused at default Trigger_R=3.0
input double  Partial_Close_Trigger_R = 3.0;      // was 1.0; at 3.0 the partial branch never fires
                                                  //   on this signal generator (no trade reaches +3R)
input int     Trail_Delay_Bars        = 2;        // unused when partial is dormant (MA_TRAIL is partial_done-gated)
```

Range checks in `ValidateInputs` already accept `Partial_Close_Trigger_R` up to 3.0 — no change needed.

**Why keep `Partial_Close_Trigger_R=3.0` instead of removing the input:** Files 9–12 prove no trade reaches +3R on this signal generator + 12-mo sample. The branch is effectively a no-op at this default. Removing the input would require ripping out `MA_PARTIAL_AND_BE` dispatch + state fields + tests — high cost for no behavioural benefit. Leaving it dormant lets us flip to a positive value for experimentation later.

### 5. Test updates

**`Test_TradeManager.mq5`:**

- Rewrite tests that previously expected `MA_TIGHTEN_SL_LIPS` → now expect `MA_CLOSE_LIPS`. The Lips-break trigger semantics are unchanged; only the return action differs.
  - Functions affected (from Task C's test suite): `Decide_TightenSL_Buy/Sell`, `Decide_TightenSL_ClampToEntry_*`, `Decide_NoLipsBreakPostBE`, `Decide_PartialAndBE_BeatsTightenLips`.
  - Rename or repurpose to `Decide_CloseLips_*`.
- `TightenLipsPrice_*` pure-helper tests: keep them. The helper is dead code in production but still pure and correct; the tests document the formula in case Approach C is ever resurrected.
- Don't add new tests — restoring `MA_CLOSE_LIPS` doesn't introduce new pure logic, just a return-value change.
- Expected count post-revert: somewhere around 56–62 asserts depending on how aggressively you rename vs delete. Pin the number in the commit message.

**`Test_StreakManager.mq5`:**

- Restore a test for `FCR_LIPS_BREAK` advancing the streak. Task 7 deleted `Test_Forced_LipsBreakAdvancesStreak` as redundant; restore equivalent coverage:

```mql5
void Test_Forced_LipsBreakAdvancesStreak()
  {
   Print("[Test_Forced_LipsBreakAdvancesStreak]");
   EAState s = MakeFresh();
   CStreakManager::OnForcedClose(s, FCR_LIPS_BREAK, 3);
   AssertEqInt(s.last_sl_count, 1, "Lips-break: last_sl_count = 1");
   AssertEqInt(s.streak_position, 2, "Lips-break: streak_position advances to 2");
  }
```

Add the registration line in `OnStart()`.

Expected count: 28 (was 26 after Task 7's cleanup; +2 for the restored Lips-break asserts).

### 6. CLAUDE.md updates after revert ships

- Add a project-status bullet: "Path A Stage 2 Approach C reverted (2026-05-15): MA_CLOSE_LIPS restored, FCR_LIPS_BREAK restored, Stage-2 partial infrastructure dormant via Trigger_R=3.0 default. Backtest reproduces +$2,474 Stage 1.1 number."
- Update invariants #16 + #17: #16 reverts to Stage 1.1 semantics for the action ("Lips break market-closes"); #17 stays as documentation of the Stage-2 priority order with a note that `MA_TIGHTEN_SL_LIPS` is dead code.
- Update the file layout test counts:
  - Test_TradeManager: ~62 → ~56–58 (depending on rename decision)
  - Test_StreakManager: 26 → 28
- Update the "Heads-up for the next session" pending list: revert done → walk-forward Stage 1.1 baseline next.

## Acceptance criteria

1. EA compiles 0 errors / 0 warnings.
2. All 14 test scripts green. Expected post-revert counts:
   - Test_StateManager: 42/42 (unchanged)
   - Test_PositionManager: 49/49 (unchanged)
   - Test_TradeManager: ~56–58/56–58 (was 62; revert drops tests that asserted MA_TIGHTEN_SL_LIPS specifically)
   - Test_StreakManager: 28/28 (was 26; +2 for FCR_LIPS_BREAK)
   - Other 10 scripts: unchanged.
3. Backtest re-baselined to within $200 of **+$2,474** on the 12-mo 6-symbol config. (Some drift is OK — broker tick data may have shifted slightly since Stage 1.1's original run.)
4. **Walk-forward** as the final acceptance: 8mo train (2025-05-12 → 2026-01-11) + 4mo test (2026-01-12 → 2026-05-11). If the 4mo test holds positive expectancy, +$2,474 is robust. If it falls apart, the 12-mo headline was over-fit and we re-evaluate whether to keep tuning.

## Out of scope (deferred)

- Removing `MA_PARTIAL_AND_BE` / `MA_TIGHTEN_SL_LIPS` from the enum entirely. Defer until/unless a future experiment confirms the partial-and-BE mechanism is permanently abandoned. Dormant code is cheaper to maintain than re-implement.
- Removing `entry_R_distance` from `EAState`. Same reason — the schema field is harmless when not used, and ripping it out would break the legacy-load path.
- Walk-forward of any Stage 2 config. The revert backtest IS the relevant comparison; Stage 2 configs are all known to be negative.
- Stage 3 (entry tightening). Only worth considering once Stage 1.1 walk-forward confirms the baseline. If +$2,474 collapses out-of-sample, the entire signal generator needs re-evaluation, not just the entries.

## Estimated effort

- Code changes: ~60 lines across 3 files (enum/Decide in TradeManager, enum/OnForcedClose in StreakManager, dispatch branch in EA).
- Test changes: ~30 lines (rename ~5 tests in Test_TradeManager, restore 1 test in Test_StreakManager).
- One backtest run to verify the +$2,474 reproduces.
- One walk-forward run (set tester date range, single run).
- Total: ~1 hour focused work plus the backtest wait times.

## Suggested commit sequence (single working session)

1. `git checkout Include/TradeManager.mqh` if the partial revert from the prior session looks wrong, OR keep it and just complete the other pieces.
2. Apply changes 1–5 above (TradeManager + StreakManager + EA dispatch + input defaults + tests).
3. User compiles + runs all 14 test scripts → confirm green.
4. User runs the 12-mo backtest → confirm ~+$2,474.
5. Single commit: `"Path A Stage 2: revert Approach C, restore MA_CLOSE_LIPS"`.
6. User runs walk-forward 8mo/4mo.
7. Update CLAUDE.md (project status + invariants + file layout + heads-up).
8. Second commit: `"Path A Stage 2: post-revert status + walk-forward result"`.
9. Push the bundle.
