//+------------------------------------------------------------------+
//|  Test_DailyLossManager.mq5                                       |
//|  Phase 6 unit tests for daily-loss tracking.                     |
//+------------------------------------------------------------------+
#property copyright "Phase 6 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\DailyLossManager.mqh"

int g_passed = 0;
int g_failed = 0;
void Assert(const bool cond, const string label)
{ if(cond) { g_passed++; PrintFormat("  PASS: %s", label); }
  else     { g_failed++; PrintFormat("  FAIL: %s", label); } }
void AssertEqStr(const string got, const string exp, const string label)
{ if(got == exp) { g_passed++; PrintFormat("  PASS: %s", label); }
  else { g_failed++; PrintFormat("  FAIL: %s exp='%s' got='%s'", label, exp, got); } }
void AssertEqDbl(const double got, const double exp, const double tol, const string label)
{ if(MathAbs(got - exp) <= tol) { g_passed++; PrintFormat("  PASS: %s", label); }
  else { g_failed++; PrintFormat("  FAIL: %s exp=%.6f got=%.6f tol=%.6f", label, exp, got, tol); } }

datetime MakeDt(int y, int m, int d, int h, int mi)
{ MqlDateTime t; ZeroMemory(t); t.year=y; t.mon=m; t.day=d; t.hour=h; t.min=mi; return StructToTime(t); }

EAState MakeFresh()
{
   EAState s;
   s.streak_position=1; s.current_cycle_id="20260511_NY"; s.tp_hit_in_cycle=false;
   s.daily_loss_pct=0; s.daily_loss_date=""; s.last_sl_count=0; s.trades_taken_today=0;
   s.open_trade_ticket=0; s.open_trade_cycle_id=""; s.initial_balance=0; s.last_save_time=0;
   return s;
}

