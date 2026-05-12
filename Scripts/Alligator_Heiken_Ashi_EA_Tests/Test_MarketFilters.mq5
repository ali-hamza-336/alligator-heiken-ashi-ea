//+------------------------------------------------------------------+
//|  Test_MarketFilters.mq5                                          |
//|  Phase 2 unit tests for IsDeadMarket and spread limit lookup.    |
//|  PipSize / CurrentSpreadPips / IsSpreadOK are integration-tested |
//|  via the EA on a chart (they read SymbolInfoXxx).                |
//+------------------------------------------------------------------+
#property copyright "Phase 2 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\MarketFilters.mqh"

int g_passed = 0;
int g_failed = 0;

void Assert(const bool cond, const string label)
{
   if(cond) { g_passed++; PrintFormat("  PASS: %s", label); }
   else     { g_failed++; PrintFormat("  FAIL: %s", label); }
}

void AssertEqDbl(const double got, const double expected, const double tol, const string label)
{
   if(MathAbs(got - expected) <= tol) { g_passed++; PrintFormat("  PASS: %s", label); }
   else { g_failed++; PrintFormat("  FAIL: %s  expected=%.6f got=%.6f tol=%.6f", label, expected, got, tol); }
}

//==================================================================
//  IsDeadMarket
//==================================================================

//+------------------------------------------------------------------+
//| Current ATR is half the running mean → dead at min_ratio=0.5.    |
//+------------------------------------------------------------------+
void Test_DeadMarket_Below()
{
   Print("[Test_DeadMarket_Below]");
   double atr[21];
   atr[0] = 0.4;                          // current
   for(int i = 1; i < 21; i++) atr[i] = 1.0;  // mean=1.0
   //  0.4 < 0.5 * 1.0 → dead
   Assert(CMarketFilters::IsDeadMarket(atr, 21, 0.5), "ratio 0.4 vs 0.5 → dead");
}

//+------------------------------------------------------------------+
//| Current ATR comfortably above ratio threshold → alive.           |
//+------------------------------------------------------------------+
void Test_DeadMarket_Above()
{
   Print("[Test_DeadMarket_Above]");
   double atr[21];
   atr[0] = 1.5;
   for(int i = 1; i < 21; i++) atr[i] = 1.0;
   Assert(!CMarketFilters::IsDeadMarket(atr, 21, 0.5), "ratio 1.5 → alive");
}

//+------------------------------------------------------------------+
//| Boundary: spec wording is "ATR_Now < ratio × avg" (strict).      |
//| atr[0] == ratio * mean must NOT be dead.                         |
//+------------------------------------------------------------------+
void Test_DeadMarket_BoundaryStrict()
{
   Print("[Test_DeadMarket_BoundaryStrict]");
   double atr[21];
   atr[0] = 0.5;
   for(int i = 1; i < 21; i++) atr[i] = 1.0;
   //  0.5 < 0.5*1.0 is false → alive
   Assert(!CMarketFilters::IsDeadMarket(atr, 21, 0.5), "boundary equality is alive");
}

//+------------------------------------------------------------------+
//| All-zero history → mean is 0 → guard returns false.              |
//+------------------------------------------------------------------+
void Test_DeadMarket_AllZeros()
{
   Print("[Test_DeadMarket_AllZeros]");
   double atr[21];
   for(int i = 0; i < 21; i++) atr[i] = 0.0;
   Assert(!CMarketFilters::IsDeadMarket(atr, 21, 0.5), "all-zero ATR → not dead (guard)");
}

//+------------------------------------------------------------------+
//| Pathological inputs.                                             |
//+------------------------------------------------------------------+
void Test_DeadMarket_BadInputs()
{
   Print("[Test_DeadMarket_BadInputs]");
   double atr[1] = {0.0};
   Assert(!CMarketFilters::IsDeadMarket(atr, 1, 0.5), "n<2 → false");
   double atr20[21];
   for(int i = 0; i < 21; i++) atr20[i] = 1.0;
   Assert(!CMarketFilters::IsDeadMarket(atr20, 21, 0.0),  "min_ratio==0 → false");
   Assert(!CMarketFilters::IsDeadMarket(atr20, 21, -0.5), "min_ratio<0 → false");
}

