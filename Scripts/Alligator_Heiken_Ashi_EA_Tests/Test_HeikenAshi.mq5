//+------------------------------------------------------------------+
//|  Test_HeikenAshi.mq5                                             |
//|  Phase 2 unit tests for the pure HA Compute() function.          |
//|  Live wrapper (GetClosed) is integration-tested via the EA.      |
//+------------------------------------------------------------------+
#property copyright "Phase 2 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\HeikenAshi.mqh"

int g_passed = 0;
int g_failed = 0;

void Assert(const bool cond, const string label)
{
   if(cond) { g_passed++; PrintFormat("  PASS: %s", label); }
   else     { g_failed++; PrintFormat("  FAIL: %s", label); }
}

void AssertEqInt(const long got, const long expected, const string label)
{
   if(got == expected) { g_passed++; PrintFormat("  PASS: %s", label); }
   else { g_failed++; PrintFormat("  FAIL: %s  expected=%I64d got=%I64d", label, expected, got); }
}

void AssertEqDbl(const double got, const double expected, const double tol, const string label)
{
   if(MathAbs(got - expected) <= tol) { g_passed++; PrintFormat("  PASS: %s", label); }
   else { g_failed++; PrintFormat("  FAIL: %s  expected=%.6f got=%.6f tol=%.6f", label, expected, got, tol); }
}

//+------------------------------------------------------------------+
//| Bar 0 bootstrap: ha_open = (open+close)/2,                       |
//| ha_close = (o+h+l+c)/4, ha_high = max(h, ha_o, ha_c),            |
//| ha_low  = min(l, ha_o, ha_c).                                    |
//+------------------------------------------------------------------+
void Test_BootstrapBar()
{
   Print("[Test_BootstrapBar]");
   double o[1] = {100.0};
   double h[1] = {102.0};
   double l[1] = {99.0};
   double c[1] = {101.0};
   double ha_o[], ha_h[], ha_l[], ha_c[];

   const bool ok = CHeikenAshi::Compute(o, h, l, c, 1, ha_o, ha_h, ha_l, ha_c);
   Assert(ok, "Compute returns true on valid 1-bar input");
   AssertEqInt(ArraySize(ha_o), 1, "output sized to 1");
   AssertEqDbl(ha_o[0], 100.5, 1e-9, "ha_open[0] = (100+101)/2");
   AssertEqDbl(ha_c[0], 100.5, 1e-9, "ha_close[0] = (100+102+99+101)/4");
   AssertEqDbl(ha_h[0], 102.0, 1e-9, "ha_high[0] = max(high, ha_o, ha_c)");
   AssertEqDbl(ha_l[0], 99.0,  1e-9, "ha_low[0]  = min(low,  ha_o, ha_c)");
}

//+------------------------------------------------------------------+
//| Recursive bar: ha_open[i] = (ha_open[i-1] + ha_close[i-1]) / 2.  |
//+------------------------------------------------------------------+
void Test_RecursiveTwoBars()
{
   Print("[Test_RecursiveTwoBars]");
   //  Bar 0: O=100 H=102 L=99 C=101
   //  Bar 1: O=101 H=103 L=100 C=102
   double o[2] = {100.0, 101.0};
   double h[2] = {102.0, 103.0};
   double l[2] = {99.0,  100.0};
   double c[2] = {101.0, 102.0};
   double ha_o[], ha_h[], ha_l[], ha_c[];

   CHeikenAshi::Compute(o, h, l, c, 2, ha_o, ha_h, ha_l, ha_c);

   //  Bar 0 (bootstrap)
   AssertEqDbl(ha_o[0], 100.5, 1e-9, "bar0 ha_o");
   AssertEqDbl(ha_c[0], 100.5, 1e-9, "bar0 ha_c");
   //  Bar 1
   //  ha_o[1] = (ha_o[0] + ha_c[0]) / 2 = (100.5 + 100.5)/2 = 100.5
   //  ha_c[1] = (101+103+100+102)/4 = 101.5
   //  ha_h[1] = max(103, 100.5, 101.5) = 103
   //  ha_l[1] = min(100, 100.5, 101.5) = 100
   AssertEqDbl(ha_o[1], 100.5, 1e-9, "bar1 ha_o = avg of prev ha_o & ha_c");
   AssertEqDbl(ha_c[1], 101.5, 1e-9, "bar1 ha_c = (o+h+l+c)/4");
   AssertEqDbl(ha_h[1], 103.0, 1e-9, "bar1 ha_h");
   AssertEqDbl(ha_l[1], 100.0, 1e-9, "bar1 ha_l");
}

//+------------------------------------------------------------------+
//| Doji (open == high == low == close): all four HA values equal.   |
//+------------------------------------------------------------------+
void Test_Doji()
{
   Print("[Test_Doji]");
   double o[1] = {1.2345};
   double h[1] = {1.2345};
   double l[1] = {1.2345};
   double c[1] = {1.2345};
   double ha_o[], ha_h[], ha_l[], ha_c[];

   CHeikenAshi::Compute(o, h, l, c, 1, ha_o, ha_h, ha_l, ha_c);
   AssertEqDbl(ha_o[0], 1.2345, 1e-9, "doji ha_o");
   AssertEqDbl(ha_c[0], 1.2345, 1e-9, "doji ha_c");
   AssertEqDbl(ha_h[0], 1.2345, 1e-9, "doji ha_h");
   AssertEqDbl(ha_l[0], 1.2345, 1e-9, "doji ha_l");
}