void Test_DateString_Format()
{
   Print("[Test_DateString_Format]");
   AssertEqStr(CDailyLossManager::CETDateString(MakeDt(2026,5,11,14,30)),
               "2026-05-11", "YYYY-MM-DD");
}
void Test_IsNewCETDate_FirstRun()
{
   Print("[Test_IsNewCETDate_FirstRun]");
   Assert(CDailyLossManager::IsNewCETDate("", "2026-05-11"), "empty state = new day");
}
void Test_IsNewCETDate_SameDay()
{
   Print("[Test_IsNewCETDate_SameDay]");
   Assert(!CDailyLossManager::IsNewCETDate("2026-05-11", "2026-05-11"), "same day = no");
}
void Test_IsNewCETDate_Rollover()
{
   Print("[Test_IsNewCETDate_Rollover]");
   Assert(CDailyLossManager::IsNewCETDate("2026-05-11", "2026-05-12"), "rollover = yes");
}
void Test_ResetForNewDay_ZerosCounters()
{
   Print("[Test_ResetForNewDay_ZerosCounters]");
   EAState s = MakeFresh();
   s.daily_loss_pct = 1.20; s.daily_loss_date = "2026-05-10"; s.trades_taken_today = 3;
   CDailyLossManager::ResetForNewDay(s, "2026-05-11");
   AssertEqDbl(s.daily_loss_pct, 0.0, 1e-9, "loss pct zeroed");
   AssertEqStr(s.daily_loss_date, "2026-05-11", "date advanced");
   Assert(s.trades_taken_today == 0, "trades_taken_today zeroed");
}
void Test_WouldBreach_BelowLimit()
{
   Print("[Test_WouldBreach_BelowLimit]");
   //  current 0.5% + risk 0.7% = 1.2% < 1.5% limit → no breach
   Assert(!CDailyLossManager::WouldBreachLimit(0.5, 0.7, 1.5), "1.2 < 1.5");
}
void Test_WouldBreach_AtLimit()
{
   Print("[Test_WouldBreach_AtLimit]");
   //  current 1.0% + risk 0.5% = 1.5% — equal to limit, NOT a breach (>)
   Assert(!CDailyLossManager::WouldBreachLimit(1.0, 0.5, 1.5), "1.5 == 1.5 = no breach");
}
void Test_WouldBreach_OverLimit()
{
   Print("[Test_WouldBreach_OverLimit]");
   //  current 1.0% + risk 0.7% = 1.7% → breach
   Assert(CDailyLossManager::WouldBreachLimit(1.0, 0.7, 1.5), "1.7 > 1.5");
}
void Test_ApplyProfit_LossOnly()
{
   Print("[Test_ApplyProfit_LossOnly]");
   //  $-300 loss on $100k start = 0.30%
   EAState s = MakeFresh();
   CDailyLossManager::ApplyRealizedProfit(s, -300.0, 100000.0);
   AssertEqDbl(s.daily_loss_pct, 0.30, 1e-6, "1 SL = +0.30 loss pct");
}
void Test_ApplyProfit_Accumulates()
{
   Print("[Test_ApplyProfit_Accumulates]");
   EAState s = MakeFresh();
   CDailyLossManager::ApplyRealizedProfit(s, -300.0, 100000.0);
   CDailyLossManager::ApplyRealizedProfit(s, -500.0, 100000.0);
   AssertEqDbl(s.daily_loss_pct, 0.80, 1e-6, "0.30+0.50 = 0.80");
}
void Test_ApplyProfit_WinIgnored()
{
   Print("[Test_ApplyProfit_WinIgnored]");
   EAState s = MakeFresh();
   CDailyLossManager::ApplyRealizedProfit(s, +600.0, 100000.0);
   AssertEqDbl(s.daily_loss_pct, 0.0, 1e-9, "win does not reduce loss counter");
}
void Test_ApplyProfit_ZeroEquityNoOp()
{
   Print("[Test_ApplyProfit_ZeroEquityNoOp]");
   EAState s = MakeFresh();
   CDailyLossManager::ApplyRealizedProfit(s, -300.0, 0.0);
   AssertEqDbl(s.daily_loss_pct, 0.0, 1e-9, "no day_start_equity = no-op");
}
void Test_TotalDD_NotBreached_AboveLine()
{
   Print("[Test_TotalDD_NotBreached_AboveLine]");
   Assert(!CDailyLossManager::IsTotalDDBreached(95000.0, 100000.0, 7.0), "equity above line");
   Assert(!CDailyLossManager::IsTotalDDBreached(93000.0, 100000.0, 7.0), "equity exactly on line (strict <)");
}
void Test_TotalDD_Breached_BelowLine()
{
   Print("[Test_TotalDD_Breached_BelowLine]");
   Assert(CDailyLossManager::IsTotalDDBreached(92999.99, 100000.0, 7.0), "equity 1 cent below line");
   Assert(CDailyLossManager::IsTotalDDBreached(80000.0,  100000.0, 7.0), "equity well below line");
}
void Test_TotalDD_NoBaselineYet()
{
   Print("[Test_TotalDD_NoBaselineYet]");
   Assert(!CDailyLossManager::IsTotalDDBreached(50000.0, 0.0,  7.0), "initial 0 -> never breached");
   Assert(!CDailyLossManager::IsTotalDDBreached(50000.0, -1.0, 7.0), "initial negative -> never breached");
}
void Test_TotalDD_OtherAccountSizes()
{
   Print("[Test_TotalDD_OtherAccountSizes]");
   Assert( CDailyLossManager::IsTotalDDBreached(185000.0, 200000.0, 7.0), "200k: below line");
   Assert(!CDailyLossManager::IsTotalDDBreached(190000.0, 200000.0, 7.0), "200k: above line");
}

void OnStart()
{
   g_passed = 0; g_failed = 0;
   Test_DateString_Format();
   Test_IsNewCETDate_FirstRun();
   Test_IsNewCETDate_SameDay();
   Test_IsNewCETDate_Rollover();
   Test_ResetForNewDay_ZerosCounters();
   Test_WouldBreach_BelowLimit();
   Test_WouldBreach_AtLimit();
   Test_WouldBreach_OverLimit();
   Test_ApplyProfit_LossOnly();
   Test_ApplyProfit_Accumulates();
   Test_ApplyProfit_WinIgnored();
   Test_ApplyProfit_ZeroEquityNoOp();
   Test_TotalDD_NotBreached_AboveLine();
   Test_TotalDD_Breached_BelowLine();
   Test_TotalDD_NoBaselineYet();
   Test_TotalDD_OtherAccountSizes();
   PrintFormat("===== Done. passed=%d failed=%d =====", g_passed, g_failed);
}
