//+------------------------------------------------------------------+
//|  Test_NewsFilter.mq5                                             |
//|  Phase 7 unit tests for CNewsFilter pure helpers.                |
//+------------------------------------------------------------------+
#property copyright "Phase 7 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\NewsFilter.mqh"

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
void AssertEqInt(const int got, const int exp, const string label)
{ if(got == exp) { g_passed++; PrintFormat("  PASS: %s", label); }
  else { g_failed++; PrintFormat("  FAIL: %s exp=%d got=%d", label, exp, got); } }

datetime MakeDt(int y, int m, int d, int h, int mi)
{ MqlDateTime t; ZeroMemory(t); t.year=y; t.mon=m; t.day=d; t.hour=h; t.min=mi; return StructToTime(t); }

//+------------------------------------------------------------------+
void Test_CurrenciesForSymbol_FXPair()
  {
   Print("[Test_CurrenciesForSymbol_FXPair]");
   string c[];
   AssertEqInt(CNewsFilter::CurrenciesForSymbol("EURUSD", c), 2, "EURUSD count");
   Assert((c[0] == "EUR" && c[1] == "USD"), "EURUSD = {EUR,USD}");
   CNewsFilter::CurrenciesForSymbol("USDJPY", c);
   Assert((c[0] == "USD" && c[1] == "JPY"), "USDJPY = {USD,JPY}");
   CNewsFilter::CurrenciesForSymbol("AUDUSD", c);
   Assert((c[0] == "AUD" && c[1] == "USD"), "AUDUSD = {AUD,USD}");
  }

//+------------------------------------------------------------------+
void Test_CurrenciesForSymbol_GoldAndIndex()
  {
   Print("[Test_CurrenciesForSymbol_GoldAndIndex]");
   string c[];
   AssertEqInt(CNewsFilter::CurrenciesForSymbol("XAUUSD", c), 1, "XAUUSD count");
   Assert(c[0] == "USD", "XAUUSD = {USD}");
   AssertEqInt(CNewsFilter::CurrenciesForSymbol("NAS100", c), 1, "NAS100 count");
   Assert(c[0] == "USD", "NAS100 = {USD}");
  }

//+------------------------------------------------------------------+
void Test_ImpactPasses()
  {
   Print("[Test_ImpactPasses]");
   Assert( CNewsFilter::ImpactPasses(CALENDAR_IMPORTANCE_HIGH,     "High"),    "High filter accepts HIGH");
   Assert(!CNewsFilter::ImpactPasses(CALENDAR_IMPORTANCE_MODERATE, "High"),    "High filter rejects MODERATE");
   Assert(!CNewsFilter::ImpactPasses(CALENDAR_IMPORTANCE_NONE,     "High"),    "High filter rejects NONE");
   Assert( CNewsFilter::ImpactPasses(CALENDAR_IMPORTANCE_MODERATE, "Medium+"), "Medium+ accepts MODERATE");
   Assert( CNewsFilter::ImpactPasses(CALENDAR_IMPORTANCE_HIGH,     "Medium+"), "Medium+ accepts HIGH");
   Assert(!CNewsFilter::ImpactPasses(CALENDAR_IMPORTANCE_LOW,      "Medium+"), "Medium+ rejects LOW");
   Assert( CNewsFilter::ImpactPasses(CALENDAR_IMPORTANCE_MODERATE, "Medium"),  "Medium (no +) accepts MODERATE");
   Assert( CNewsFilter::ImpactPasses(CALENDAR_IMPORTANCE_LOW,      "All"),     "All accepts LOW");
   Assert(!CNewsFilter::ImpactPasses(CALENDAR_IMPORTANCE_NONE,     "All"),     "All rejects NONE (holidays)");
   Assert( CNewsFilter::ImpactPasses(CALENDAR_IMPORTANCE_HIGH,     "garbage"), "unknown filter => treated as High");
  }

//+------------------------------------------------------------------+
void Test_IsWithinBlackout()
  {
   Print("[Test_IsWithinBlackout]");
   datetime now = MakeDt(2026, 5, 11, 14, 30);
   Assert( CNewsFilter::IsWithinBlackout(MakeDt(2026,5,11,14,30), now, 15, 15), "event == now");
   Assert( CNewsFilter::IsWithinBlackout(MakeDt(2026,5,11,14,16), now, 15, 15), "14 min before");
   Assert( CNewsFilter::IsWithinBlackout(MakeDt(2026,5,11,14,15), now, 15, 15), "exactly 15 min before (inclusive)");
   Assert(!CNewsFilter::IsWithinBlackout(MakeDt(2026,5,11,14,14), now, 15, 15), "16 min before => outside");
   Assert( CNewsFilter::IsWithinBlackout(MakeDt(2026,5,11,14,45), now, 15, 15), "exactly 15 min after (inclusive)");
   Assert(!CNewsFilter::IsWithinBlackout(MakeDt(2026,5,11,14,46), now, 15, 15), "16 min after => outside");
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   g_passed = 0; g_failed = 0;
   Test_CurrenciesForSymbol_FXPair();
   Test_CurrenciesForSymbol_GoldAndIndex();
   Test_ImpactPasses();
   Test_IsWithinBlackout();
   PrintFormat("===== Done. passed=%d failed=%d =====", g_passed, g_failed);
  }