//+------------------------------------------------------------------+
//| Realistic mixed-history mean.                                    |
//+------------------------------------------------------------------+
void Test_DeadMarket_MixedHistory()
{
   Print("[Test_DeadMarket_MixedHistory]");
   double atr[5];
   //  History [1,2,3,4] → mean = 2.5. Current 1.2.
   //  1.2 < 0.5*2.5 = 1.25 → dead
   atr[0] = 1.2; atr[1] = 1.0; atr[2] = 2.0; atr[3] = 3.0; atr[4] = 4.0;
   Assert(CMarketFilters::IsDeadMarket(atr, 5, 0.5), "mixed history dead at 1.2 vs mean 2.5");
   //  Same history, current 1.3 → 1.3 < 1.25 false → alive
   atr[0] = 1.3;
   Assert(!CMarketFilters::IsDeadMarket(atr, 5, 0.5), "mixed history alive at 1.3");
}

//==================================================================
//  LookupSpreadLimit
//==================================================================

void Test_Lookup_AllSymbols()
{
   Print("[Test_Lookup_AllSymbols]");
   SpreadLimits L;
   L.EURUSD = 1.5;
   L.GBPUSD = 1.6;
   L.USDJPY = 2.0;
   L.USDCHF = 2.1;
   L.AUDUSD = 2.2;
   L.USDCAD = 2.3;
   L.NZDUSD = 2.4;
   L.XAUUSD = 30.0;
   L.NAS100 = 5.0;

   double out = -1.0;
   Assert(CMarketFilters::LookupSpreadLimit("EURUSD", L, out), "EURUSD found");
   AssertEqDbl(out, 1.5, 1e-9, "EURUSD value");
   Assert(CMarketFilters::LookupSpreadLimit("GBPUSD", L, out), "GBPUSD found");
   AssertEqDbl(out, 1.6, 1e-9, "GBPUSD value");
   Assert(CMarketFilters::LookupSpreadLimit("USDJPY", L, out), "USDJPY found");
   AssertEqDbl(out, 2.0, 1e-9, "USDJPY value");
   Assert(CMarketFilters::LookupSpreadLimit("XAUUSD", L, out), "XAUUSD found");
   AssertEqDbl(out, 30.0, 1e-9, "XAUUSD value");
   Assert(CMarketFilters::LookupSpreadLimit("NAS100", L, out), "NAS100 found");
   AssertEqDbl(out, 5.0, 1e-9, "NAS100 value");
}

void Test_Lookup_Unknown()
{
   Print("[Test_Lookup_Unknown]");
   SpreadLimits L;
   L.EURUSD = 1.5; L.GBPUSD = 1.5; L.USDJPY = 2.0; L.USDCHF = 2.0;
   L.AUDUSD = 2.0; L.USDCAD = 2.0; L.NZDUSD = 2.0; L.XAUUSD = 30.0; L.NAS100 = 2.0;
   double out = 99.0;
   Assert(!CMarketFilters::LookupSpreadLimit("BTCUSD", L, out), "unknown symbol returns false");
   AssertEqDbl(out, 0.0, 1e-9, "unknown clears out to 0");
   Assert(!CMarketFilters::LookupSpreadLimit("eurusd", L, out), "case-sensitive: lowercase rejected");
}

//==================================================================
void OnStart()
{
   Print("===== MarketFilters test suite =====");
   Test_DeadMarket_Below();
   Test_DeadMarket_Above();
   Test_DeadMarket_BoundaryStrict();
   Test_DeadMarket_AllZeros();
   Test_DeadMarket_BadInputs();
   Test_DeadMarket_MixedHistory();
   Test_Lookup_AllSymbols();
   Test_Lookup_Unknown();
   PrintFormat("===== Done.  passed=%d  failed=%d =====", g_passed, g_failed);
}
//+------------------------------------------------------------------+
