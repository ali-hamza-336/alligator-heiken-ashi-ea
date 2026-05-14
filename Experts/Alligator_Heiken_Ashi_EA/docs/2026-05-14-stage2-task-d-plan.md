# Path A Stage 2 Task D — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the Stage-2 exit-rework (Tasks A/B/C already shipped) into the EA orchestrator and remove the deprecated `MA_MOVE_BE` / `MA_CLOSE_LIPS` / `FCR_LIPS_BREAK` symbols.

**Architecture:** Six narrow EA edits + one enum cleanup. State-schema add (`entry_R_distance`), three new inputs + two default flips, snapshot at entry, populate Stage-2 fields in `ManageContext`, rewrite the `EvaluateOpenPosition` dispatch (new `MA_PARTIAL_AND_BE` three-sub-case + `MA_TIGHTEN_SL_LIPS`), update `ResolveClosedPosition` for runner-after-partial, then drop dead enum entries. Design + atomicity rationale already settled in [2026-05-14-stage2-task-d-handoff.md](2026-05-14-stage2-task-d-handoff.md) — this plan is the execution decomposition only.

**Tech Stack:** MQL5 (MetaTrader 5); test scripts in `Scripts/Alligator_Heiken_Ashi_EA_Tests/`; user is the test runner (Claude cannot compile/run MT5 itself).

**TDD note:** Steps that touch pure logic in `StateManager.mqh` are test-first. Steps that wire the EA against MT5 broker APIs (`PositionGetDouble`, `CTrade::PositionClosePartial`, `History*`) are integration-only — the user verifies via live attach + paste of logs. The handoff doc and the "Smoke test" task at the end of this plan are the integration acceptance.

**Background reading before starting:**
- [docs/2026-05-14-stage2-task-d-handoff.md](2026-05-14-stage2-task-d-handoff.md) — full design + atomicity recipe + open questions.
- [docs/2026-05-13-path-a-stage2.md](2026-05-13-path-a-stage2.md) — Stage 2 architectural overview.
- [CLAUDE.md](../CLAUDE.md) "Cross-cutting invariants" #7 (IsImprovement), #10 (zero-close), #11 (state-mutation locations), #16 (Lips softening defaults), #17 (Stage 2 Decide priority), #18 (Partial atomicity).

---

### Task 1: State schema — add `entry_R_distance`

**Files:**
- Modify: `Include/StateManager.mqh` (struct, `InitDefault`, `Serialize`, `Load`)
- Modify: `Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_StateManager.mq5` (Test_InitDefault, Test_Roundtrip, Test_LoadLegacyMissingFields)

- [ ] **Step 1.1: Write the failing test additions**

In [Test_StateManager.mq5](../../../Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_StateManager.mq5):

`Test_InitDefault` (around line 43 — append a single assert at the end of the function, right before its closing `}`):

```mql5
   AssertEqDbl(s.entry_R_distance, 0.0, 1e-9, "default entry_R_distance");
```

`Test_Roundtrip` (around line 64) — set the field on the writer struct before `Save`, and assert it on the reader struct after `Load`. Find the existing `w.initial_balance = ...; w.partial_done = ...; w.be_move_time = ...;` cluster and add a line:

```mql5
   w.entry_R_distance = 0.00500;
```

Then in the read-back block, add:

```mql5
   AssertEqDbl(r.entry_R_distance, 0.005, 1e-6, "entry_R_distance roundtrip");
```

`Test_LoadLegacyMissingFields` (around line 199) — the legacy-JSON fixture already omits the new field by construction. Add at the assertion section (after the existing `initial_balance == 0` / `partial_done == false` / `be_move_time == 0` asserts):

```mql5
   AssertEqDbl(r.entry_R_distance, 0.0, 1e-9, "legacy load: entry_R_distance defaults to 0");
```

Expected after Step 1.1: 3 new asserts (1 init + 1 roundtrip + 1 legacy). Test_StateManager goes 39 → 42 asserts. (Handoff doc said "+4" because the legacy fixture added one structural assert too — we'll add a 4th below if the legacy JSON literal doesn't already need adjustment; check the body when editing.)

- [ ] **Step 1.2: Run the test to verify it fails to compile**

User compiles `Test_StateManager.mq5`. Expected: **compile error** — `'entry_R_distance' - some operator expected` or similar, because `EAState` doesn't have the field yet. This is the failing-test signal in MQL5 (no field → struct-access compile error).

- [ ] **Step 1.3: Add the struct field**

In [Include/StateManager.mqh](Include/StateManager.mqh) at line 25 (between `be_move_time` and `last_save_time`):

```mql5
   datetime be_move_time;             // Stage 2: bar time at which MA_PARTIAL_AND_BE moved SL to BE
   double   entry_R_distance;         // Stage 2: |entry - initial_sl|, snapshotted at fill; survives partial/tighten SL moves
   datetime last_save_time;
```

- [ ] **Step 1.4: Update `InitDefault`**

In `CStateManager::InitDefault` (around line 51) add one line after the `partial_done` / `be_move_time` zeros:

```mql5
   state.entry_R_distance    = 0.0;
```

- [ ] **Step 1.5: Update `Serialize`**

In `CStateManager::Serialize` (around line 161) add one line before `last_save_time`, after the `be_move_time` emit:

```mql5
   s += StringFormat("  \"entry_R_distance\": %.5f,\n",     state.entry_R_distance);
```

- [ ] **Step 1.6: Update `Load`**

In `CStateManager::Load` (around line 138) add one line in the optional-extract block after the `be_move_time` line:

