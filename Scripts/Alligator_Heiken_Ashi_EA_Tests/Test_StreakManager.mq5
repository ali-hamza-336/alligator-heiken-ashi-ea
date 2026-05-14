//+------------------------------------------------------------------+
//|  Test_StreakManager.mq5                                          |
//|  Phase 6 unit tests for cycle/streak state machine.              |
//+------------------------------------------------------------------+
#property copyright "Phase 6 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\StreakManager.mqh"

int g_passed = 0;
int g_failed = 0;
void Assert(const bool cond, const string label)
{ if(cond) { g_passed++; PrintFormat("  PASS: %s", label); }
  else     { g_failed++; PrintFormat("  FAIL: %s", label); } }
void AssertEqInt(const int got, const int exp, const string label)
{ if(got == exp) { g_passed++; PrintFormat("  PASS: %s", label); }
  else { g_failed++; PrintFormat("  FAIL: %s exp=%d got=%d", label, exp, got); } }

EAState MakeFresh()
{
   EAState s;
   s.streak_position     = 1;
   s.current_cycle_id    = "20260511_NY";
   s.tp_hit_in_cycle     = false;
   s.daily_loss_pct      = 0.0;
   s.daily_loss_date     = "2026-05-11";
   s.last_sl_count       = 0;
   s.trades_taken_today  = 0;
   s.open_trade_ticket   = 0;
   s.open_trade_cycle_id = "";
   s.initial_balance     = 0.0;
   s.last_save_time      = 0;
   return s;
}

