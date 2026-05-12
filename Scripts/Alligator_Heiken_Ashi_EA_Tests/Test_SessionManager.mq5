//+------------------------------------------------------------------+
//|  Test_SessionManager.mq5                                         |
//|  Phase 6 unit tests for session windows + IsTradingAllowed.       |
//+------------------------------------------------------------------+
#property copyright "Phase 6 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\SessionManager.mqh"

int g_passed = 0;
int g_failed = 0;
void Assert(const bool cond, const string label)
{ if(cond) { g_passed++; PrintFormat("  PASS: %s", label); }
  else     { g_failed++; PrintFormat("  FAIL: %s", label); } }

void Test_NYWindow_InsideMon()
{
   Print("[Test_NYWindow_InsideMon]");
   Assert(CSessionManager::IsInNYWindow(1, 10, 8, 15), "Mon 10:00 NY = inside");
   Assert(CSessionManager::IsInNYWindow(1,  8, 8, 15), "Mon 08:00 NY = inside (open inclusive)");
   Assert(!CSessionManager::IsInNYWindow(1, 15, 8, 15), "Mon 15:00 NY = outside (close exclusive)");
   Assert(!CSessionManager::IsInNYWindow(1,  7, 8, 15), "Mon 07:00 NY = outside");
}
void Test_NYWindow_Weekend()
{
   Print("[Test_NYWindow_Weekend]");
   Assert(!CSessionManager::IsInNYWindow(0, 10, 8, 15), "Sun 10:00 NY = no");
   Assert(!CSessionManager::IsInNYWindow(6, 10, 8, 15), "Sat 10:00 NY = no");
}
void Test_TokyoWindow_LateMonNY()
{
   Print("[Test_TokyoWindow_LateMonNY]");
   Assert(CSessionManager::IsInTokyoWindow(1, 20), "Mon 20:00 NY = Tokyo session active");
   Assert(CSessionManager::IsInTokyoWindow(2, 2),  "Tue 02:00 NY = Tokyo (Mon evening)");
   Assert(!CSessionManager::IsInTokyoWindow(2, 5), "Tue 05:00 NY = past Tokyo close");
}
void Test_TokyoWindow_SunEvening()
{
   Print("[Test_TokyoWindow_SunEvening]");
   Assert(CSessionManager::IsInTokyoWindow(0, 20), "Sun 20:00 NY = Mon Tokyo open");
   Assert(!CSessionManager::IsInTokyoWindow(6, 20), "Sat 20:00 NY = no (no Sun trading)");
}
void Test_LondonWindow()
{
   Print("[Test_LondonWindow]");
   Assert(CSessionManager::IsInLondonWindow(1, 5),  "Mon 05:00 NY = London active");
   Assert(!CSessionManager::IsInLondonWindow(1, 12),"Mon 12:00 NY = London closed");
   Assert(!CSessionManager::IsInLondonWindow(0, 5), "Sun 05:00 NY = no (weekend)");
}
void Test_AnySession_RecoveryCoverage()
{
   Print("[Test_AnySession_RecoveryCoverage]");
   Assert( CSessionManager::IsAnySessionWindow(1,  9, 8, 15), "Mon 09 = NY");
   Assert( CSessionManager::IsAnySessionWindow(1,  4, 8, 15), "Mon 04 = London");
   Assert( CSessionManager::IsAnySessionWindow(1, 22, 8, 15), "Mon 22 = Tokyo (next day)");
   Assert(!CSessionManager::IsAnySessionWindow(1, 16, 8, 15), "Mon 16 = post-NY gap");
   Assert(!CSessionManager::IsAnySessionWindow(2, 17, 8, 15), "Tue 17 = post-NY gap");
}
void Test_FridayCloseTime()
{
   Print("[Test_FridayCloseTime]");
   Assert(CSessionManager::IsFridayCloseTime(5, 15, 15), "Fri 15:00 NY = close");
   Assert(CSessionManager::IsFridayCloseTime(5, 22, 15), "Fri 22:00 NY = past close");
   Assert(!CSessionManager::IsFridayCloseTime(5, 14, 15),"Fri 14:00 NY = not yet");
   Assert(!CSessionManager::IsFridayCloseTime(4, 15, 15),"Thu 15:00 NY = not Friday");
}
void Test_Allowed_DefaultInsideNY()
{
   Print("[Test_Allowed_DefaultInsideNY]");
   const TradeAllowResult r = CSessionManager::IsTradingAllowed(
      MODE_DEFAULT, 2, 10, 8, 15, 15);
   Assert(r.allowed, "Tue 10:00 default = allowed");
}
void Test_Allowed_DefaultOutsideNY()
{
   Print("[Test_Allowed_DefaultOutsideNY]");
   const TradeAllowResult r = CSessionManager::IsTradingAllowed(
      MODE_DEFAULT, 2, 22, 8, 15, 15);
   Assert(!r.allowed, "Tue 22:00 default = blocked");
}
void Test_Allowed_RecoveryInTokyo()
{
   Print("[Test_Allowed_RecoveryInTokyo]");
   const TradeAllowResult r = CSessionManager::IsTradingAllowed(
      MODE_RECOVERY, 2, 22, 8, 15, 15);
   Assert(r.allowed, "Tue 22:00 recovery = allowed (Tokyo)");
}
void Test_Allowed_LockedAlwaysBlocks()
{
   Print("[Test_Allowed_LockedAlwaysBlocks]");
   const TradeAllowResult r = CSessionManager::IsTradingAllowed(
      MODE_LOCKED, 2, 10, 8, 15, 15);
   Assert(!r.allowed, "Tue 10:00 locked = blocked");
}
void Test_Allowed_FridayCloseBeatsRecovery()
{
   Print("[Test_Allowed_FridayCloseBeatsRecovery]");
   const TradeAllowResult r = CSessionManager::IsTradingAllowed(
      MODE_RECOVERY, 5, 15, 8, 15, 15);
   Assert(!r.allowed, "Fri 15:00 recovery = blocked (Friday close)");
}
void Test_Allowed_WeekendBlocked()
{
   Print("[Test_Allowed_WeekendBlocked]");
   const TradeAllowResult r1 = CSessionManager::IsTradingAllowed(
      MODE_DEFAULT, 6, 10, 8, 15, 15);
   const TradeAllowResult r2 = CSessionManager::IsTradingAllowed(
      MODE_RECOVERY, 0, 10, 8, 15, 15);
   Assert(!r1.allowed, "Sat default = blocked");
   Assert(!r2.allowed, "Sun recovery = blocked");
}

void OnStart()
{
   g_passed = 0; g_failed = 0;
   Test_NYWindow_InsideMon();
   Test_NYWindow_Weekend();
   Test_TokyoWindow_LateMonNY();
   Test_TokyoWindow_SunEvening();
   Test_LondonWindow();
   Test_AnySession_RecoveryCoverage();
   Test_FridayCloseTime();
   Test_Allowed_DefaultInsideNY();
   Test_Allowed_DefaultOutsideNY();
   Test_Allowed_RecoveryInTokyo();
   Test_Allowed_LockedAlwaysBlocks();
   Test_Allowed_FridayCloseBeatsRecovery();
   Test_Allowed_WeekendBlocked();
   PrintFormat("===== Done. passed=%d failed=%d =====", g_passed, g_failed);
}