```mql5
   if(ExtractDouble(body, "entry_R_distance", l_dbl)) state.entry_R_distance = l_dbl; // legacy files lack it -> stays 0
```

- [ ] **Step 1.7: Run the tests to verify GREEN**

User compiles `Test_StateManager.mq5` (must compile clean) and runs it as a Script. Expected log:

```
===== Done. passed=42 failed=0 =====
```

(7 test functions, 42 asserts total post-Task-1.) If a 4th legacy assertion was needed for the JSON literal, count goes to 43 — note final number in commit message.

- [ ] **Step 1.8: Commit**

```bash
git add Include/StateManager.mqh Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_StateManager.mq5
git commit -m "Path A Stage 2 Task D step 1: add entry_R_distance to EAState

Snapshotted at fill, persists across partial/tighten SL moves so the
+trigger_R compute in Decide always uses the original R. Legacy-load
pattern matches initial_balance / partial_done / be_move_time."
```

---

### Task 2: New inputs + default flips + `ValidateInputs`

**Files:**
- Modify: `EA_AlligatorHA.mq5` (inputs block lines 67-73; `ValidateInputs` lines 941-970)

No new tests — these are mechanical input declarations with range checks already covered by manual test on EA attach.

- [ ] **Step 2.1: Flip the two existing defaults**

In [EA_AlligatorHA.mq5](EA_AlligatorHA.mq5):

Line 67 — change `0.3` to `0.5`:

```mql5
input double  Trail_ATR_Buffer       = 0.5;
```

Line 72 — change `1` to `2`:

```mql5
input int     LipsBreak_Confirm_Bars = 2;         // 2 = Phase-8 tuned-good; 1 = spec §3.4; 3 = stricter
```

(Update the inline `// comment` so the panel-display name reflects the new default. Keep it short.)

- [ ] **Step 2.2: Add three new inputs**

After line 73 (`LipsBreak_Min_Hold_Bars`) and before line 75 (`//--- TREND/STRENGTH FILTERS`), insert:

```mql5
//--- Stage 2 (Path A): partial-close-at-+1R spectrum + trail-delay gate
//--- See docs/2026-05-13-path-a-stage2.md. Fraction=0 → BE-only (no partial);
//--- Fraction=1 → 1:1 RR baseline; default 0.5 banks half, runner trails.
input double  Partial_Close_Fraction  = 0.5;      // Partial size at +1R (0..1)
input double  Partial_Close_Trigger_R = 1.0;      // Partial fires at +N*R
input int     Trail_Delay_Bars        = 2;        // M15 bars post-BE before trail starts
```

- [ ] **Step 2.3: Add range checks in `ValidateInputs`**

In `ValidateInputs` (around line 968, after the `Max_Lot > 0` check, before `return true;`):

```mql5
   if(Partial_Close_Fraction < 0.0 || Partial_Close_Fraction > 1.0)
      { Log.Error("Partial_Close_Fraction must be in [0.0, 1.0]"); return false; }
   if(Partial_Close_Trigger_R < 0.5 || Partial_Close_Trigger_R > 3.0)
      { Log.Error("Partial_Close_Trigger_R must be in [0.5, 3.0]"); return false; }
   if(Trail_Delay_Bars < 0 || Trail_Delay_Bars > 10)
      { Log.Error("Trail_Delay_Bars must be in [0, 10]"); return false; }
```

- [ ] **Step 2.4: Verify EA compiles**

User compiles `EA_AlligatorHA.mq5`. Expected: **0 errors / 0 warnings**. The compile is the test for this step — at this point the EA still references the deprecated enum values, so it will still build cleanly (those values exist in the enum, Task 7 removes them).

If compile fails with "undeclared identifier Partial_Close_*", check that the input block placement is above `ValidateInputs`.

- [ ] **Step 2.5: Commit**

```bash
git add EA_AlligatorHA.mq5
git commit -m "Path A Stage 2 Task D step 2: 3 new inputs + flip Trail_ATR_Buffer 0.3->0.5, LipsBreak_Confirm_Bars 1->2

Bakes the Phase-8 tuned-good values + Stage-2 design defaults into
the code. Spec §9 deviation sanctioned under Path A (CLAUDE.md)."
```

---

### Task 3: Snapshot `entry_R_distance` at entry + adopt + clear on close

**Files:**
- Modify: `EA_AlligatorHA.mq5` (`TryEnterSignal` ~line 458; `AdoptOpenPosition` ~line 521; `EvaluateOpenPosition` ~line 625 "position no longer exists" branch)

Again no new pure-logic tests — these are field assignments verified by the live smoke test in Task 8 + the existing state roundtrip test in Task 1.

- [ ] **Step 3.1: Snapshot at fill in `TryEnterSignal`**

In `EA_AlligatorHA.mq5` around line 458 (after `g_state.open_trade_ticket = res.ticket;`, before `State.Save(...)`):

```mql5
   //--- Persist immediately. StateManager.Save is atomic (spec §14 #5).
   g_state.open_trade_ticket   = res.ticket;
   g_state.open_trade_cycle_id = CycleIdNow();
   if(StringLen(g_state.current_cycle_id) == 0)
      g_state.current_cycle_id = g_state.open_trade_cycle_id;
   g_state.trades_taken_today += 1;
   //--- Stage 2: snapshot original R for the +trigger_R compute. Belt-and-braces
   //--- reset the per-trade flags in case a prior close took an unusual path.
   g_state.entry_R_distance    = MathAbs(plan.entry - plan.sl);
   g_state.partial_done        = false;
   g_state.be_move_time        = 0;
   g_state.last_save_time      = TimeGMT();
   if(!State.Save(g_state, g_state_file))
      Log.Error("    state save after fill FAILED", sym);
```