void Test_Mode_FreshIsDefault()
{
   Print("[Test_Mode_FreshIsDefault]");
   EAState s = MakeFresh();
   Assert(CStreakManager::DeriveMode(s, 3) == MODE_DEFAULT, "fresh = DEFAULT");
}
void Test_Mode_AfterOneSLIsRecovery()
{
   Print("[Test_Mode_AfterOneSLIsRecovery]");
   EAState s = MakeFresh();
   CStreakManager::OnSLClose(s, 3);
   Assert(CStreakManager::DeriveMode(s, 3) == MODE_RECOVERY, "1 SL = RECOVERY");
   AssertEqInt(s.streak_position, 2, "streak_position = 2");
   AssertEqInt(s.last_sl_count, 1, "last_sl_count = 1");
}
void Test_Mode_AfterTPIsLocked()
{
   Print("[Test_Mode_AfterTPIsLocked]");
   EAState s = MakeFresh();
   CStreakManager::OnTPClose(s);
   Assert(CStreakManager::DeriveMode(s, 3) == MODE_LOCKED, "TP = LOCKED");
   Assert(s.tp_hit_in_cycle, "tp_hit_in_cycle set");
}
void Test_Mode_After3SLsIsLocked()
{
   Print("[Test_Mode_After3SLsIsLocked]");
   EAState s = MakeFresh();
   CStreakManager::OnSLClose(s, 3);
   CStreakManager::OnSLClose(s, 3);
   CStreakManager::OnSLClose(s, 3);
   Assert(CStreakManager::DeriveMode(s, 3) == MODE_LOCKED, "3 SLs = LOCKED");
   AssertEqInt(s.last_sl_count, 3, "last_sl_count = 3");
   AssertEqInt(s.streak_position, 3, "streak_position clamped at 3");
}
void Test_Forced_LipsBreakAdvancesStreak()
{
   Print("[Test_Forced_LipsBreakAdvancesStreak]");
   EAState s = MakeFresh();
   //  Stage 2: FCR_LIPS_BREAK is gone (Lips break is now MA_TIGHTEN_SL_LIPS, not a close).
   //  Verify FCR_FRIDAY_CLOSE is a streak no-op instead.
   const int sp_before  = s.streak_position;
   const int slc_before = s.last_sl_count;
   CStreakManager::OnForcedClose(s, FCR_FRIDAY_CLOSE, 3);
   AssertEqInt(s.streak_position, sp_before,  "Friday close: streak_position unchanged");
   AssertEqInt(s.last_sl_count,   slc_before, "Friday close: last_sl_count unchanged");
}
void Test_Forced_FridayCloseDoesNotAdvance()
{
   Print("[Test_Forced_FridayCloseDoesNotAdvance]");
   EAState s = MakeFresh();
   CStreakManager::OnForcedClose(s, FCR_FRIDAY_CLOSE, 3);
   AssertEqInt(s.last_sl_count, 0, "Friday close: streak untouched");
   AssertEqInt(s.streak_position, 1, "streak_position untouched");
}
void Test_Forced_NYCarryoverDoesNotAdvance()
{
   Print("[Test_Forced_NYCarryoverDoesNotAdvance]");
   EAState s = MakeFresh();
   CStreakManager::OnSLClose(s, 3);
   const int sl_before = s.last_sl_count;
   const int sp_before = s.streak_position;
   CStreakManager::OnForcedClose(s, FCR_NY_CARRYOVER, 3);
   AssertEqInt(s.last_sl_count,   sl_before, "carryover: SL count untouched");
   AssertEqInt(s.streak_position, sp_before, "carryover: streak_position untouched");
}
void Test_Reset_ZerosCounters()
{
   Print("[Test_Reset_ZerosCounters]");
   EAState s = MakeFresh();
   CStreakManager::OnSLClose(s, 3);
   CStreakManager::OnSLClose(s, 3);
   CStreakManager::OnTPClose(s);
   CStreakManager::ResetForNewCycle(s, "20260512_NY");
   AssertEqInt(s.streak_position, 1, "streak_position back to 1");
   AssertEqInt(s.last_sl_count,   0, "last_sl_count back to 0");
   Assert(!s.tp_hit_in_cycle,         "tp_hit_in_cycle cleared");
   Assert(s.current_cycle_id == "20260512_NY", "current_cycle_id updated");
   Assert(CStreakManager::DeriveMode(s, 3) == MODE_DEFAULT, "post-reset = DEFAULT");
}
void Test_WalkThrough_CleanWin()
{
   Print("[Test_WalkThrough_CleanWin]");
   EAState s = MakeFresh();
   Assert(CStreakManager::DeriveMode(s, 3) == MODE_DEFAULT, "Mon NY: default");
   CStreakManager::OnTPClose(s);
   Assert(CStreakManager::DeriveMode(s, 3) == MODE_LOCKED, "post-TP: locked");
   CStreakManager::ResetForNewCycle(s, "20260512_NY");
   Assert(CStreakManager::DeriveMode(s, 3) == MODE_DEFAULT, "Tue NY rollover: default");
}
void Test_WalkThrough_LossStreakRecovery()
{
   Print("[Test_WalkThrough_LossStreakRecovery]");
   EAState s = MakeFresh();
   CStreakManager::OnSLClose(s, 3);
   AssertEqInt(s.streak_position, 2, "after Pos1 SL, next = Pos2");
   CStreakManager::OnSLClose(s, 3);
   AssertEqInt(s.streak_position, 3, "after Pos2 SL, next = Pos3");
   Assert(CStreakManager::DeriveMode(s, 3) == MODE_RECOVERY, "still recovery");
   CStreakManager::OnTPClose(s);
   Assert(CStreakManager::DeriveMode(s, 3) == MODE_LOCKED, "TP after recovery: locked");
}
void Test_WalkThrough_FullBust()
{
   Print("[Test_WalkThrough_FullBust]");
   EAState s = MakeFresh();
   for(int i = 0; i < 3; i++) CStreakManager::OnSLClose(s, 3);
   Assert(CStreakManager::DeriveMode(s, 3) == MODE_LOCKED, "3 SLs = locked");
}

void OnStart()
{
   g_passed = 0; g_failed = 0;
   Test_Mode_FreshIsDefault();
   Test_Mode_AfterOneSLIsRecovery();
   Test_Mode_AfterTPIsLocked();
   Test_Mode_After3SLsIsLocked();
   Test_Forced_LipsBreakAdvancesStreak();
   Test_Forced_FridayCloseDoesNotAdvance();
   Test_Forced_NYCarryoverDoesNotAdvance();
   Test_Reset_ZerosCounters();
   Test_WalkThrough_CleanWin();
   Test_WalkThrough_LossStreakRecovery();
   Test_WalkThrough_FullBust();
   PrintFormat("===== Done. passed=%d failed=%d =====", g_passed, g_failed);
}