//+------------------------------------------------------------------+
//| Bullish-then-bearish: HA high/low must reach beyond ha_open and  |
//| ha_close to engulf the real candle's wicks.                      |
//+------------------------------------------------------------------+
void Test_BullishThenBearish()
{
   Print("[Test_BullishThenBearish]");
   //  Bar 0 bullish: O=100 H=105 L=100 C=105
   //  Bar 1 bearish: O=105 H=105 L=98  C=99
   double o[2] = {100.0, 105.0};
   double h[2] = {105.0, 105.0};
   double l[2] = {100.0, 98.0};
   double c[2] = {105.0, 99.0};
   double ha_o[], ha_h[], ha_l[], ha_c[];

   CHeikenAshi::Compute(o, h, l, c, 2, ha_o, ha_h, ha_l, ha_c);

   //  Bar 0:
   //  ha_o[0]=(100+105)/2=102.5, ha_c[0]=(100+105+100+105)/4=102.5
   //  ha_h[0]=max(105, 102.5, 102.5)=105, ha_l[0]=min(100, ...)=100
   AssertEqDbl(ha_o[0], 102.5, 1e-9, "bar0 ha_o");
   AssertEqDbl(ha_c[0], 102.5, 1e-9, "bar0 ha_c");
   AssertEqDbl(ha_h[0], 105.0, 1e-9, "bar0 ha_h");
   AssertEqDbl(ha_l[0], 100.0, 1e-9, "bar0 ha_l");

   //  Bar 1:
   //  ha_o[1]=(102.5+102.5)/2=102.5
   //  ha_c[1]=(105+105+98+99)/4=101.75
   //  ha_h[1]=max(105, 102.5, 101.75)=105
   //  ha_l[1]=min(98, 102.5, 101.75)=98
   AssertEqDbl(ha_o[1], 102.5,  1e-9, "bar1 ha_o");
   AssertEqDbl(ha_c[1], 101.75, 1e-9, "bar1 ha_c");
   AssertEqDbl(ha_h[1], 105.0,  1e-9, "bar1 ha_h reaches real high");
   AssertEqDbl(ha_l[1], 98.0,   1e-9, "bar1 ha_l reaches real low");
}

//+------------------------------------------------------------------+
//| Invariant: ha_low <= min(ha_open, ha_close) <= max <= ha_high.   |
//| Also: ha_low <= real_low and ha_high >= real_high.               |
//+------------------------------------------------------------------+
void Test_Invariants_LongSeries()
{
   Print("[Test_Invariants_LongSeries]");
   const int N = 8;
   double o[8] = {100, 101, 102, 101, 99,  98,  97,  98};
   double h[8] = {101, 103, 103, 102, 100, 99,  98,  100};
   double l[8] = {99,  100, 101, 99,  98,  96,  96,  97};
   double c[8] = {101, 102, 101, 100, 98,  97,  97,  100};
   double ha_o[], ha_h[], ha_l[], ha_c[];

   CHeikenAshi::Compute(o, h, l, c, N, ha_o, ha_h, ha_l, ha_c);

   bool inv_ok = true;
   for(int i = 0; i < N; i++)
     {
      const double bmin = MathMin(ha_o[i], ha_c[i]);
      const double bmax = MathMax(ha_o[i], ha_c[i]);
      if(ha_l[i] > bmin)            { inv_ok = false; PrintFormat("  bar%d ha_l>%f body_min", i, bmin); }
      if(ha_h[i] < bmax)            { inv_ok = false; PrintFormat("  bar%d ha_h<%f body_max", i, bmax); }
      if(ha_l[i] > l[i])            { inv_ok = false; PrintFormat("  bar%d ha_l>real_low",  i); }
      if(ha_h[i] < h[i])            { inv_ok = false; PrintFormat("  bar%d ha_h<real_high", i); }
     }
   Assert(inv_ok, "all bars satisfy ha_low <= body <= ha_high and engulf real high/low");
}

//+------------------------------------------------------------------+
//| Bad inputs return false without crashing.                        |
//+------------------------------------------------------------------+
void Test_BadInputs()
{
   Print("[Test_BadInputs]");
   double o[2] = {1.0, 2.0};
   double h[2] = {1.0, 2.0};
   double l[2] = {1.0, 2.0};
   double c_short[1] = {1.0};
   double ha_o[], ha_h[], ha_l[], ha_c[];

   //  count larger than smallest input array
   const bool ok1 = CHeikenAshi::Compute(o, h, l, c_short, 2, ha_o, ha_h, ha_l, ha_c);
   Assert(!ok1, "Compute returns false when count > shortest input");

   //  count <= 0
   double dummy[1] = {0};
   const bool ok2 = CHeikenAshi::Compute(dummy, dummy, dummy, dummy, 0, ha_o, ha_h, ha_l, ha_c);
   Assert(!ok2, "Compute returns false on count==0");
}

//+------------------------------------------------------------------+
void OnStart()
{
   Print("===== HeikenAshi test suite (pure compute) =====");
   Test_BootstrapBar();
   Test_RecursiveTwoBars();
   Test_Doji();
   Test_BullishThenBearish();
   Test_Invariants_LongSeries();
   Test_BadInputs();
   PrintFormat("===== Done.  passed=%d  failed=%d =====", g_passed, g_failed);
}
//+------------------------------------------------------------------+