- [ ] **Step 3.2: Best-effort adopt in `AdoptOpenPosition`**

In `AdoptOpenPosition` around line 521 (just before the `if(g_state.open_trade_ticket == t)` "state matches live" branch and the "reconcile" branch — i.e. in the common path of "exactly one live position"):

```mql5
   //--- exactly one live position
   const ulong  t   = live_tickets[0];
   const string sym = live_syms[0];

   //--- Stage 2: best-effort restore of entry_R_distance / partial_done / be_move_time
   //--- if state lacks them (legacy file or post-crash recovery). Underestimates the
   //--- original R if SL has been modified mid-trade (BE/tighten/trail) — acceptable
   //--- for a recovery path. Reads via PositionSelectByTicket to access POSITION_*.
   if(PositionSelectByTicket(t))
     {
      const double entry_p  = PositionGetDouble(POSITION_PRICE_OPEN);
      const double sl_now   = PositionGetDouble(POSITION_SL);
      const bool   is_buy   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(g_state.entry_R_distance <= 0 && entry_p > 0 && sl_now > 0)
         g_state.entry_R_distance = MathAbs(entry_p - sl_now);
      if(!g_state.partial_done && sl_now > 0 && entry_p > 0)
        {
         //  SL already past entry => assume BE move already happened upstream.
         //  Conservative: set be_move_time to now so trail-delay starts fresh.
         const bool sl_past_entry = is_buy ? (sl_now >= entry_p) : (sl_now <= entry_p);
         if(sl_past_entry)
           {
            g_state.partial_done = true;
            g_state.be_move_time = TimeCurrent();
            Log.Info(StringFormat("Adopt: BE-already-moved heuristic -> partial_done=true be_move_time=now (entry=%.5f sl=%.5f)", entry_p, sl_now));
           }
        }
     }

   if(g_state.open_trade_ticket == t)
     { ... }
```

(Leave the existing `if(g_state.open_trade_ticket == t)` and reconcile-mismatch branches untouched below this block.)

- [ ] **Step 3.3: Clear per-trade fields when position-no-longer-exists**

In `EvaluateOpenPosition` around line 622-630 (the "position no longer exists" branch):

```mql5
   if(!PositionSelectByTicket(g_state.open_trade_ticket))
     {
      Log.Warn(StringFormat("Manage: ticket=%I64u no longer exists — resolving close",
                             g_state.open_trade_ticket));
      ResolveClosedPosition(g_state.open_trade_ticket);
      g_state.open_trade_ticket   = 0;
      g_state.open_trade_cycle_id = "";
      g_state.partial_done        = false;   // Stage 2: clear per-trade flags
      g_state.be_move_time        = 0;
      g_state.entry_R_distance    = 0.0;
      g_state.last_save_time      = TimeGMT();
      State.Save(g_state, g_state_file);
      return true;
     }
```

- [ ] **Step 3.4: Verify EA compiles clean**

User compiles. Expected: 0/0.

- [ ] **Step 3.5: Commit**

```bash
git add EA_AlligatorHA.mq5
git commit -m "Path A Stage 2 Task D step 3: snapshot entry_R_distance at fill, best-effort adopt, clear on close

TryEnterSignal sets entry_R_distance = |entry - sl| and resets
partial_done/be_move_time. AdoptOpenPosition best-effort restores
from POSITION_PRICE_OPEN/POSITION_SL; if SL is past entry assumes
BE already happened (sets be_move_time=now). Position-no-longer-exists
branch clears all three per-trade fields."
```

---

### Task 4: `ManageContext` population

**Files:**
- Modify: `EA_AlligatorHA.mq5` (`EvaluateOpenPosition` around lines 657-676)

No tests — purely caller-side context population. Behavioral verification is via Tasks 5 and 8.

- [ ] **Step 4.1: Populate the 5 Stage-2 fields**

In `EvaluateOpenPosition` around line 676 (after the `mctx.close_m15_s3 = 0; mctx.lips_m15_s3 = 0;` line, before the `if(same_sym)` block):

```mql5
   mctx.close_m15_s3 = 0; mctx.lips_m15_s3 = 0;
   //--- Stage 2: partial-close-and-BE + trail-delay context
   mctx.partial_done            = g_state.partial_done;
   mctx.partial_close_trigger_R = Partial_Close_Trigger_R;
   mctx.trail_delay_bars        = Trail_Delay_Bars;
   mctx.entry_R_distance        = g_state.entry_R_distance;
   //  bars_since_BE_move: 0 until BE move; thereafter (bar_time - be_move_time)/900.
   //  Pre-BE bars_since_BE_move is unused by Decide (MA_TRAIL is gated by partial_done).
   if(g_state.be_move_time > 0 && bar_time > g_state.be_move_time)
      mctx.bars_since_BE_move = (int)(((long)bar_time - (long)g_state.be_move_time) / 900);
   else
      mctx.bars_since_BE_move = 0;
```

- [ ] **Step 4.2: Verify EA compiles**

User compiles. Expected: 0/0.

- [ ] **Step 4.3: Commit**

```bash
git add EA_AlligatorHA.mq5
git commit -m "Path A Stage 2 Task D step 4: populate Stage-2 ManageContext fields

partial_done from g_state; trigger_R + trail_delay from inputs;
entry_R_distance from state; bars_since_BE_move from
(bar_time - g_state.be_move_time)/900 with pre-BE 0 fallback."
```

---

### Task 5: Dispatch rewrite — `MA_TIGHTEN_SL_LIPS` + `MA_PARTIAL_AND_BE` + remove dead branches

**Files:**
- Modify: `EA_AlligatorHA.mq5` (`EvaluateOpenPosition` dispatch block, lines ~730-769)

This is the **largest single edit** in Task D. Invariant #18 (CLAUDE.md) is the load-bearing rule — read it before writing the partial branch. No new unit tests — `Decide` is already covered by Test_TradeManager 68/68; this step is the EA-side dispatch only, verified live in Task 8.

- [ ] **Step 5.1: Replace the dispatch block (lines 730-769)**

Find this block in `EvaluateOpenPosition`:

```mql5
   bool action_ok = false;
   if(d.action == MA_MOVE_BE || d.action == MA_TRAIL)
     {
      Log.Info(StringFormat("MANAGE %s ticket=%I64u %s -> SL %.5f (%s)",
                             pos_sym, g_state.open_trade_ticket,
                             d.action == MA_MOVE_BE ? "BE" : "TRAIL",
                             d.new_sl, d.reason), pos_sym);
      action_ok = CTradeManager::ModifySL(g_state.open_trade_ticket, d.new_sl, tp);
      ...
     }
   else
     {
      const string label =
         (d.action == MA_CLOSE_LIPS  ) ? "CLOSE_LIPS"   :
         (d.action == MA_CLOSE_FRIDAY) ? "CLOSE_FRIDAY" : "CLOSE_NYOPEN";
      ...
      const EForcedCloseReason fcr =
         (d.action == MA_CLOSE_LIPS)   ? FCR_LIPS_BREAK :
         (d.action == MA_CLOSE_FRIDAY) ? FCR_FRIDAY_CLOSE :
                                         FCR_NY_CARRYOVER;
      CStreakManager::OnForcedClose(g_state, fcr, Max_Streak_Length);
      ...
     }
```

Replace with:

```mql5
   const double current_pos_lot = PositionGetDouble(POSITION_VOLUME);
   const double vol_min  = SymbolInfoDouble(pos_sym, SYMBOL_VOLUME_MIN);
   const double vol_step = SymbolInfoDouble(pos_sym, SYMBOL_VOLUME_STEP);

   bool action_ok = false;

   if(d.action == MA_TRAIL || d.action == MA_TIGHTEN_SL_LIPS)
     {
      //  Pure SL-modify actions. ModifySL preserves the current TP (which is 0 post-partial).
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
      //  Three sub-cases by PartialLot result. See CLAUDE.md invariant #18.
      const double partial_lot = CPositionManager::PartialLot(
         current_pos_lot, Partial_Close_Fraction, vol_min, vol_step);

      if(partial_lot <= 0.0)
        {
         //--- Fraction=0.0: skip partial close, just ModifySL to BE+buffer (clear TP).
         Log.Info(StringFormat("MANAGE %s ticket=%I64u PARTIAL_AND_BE (Fraction=0, BE-only) -> SL %.5f (%s)",
                                pos_sym, g_state.open_trade_ticket, d.new_sl, d.reason), pos_sym);
         action_ok = CTradeManager::ModifySL(g_state.open_trade_ticket, d.new_sl, 0.0);
         if(action_ok)
           {
            g_state.partial_done = true;
            g_state.be_move_time = bar_time;
           }
        }
      else if(partial_lot >= current_pos_lot - 1e-9)
        {
         //--- Close-full path (Fraction=1.0 or close-full fallback when runner < vol_min).
         //--- Treat as a finished TP win: streak hook + apply profit + clear per-trade state.
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
            g_state.partial_done        = false;
            g_state.be_move_time        = 0;
            g_state.entry_R_distance    = 0.0;
            Log.Info(StringFormat("    partial-as-full-close: streak/cycle updated, daily_loss_pct=%.4f%%",
                                   g_state.daily_loss_pct));
           }
         else
            Log.Error(StringFormat("MANAGE CloseAtMarket failed ticket=%I64u", g_state.open_trade_ticket), pos_sym);
        }
      else
        {
         //--- Normal split. Atomic sequence: partial-close -> ModifySL -> flags -> save.
         //--- Scale POSITION_PROFIT (still on full lot at this point) to the partial portion.
         const double full_pos_profit  = PositionGetDouble(POSITION_PROFIT);
         const double partial_profit   = full_pos_profit * (partial_lot / current_pos_lot);
         Log.Info(StringFormat("MANAGE %s ticket=%I64u PARTIAL_AND_BE close=%.2f/%.2f at +%.1fR -> SL %.5f (P/L on partial=%.2f) [%s]",
                                pos_sym, g_state.open_trade_ticket,
                                partial_lot, current_pos_lot, Partial_Close_Trigger_R,
                                d.new_sl, partial_profit, d.reason), pos_sym);

         //--- Step 1: partial-close via CTrade::PositionClosePartial.
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
            //--- Step 2: ModifySL to BE+buffer, clear TP (runner has no TP).
            const bool modify_ok = CTradeManager::ModifySL(g_state.open_trade_ticket, d.new_sl, 0.0);
            //--- Step 3: book the partial as a TP win + apply realized profit.
            //--- Done unconditionally (the partial actually happened, the broker booked it).
            CStreakManager::OnTPClose(g_state);
            CDailyLossManager::ApplyRealizedProfit(g_state, partial_profit, g_day_start_equity);
            g_state.partial_done = true;          // bias: prevent double-partial on next bar
            g_state.be_move_time = bar_time;
            action_ok = true;
            if(modify_ok)
               Log.Info(StringFormat("    partial OK: streak +TP, daily_loss_pct=%.4f%%, runner=%.2f lots @ SL %.5f",
                                      g_state.daily_loss_pct,
                                      current_pos_lot - partial_lot, d.new_sl));
            else
               Log.Error(StringFormat("    HALF-STATE: partial fired (lot %.2f closed) but ModifySL FAILED for ticket=%I64u — runner has no BE protection. partial_done=true set to avoid double-partial; please manually inspect.",
                                       partial_lot, g_state.open_trade_ticket), pos_sym);
           }
        }
     }
   else if(d.action == MA_CLOSE_FRIDAY || d.action == MA_CLOSE_NYOPEN)
     {
      const string label = (d.action == MA_CLOSE_FRIDAY) ? "CLOSE_FRIDAY" : "CLOSE_NYOPEN";
      const double pre_close_profit = PositionGetDouble(POSITION_PROFIT);
      Log.Info(StringFormat("MANAGE %s ticket=%I64u %s slip=%dpts (%s)",
                             pos_sym, g_state.open_trade_ticket, label, slip, d.reason), pos_sym);
      action_ok = CTradeManager::CloseAtMarket(g_state.open_trade_ticket, slip);
      if(action_ok)
        {
         const EForcedCloseReason fcr =
            (d.action == MA_CLOSE_FRIDAY) ? FCR_FRIDAY_CLOSE : FCR_NY_CARRYOVER;
         //  Stage 2: if partial_done is already true, the streak was booked at
         //  the partial moment — don't double-count. Daily-loss still applies.
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
   //  Note: no MA_MOVE_BE / MA_CLOSE_LIPS handlers — Decide never returns those post-Task-C
   //  (Task 7 removes them from the enum).
```

Make sure `const double tp = PositionGetDouble(POSITION_TP);` and `const int slip = CPositionManager::SlippagePoints(...);` (the lines just above the dispatch around line 724-728) stay above this block — both branches use them.

- [ ] **Step 5.2: Verify EA compiles**

User compiles. Expected: 0/0. If a compile error references `MA_MOVE_BE` or `MA_CLOSE_LIPS`, those were left in the enum on purpose (Task 7 removes them) — no other code path should reference them after this edit. Grep `EA_AlligatorHA.mq5` for both:

```bash
grep -n 'MA_MOVE_BE\|MA_CLOSE_LIPS' EA_AlligatorHA.mq5
```

Expected: zero matches in the EA file.

- [ ] **Step 5.3: Commit**

```bash
git add EA_AlligatorHA.mq5
git commit -m "Path A Stage 2 Task D step 5: dispatch MA_TIGHTEN_SL_LIPS + MA_PARTIAL_AND_BE

Three-sub-case partial dispatch (Fraction=0 -> BE-only; Fraction=1
or runner-below-vol-min -> close-full; otherwise partial+ModifySL with
profit-scaled streak hook). Tighten = pure SL modify (no TP touch).
Friday/NY-open branch now checks g_state.partial_done to avoid
double-counting streak. Drops MA_MOVE_BE / MA_CLOSE_LIPS dispatch
branches; enum cleanup in step 7. See CLAUDE.md invariant #18."
```

---

### Task 6: `ResolveClosedPosition` — partial-vs-runner detection

**Files:**
- Modify: `EA_AlligatorHA.mq5` (`ResolveClosedPosition`, lines ~788-854)

- [ ] **Step 6.1: Insert the `partial_done` branch**

Find this block in `ResolveClosedPosition` (around line 821-849):

```mql5
      if(reason != DEAL_REASON_EXPERT)
        {
         CDailyLossManager::ApplyRealizedProfit(g_state, profit, g_day_start_equity);
         if(profit < 0)
            Log.Info(StringFormat("Resolve: daily_loss_pct -> %.4f%% (after %.2f loss)",
                                   g_state.daily_loss_pct, profit));
        }
      if(reason == DEAL_REASON_TP)
        {
         CStreakManager::OnTPClose(g_state);
         Log.Info("Resolve: TP -> cycle locked (mode now LOCKED)");
        }
      else if(reason == DEAL_REASON_SL)
        {
         CStreakManager::OnSLClose(g_state, Max_Streak_Length);
         ...
        }
      else if(reason == DEAL_REASON_EXPERT)
        {
         Log.Info("Resolve: EA-side forced close (already accounted)");
        }
```

Replace with:

```mql5
      //  Stage 2: if partial_done is already true, the streak was booked
      //  at the partial moment in EvaluateOpenPosition. The runner's final
      //  close therefore: applies realized profit for daily-loss tracking,
      //  but does NOT update the streak (would double-count).
      if(g_state.partial_done && reason != DEAL_REASON_EXPERT)
        {
         CDailyLossManager::ApplyRealizedProfit(g_state, profit, g_day_start_equity);
         Log.Info(StringFormat("Resolve: ticket=%I64u runner closed by %s P/L=%.2f — streak unchanged (booked at partial)",
                                ticket, reason_str, profit));
        }
      else if(reason != DEAL_REASON_EXPERT)
        {
         CDailyLossManager::ApplyRealizedProfit(g_state, profit, g_day_start_equity);
         if(profit < 0)
            Log.Info(StringFormat("Resolve: daily_loss_pct -> %.4f%% (after %.2f loss)",
                                   g_state.daily_loss_pct, profit));
         if(reason == DEAL_REASON_TP)
           {
            CStreakManager::OnTPClose(g_state);
            Log.Info("Resolve: TP -> cycle locked (mode now LOCKED)");
           }
         else if(reason == DEAL_REASON_SL)
           {
            CStreakManager::OnSLClose(g_state, Max_Streak_Length);
            const ETradingMode m = CStreakManager::DeriveMode(g_state, Max_Streak_Length);
            Log.Info(StringFormat("Resolve: SL -> streak_position=%d last_sl=%d mode=%s",
                                   g_state.streak_position, g_state.last_sl_count,
                                   m == MODE_LOCKED ? "LOCKED" :
                                   (m == MODE_RECOVERY ? "RECOVERY" : "DEFAULT")));
           }
        }
      else
        {
         //  DEAL_REASON_EXPERT — Friday flatten / NY carryover / partial close-full.
         //  Dispatch in EvaluateOpenPosition already updated streak + daily-loss inline.
         Log.Info("Resolve: EA-side close (already accounted)");
        }
```

- [ ] **Step 6.2: Verify EA compiles**

User compiles. Expected: 0/0.

- [ ] **Step 6.3: Commit**

```bash
git add EA_AlligatorHA.mq5
git commit -m "Path A Stage 2 Task D step 6: ResolveClosedPosition partial-vs-runner branch

When g_state.partial_done is true and the broker closes the runner
(initial SL hit, trail SL hit, leftover TP — anything non-EXPERT),
apply realized profit but skip the streak hook (already booked at
partial moment in EvaluateOpenPosition). Avoids double-counting one
trade as two streak events."
```

---

### Task 7: Enum cleanup — drop `MA_MOVE_BE`, `MA_CLOSE_LIPS`, `FCR_LIPS_BREAK`

**Files:**
- Modify: `Include/TradeManager.mqh` (enum lines 26-37)
- Modify: `Include/StreakManager.mqh` (enum lines 20-25 + `OnForcedClose` line 102)
- Modify: `Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_TradeManager.mq5` (remove `Test_Decide_NeverReturnsDeprecatedEnums` + its registration)
- Modify: `Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_StreakManager.mq5` (replace the `FCR_LIPS_BREAK` reference on line 76)
- Update: `Include/TradeManager.mqh` and `Include/StreakManager.mqh` file-header comments (drop the "DEPRECATED: removed in Task D" lines)

- [ ] **Step 7.1: Sanity-check no live code still references the deprecated symbols**

Run from the project root:

```bash
grep -rn 'MA_MOVE_BE\|MA_CLOSE_LIPS\|FCR_LIPS_BREAK' --include='*.mq5' --include='*.mqh' Experts/ Scripts/
```

Expected matches (the ones we're about to clean up):
- `Include/TradeManager.mqh` — 2 enum lines + the file-header comment + the priority-list comment
- `Include/StreakManager.mqh` — 1 enum line + the `OnForcedClose` branch + comments
- `Scripts/.../Test_TradeManager.mq5` — `Test_Decide_NeverReturnsDeprecatedEnums` function (~448-475) + `OnStart()` registration (~598)
- `Scripts/.../Test_StreakManager.mq5` — line 76 `CStreakManager::OnForcedClose(s, FCR_LIPS_BREAK, 3);`

If there's a match anywhere else, stop and triage — Task D's earlier steps may have missed something. EA file `EA_AlligatorHA.mq5` must show zero matches.

- [ ] **Step 7.2: Remove deprecated values from `EManageAction`**

In [Include/TradeManager.mqh](Include/TradeManager.mqh) lines 26-37, replace:

```mql5
enum EManageAction
  {
   MA_NONE              = 0,
   MA_MOVE_BE           = 1,   // DEPRECATED: removed in Task D; Decide no longer returns this
   MA_TRAIL             = 2,
   MA_CLOSE_LIPS        = 3,   // DEPRECATED: removed in Task D; Decide no longer returns this
   MA_CLOSE_FRIDAY      = 4,
   MA_CLOSE_NYOPEN      = 5,
   MA_PARTIAL_AND_BE    = 6,
   MA_TIGHTEN_SL_LIPS   = 7,
  };
```

With:

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

(Integer slots `1` and `3` are intentionally left as gaps — `EManageAction` is not serialized anywhere, but keeping the gaps documents the historical numbering for any future archaeologist.)

- [ ] **Step 7.3: Drop the "DEPRECATED" line from the `TradeManager.mqh` file header**

Lines 6-10 of `Include/TradeManager.mqh`:

```mql5
//|  Path A Stage 2 (Task C) — Decide rewrite:                       |
//|    + MA_PARTIAL_AND_BE  (replaces MA_MOVE_BE; close partial @+1R)|
//|    + MA_TIGHTEN_SL_LIPS (replaces MA_CLOSE_LIPS; pre-BE only)    |
//|    + trail-delay gate (MA_TRAIL waits N bars after BE move)      |
//|    + TightenLipsPrice pure helper                                |
```

Already correct — keep as is (the historical-context phrasing is fine).

- [ ] **Step 7.4: Remove `FCR_LIPS_BREAK` from `EForcedCloseReason`**

In [Include/StreakManager.mqh](Include/StreakManager.mqh) lines 20-25, replace:

```mql5
enum EForcedCloseReason
  {
   FCR_LIPS_BREAK   = 0,
   FCR_FRIDAY_CLOSE = 1,
   FCR_NY_CARRYOVER = 2,
  };
```

With:

```mql5
enum EForcedCloseReason
  {
   FCR_FRIDAY_CLOSE = 1,
   FCR_NY_CARRYOVER = 2,
  };
```

Then in `OnForcedClose` (around line 99-105), replace the body:

```mql5
void CStreakManager::OnForcedClose(EAState &state, const EForcedCloseReason r,
                                   const int max_streak)
  {
   if(r == FCR_LIPS_BREAK) OnSLClose(state, max_streak);
   //  FCR_FRIDAY_CLOSE / FCR_NY_CARRYOVER: no-op for streak.
   //  NOTE: when adding new EForcedCloseReason values, add an explicit else-if here.
  }
```

With:

```mql5
void CStreakManager::OnForcedClose(EAState &state, const EForcedCloseReason r,
                                   const int max_streak)
  {
   //  Stage 2: FCR_FRIDAY_CLOSE / FCR_NY_CARRYOVER are no-op for streak.
   //  (Friday-15:00 NY rollover wipes streak next NY-open; NY carryover close
   //  came from a previous cycle and shouldn't count.) FCR_LIPS_BREAK is gone
   //  — pre-BE Lips break is now MA_TIGHTEN_SL_LIPS (SL tighten, no close).
   //  Function kept to give Friday/NY-open dispatch a single hook to call.
  }
```

(Suppress the unused-parameter warnings using the `(void)state; (void)r; (void)max_streak;` idiom if the compiler complains. MT5's MQL5 compiler is usually lenient on unused params; only add if a warning appears.)

- [ ] **Step 7.5: Drop the deprecated test**

In [Test_TradeManager.mq5](../../../Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_TradeManager.mq5):

- Delete the entire `Test_Decide_NeverReturnsDeprecatedEnums()` function (lines ~448-475).
- Delete its registration in `OnStart()` (line 598: `Test_Decide_NeverReturnsDeprecatedEnums();`).

The asserts inside it would be trivially-true after the enum cleanup (the compiler would even reject `d.action != MA_MOVE_BE` since the symbol is gone). Keeping it is dead test code.

- [ ] **Step 7.6: Fix the `FCR_LIPS_BREAK` reference in `Test_StreakManager`**

In [Test_StreakManager.mq5](../../../Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_StreakManager.mq5) line 76 (and read 5 lines of context around it to understand the test's intent):

```bash
grep -n -B2 -A3 'FCR_LIPS_BREAK' Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_StreakManager.mq5
```

The test was checking that a Lips-break forced close advances the streak. That semantic is gone (Lips break no longer closes — it tightens SL). Two options:

1. **Delete the assertion** (simplest — the behaviour it tested no longer exists).
2. **Repurpose the test** to assert that `FCR_FRIDAY_CLOSE` is a no-op for streak (matches the new comment in `OnForcedClose`).

Pick option 2 — keeps the streak-coverage count from dropping. Replace the line:

```mql5
   CStreakManager::OnForcedClose(s, FCR_LIPS_BREAK, 3);
```

With (along with adjusting the asserts before/after — read the function body and update them to match Friday-close-is-no-op semantics):

```mql5
   //  Stage 2: FCR_LIPS_BREAK is gone (Lips break is now MA_TIGHTEN_SL_LIPS, not a close).
   //  Verify FCR_FRIDAY_CLOSE is a streak no-op instead.
   const int sp_before  = s.streak_position;
   const int slc_before = s.last_sl_count;
   CStreakManager::OnForcedClose(s, FCR_FRIDAY_CLOSE, 3);
   AssertEqInt(s.streak_position, sp_before,  "Friday close: streak_position unchanged");
   AssertEqInt(s.last_sl_count,   slc_before, "Friday close: last_sl_count unchanged");
```

The exact replacement depends on the surrounding asserts in that test function — read lines 70-90 of `Test_StreakManager.mq5` before editing and keep the function's overall structure.

- [ ] **Step 7.7: Compile + run all test scripts**

User compiles each `.mq5` script (EA + 14 test scripts) and runs each test as a chart Script. Expected:

| Test file | Expected count |
|---|---|
| `Test_StateManager` | 42/42 (was 39) |
| `Test_TradeManager` | 67/67 or 68/68 — see notes below (was 68) |
| `Test_StreakManager` | 28/28 (was 28; one assert replaced, not removed) |
| All 11 others | unchanged |

**On Test_TradeManager count:** `Test_Decide_NeverReturnsDeprecatedEnums` contributed multiple asserts (6 in the body per the grep — 2 per scenario × 3 scenarios). Removing it drops 6 asserts. So the post-Task-D count is **68 − 6 = 62**. The handoff doc said "−1"; actual is closer to "−6". Note the real number in the commit message.

EA compiles 0/0.

- [ ] **Step 7.8: Commit**

```bash
git add Include/TradeManager.mqh Include/StreakManager.mqh \
        Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_TradeManager.mq5 \
        Scripts/Alligator_Heiken_Ashi_EA_Tests/Test_StreakManager.mq5
git commit -m "Path A Stage 2 Task D step 7: drop deprecated enum values + tests

Removes MA_MOVE_BE / MA_CLOSE_LIPS from EManageAction (Decide hasn't
returned these since Task C; EA dispatch lost them in step 5). Removes
FCR_LIPS_BREAK from EForcedCloseReason + its OnForcedClose branch
(Lips break is now MA_TIGHTEN_SL_LIPS, not a close). Test_TradeManager
loses Test_Decide_NeverReturnsDeprecatedEnums (trivially-true post-cleanup).
Test_StreakManager swaps the FCR_LIPS_BREAK reference for an FCR_FRIDAY_CLOSE
no-op assertion."
```

---

### Task 8: Acceptance — live smoke test on IC Markets demo

This task is **user-executed**. Claude can't drive MT5. Document the smoke session here so the next-session Claude can pick it up if it carries over.

- [ ] **Step 8.1: Compile + run all 14 test scripts**

All green. Specifically verify:
- Test_StateManager 42/42 (or 43/43 if a 4th legacy assert ended up necessary)
- Test_PositionManager 49/49 (unchanged from Task B)
- Test_TradeManager 62/62 (was 68, minus the 6 deprecated-enum asserts)
- Test_StreakManager 28/28
- The other 10 test scripts unchanged.

- [ ] **Step 8.2: Attach EA to a live IC Markets demo chart**

Verify on the inputs panel:
- `Partial_Close_Fraction = 0.5`
- `Partial_Close_Trigger_R = 1.0`
- `Trail_Delay_Bars = 2`
- `Trail_ATR_Buffer = 0.5` (panel may show old `0.3` due to MT5 input-panel stickiness — reset to default explicitly OR delete the `.set` file before this step)
- `LipsBreak_Confirm_Bars = 2` (same stickiness caveat)

Verify EA boot log shows Stage-2 phase banner (update the banner string in `OnInit` to "Stage 2 Task D" if it still says "Phase 8").

- [ ] **Step 8.3: Verify state file format**

After EA's first save (init or first new-M15-bar event), open `MQL5/Files/EA_State_<magic>.json` and verify it contains:

```json
"initial_balance": <number>,
"partial_done": false,
"be_move_time": "1970-01-01T00:00:00Z",
"entry_R_distance": 0.00000,
"last_save_time": "..."
```

- [ ] **Step 8.4: Force a partial fire with temporary overrides**

Temporarily set on the inputs panel:
- `Partial_Close_Trigger_R = 0.3` (partial fires at +0.3R — minutes-scale on most pairs)
- `Risk_Position1 = 0.05` (small enough to safely test without blowing demo equity)

Reattach EA. Wait for a real entry signal to fire and the trade to reach +0.3R. Expected log line:

```
MANAGE EURUSD ticket=<X> PARTIAL_AND_BE close=0.01/0.02 at +0.3R -> SL <Y> (P/L on partial=<Z>) [partial+BE: ...]
```

Followed by `partial OK: streak +TP, daily_loss_pct=...`. Verify state file updates:
- `partial_done: true`
- `be_move_time` = the M15 bar time at which partial fired
- `entry_R_distance` retains its non-zero value (NOT zeroed)

- [ ] **Step 8.5: Verify trail-delay gate**

Wait `Trail_Delay_Bars` × 15 minutes = 30 min after the partial. Expected: `MA_TRAIL` starts firing once `bars_since_BE_move >= 2`. Log line:

```
MANAGE EURUSD ticket=<X> TRAIL -> SL <new> (trail BUY/SELL lips=<L> atr=<A> buf=0.50 -> <new>)
```

Pre-2-bars: no `MANAGE` log line (Decide returns `MA_NONE`, EA logs at Debug level).

- [ ] **Step 8.6: Verify runner-close streak unchanged**

Manually click "Close Position" on the runner in MT5 (or wait for the runner to hit its trail SL). Expected log line:

```
Resolve: ticket=<X> runner closed by <SL/CLIENT/...> P/L=<Z2> — streak unchanged (booked at partial)
```

Verify state file: `partial_done` back to `false`, `be_move_time = 0`, `entry_R_distance = 0`, `open_trade_ticket = 0`.

- [ ] **Step 8.7: Revert the temporary overrides**

Set `Partial_Close_Trigger_R` back to `1.0` and `Risk_Position1` back to `0.30` on the inputs panel. Reattach EA. Confirm via boot log.

- [ ] **Step 8.8: Update CLAUDE.md**

Once the smoke test passes, edit [CLAUDE.md](../CLAUDE.md):
- Add a bullet under "Project status" describing Task D shipped (commits + smoke result).
- Update the "Heads-up for the next session" pending list — remove Task D, leave Task E (re-baseline backtest) as the next item.
- Update the file layout table to reflect post-Task-D test counts and the enum cleanup.

- [ ] **Step 8.9: Commit + push**

```bash
git add CLAUDE.md
git commit -m "Path A Stage 2 Task D: smoke test passed + status update

Smoke test on IC Markets demo confirmed PARTIAL_AND_BE fires, trail-delay
gates MA_TRAIL for 2 bars, runner close logs 'streak unchanged (booked
at partial)'. State JSON contains entry_R_distance / partial_done /
be_move_time. Reverted Partial_Close_Trigger_R / Risk_Position1 overrides.

Stage 2 Task D complete. Task E (re-baseline backtest) is next."

git push
```

---

## Out of scope for Task D (deferred)

- **Task E — re-baseline backtest** is a separate, user-run task. Document at the "Result (TBD)" section of [docs/2026-05-13-path-a-stage2.md](2026-05-13-path-a-stage2.md) after the user runs the two passes (Fraction=0.5 and Fraction=1.0) + walk-forward.
- **Trail buffer split** (separate input for `MA_TIGHTEN_SL_LIPS` vs `MA_TRAIL`) — defer to post-E review per handoff doc Open Question 3.
- **Re-litigate spec §9 params** — already advisory under Path A.

## Self-review (against the handoff doc)

Verified all 7 numbered requirements from the handoff "What Task D does (high-level)" section map to tasks:

1. State schema extension (entry_R_distance) → Task 1 ✓
2. Three new EA inputs + ValidateInputs → Task 2 ✓
3. Two existing default flips → Task 2 ✓
4. Snapshot entry_R_distance on entry + best-effort adopt → Task 3 ✓
5. EvaluateOpenPosition dispatch rewrite → Tasks 4 + 5 ✓
6. Remove deprecated enums → Task 7 ✓
7. ResolveClosedPosition partial-vs-runner → Task 6 ✓

Plus the live smoke test → Task 8 ✓.

Atomicity recipe (invariant #18) is encoded in Task 5 — the three sub-cases by `PartialLot` result + the half-state log. Decide-priority (invariant #17) is unchanged from Task C — only the dispatch is new, and that respects what Decide returns.
