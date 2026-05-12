//+------------------------------------------------------------------+
//|  Test_SRDetector.mq5                                             |
//|  Phase 2 unit tests for swing detection, dedupe, touch count.    |
//|  Live Build() wrapper integration-tested via the EA.             |
//+------------------------------------------------------------------+
#property copyright "Phase 2 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\SRDetector.mqh"

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

//==================================================================
//  DetectSwings tests
//==================================================================

//+------------------------------------------------------------------+
//| 7 bars, each_side=3, single obvious swing high in the middle.    |
//+------------------------------------------------------------------+
void Test_SwingHigh_ObviousMiddle()
{
   Print("[Test_SwingHigh_ObviousMiddle]");
   //                  i:  0    1    2    3*   4    5    6
   double highs[7] = {1.0, 2.0, 3.0, 5.0, 3.5, 2.5, 1.5};
   double lows [7] = {0.5, 1.5, 2.5, 4.5, 3.0, 2.0, 1.0};
   double sh[], sl[];

   const int total = CSRDetector::DetectSwings(highs, lows, 7, 3, sh, sl);
   AssertEqInt(ArraySize(sh), 1, "exactly one swing high");
   if(ArraySize(sh) >= 1) AssertEqDbl(sh[0], 5.0, 1e-9, "swing high value");
   //  Lows are monotonic-ish — index 3 has low=4.5 > neighbors, index 6 has lowest 1.0
   //  but index 6 is at edge with each_side=3 (no right window) → not a swing.
   //  For lows: index 3 has 4.5 which is HIGHER than neighbors (not a swing low).
   //  Actually with each_side=3, valid indices are 3..3 only → single index.
   //  At index 3: low=4.5, surrounding lows are {0.5,1.5,2.5} & {3.0,2.0,1.0} → all less → not a swing low.
   AssertEqInt(ArraySize(sl), 0, "no swing low in this series");
   AssertEqInt(total, 1, "total = sh+sl count");
}

//+------------------------------------------------------------------+
//| 7 bars, each_side=3, single obvious swing low.                   |
//+------------------------------------------------------------------+
void Test_SwingLow_ObviousMiddle()
{
   Print("[Test_SwingLow_ObviousMiddle]");
   double highs[7] = {5.0, 4.0, 3.0, 2.0, 3.0, 4.0, 5.0};
   double lows [7] = {4.5, 3.5, 2.5, 1.0, 2.5, 3.5, 4.5};
   double sh[], sl[];

   CSRDetector::DetectSwings(highs, lows, 7, 3, sh, sl);
   AssertEqInt(ArraySize(sl), 1, "exactly one swing low");
   if(ArraySize(sl) >= 1) AssertEqDbl(sl[0], 1.0, 1e-9, "swing low value");
   AssertEqInt(ArraySize(sh), 0, "no swing high in this series");
}

//+------------------------------------------------------------------+
//| Boundary: a peak at edge should NOT register (no full window).   |
//+------------------------------------------------------------------+
void Test_BoundaryNoSwing()
{
   Print("[Test_BoundaryNoSwing]");
   //  Peak at index 0 and index 6 — with each_side=3, valid range is i in [3,3].
   double highs[7] = {10.0, 1.0, 1.0, 1.0, 1.0, 1.0, 10.0};
   double lows [7] = {9.0,  0.5, 0.5, 0.5, 0.5, 0.5, 9.0};
   double sh[], sl[];

   CSRDetector::DetectSwings(highs, lows, 7, 3, sh, sl);
   AssertEqInt(ArraySize(sh), 0, "edge peaks excluded by window");
   //  At index 3: highs[3]=1.0, neighbors {1,1,1}&{1,1,1} — strict > fails → not a swing.
}

//+------------------------------------------------------------------+
//| Tie at neighbor → strict > fails → not a swing.                  |
//+------------------------------------------------------------------+
void Test_TieNotSwing()
{
   Print("[Test_TieNotSwing]");
   double highs[7] = {1.0, 2.0, 3.0, 5.0, 5.0, 2.0, 1.0};
   double lows [7] = {0,   0,   0,   0,   0,   0,   0};
   double sh[], sl[];

   CSRDetector::DetectSwings(highs, lows, 7, 3, sh, sl);
   AssertEqInt(ArraySize(sh), 0, "tie with right neighbor blocks swing");
}

//+------------------------------------------------------------------+
//| each_side=1 finds more swings than each_side=3 on same data.     |
//+------------------------------------------------------------------+
void Test_EachSideSensitivity()
{
   Print("[Test_EachSideSensitivity]");
   //  Two local peaks: indexes 2 and 6 (each is higher than immediate neighbors).
   double highs[9] = {1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0};
   double lows [9] = {0,0,0,0,0,0,0,0,0};
   double sh1[], sl1[], sh3[], sl3[];

   CSRDetector::DetectSwings(highs, lows, 9, 1, sh1, sl1);
   CSRDetector::DetectSwings(highs, lows, 9, 3, sh3, sl3);

   AssertEqInt(ArraySize(sh1), 2, "each_side=1 finds 2 peaks");
   //  each_side=3 needs strictly greater than 3 neighbors each side.
   //  At i=3..5 (valid range), highs are 2,1,2 — none is greater than 3 neighbors on both sides.
   AssertEqInt(ArraySize(sh3), 0, "each_side=3 too strict for narrow peaks");
}

//+------------------------------------------------------------------+
//| Too few bars for the window → return 0.                          |
//+------------------------------------------------------------------+
void Test_InsufficientBars()
{
   Print("[Test_InsufficientBars]");
   double highs[5] = {1, 2, 3, 2, 1};
   double lows [5] = {0, 0, 0, 0, 0};
   double sh[], sl[];
   CSRDetector::DetectSwings(highs, lows, 5, 3, sh, sl);
   AssertEqInt(ArraySize(sh), 0, "n < 2*each_side+1 → no swings");
   AssertEqInt(ArraySize(sl), 0, "n < 2*each_side+1 → no swings (low)");
}

//==================================================================
//  Dedupe tests
//==================================================================

//  Dedupe requires a DYNAMIC `levels[]` (it calls ArrayResize). Helper
//  to build one without per-test boilerplate.
void MakeDyn(double &out[], const double &src[], const int n)
{
   ArrayResize(out, n);
   for(int i = 0; i < n; i++) out[i] = src[i];
}

void Test_Dedupe_TwoCloseLevels()
{
   Print("[Test_Dedupe_TwoCloseLevels]");
   double src[2] = {1.0000, 1.0010};
   double levels[];
   MakeDyn(levels, src, 2);
   const int n = CSRDetector::Dedupe(levels, 0.0020);
   AssertEqInt(n, 1, "two close levels merge to one");
   if(n == 1) AssertEqDbl(levels[0], 1.0005, 1e-9, "merged value is mean");
}

void Test_Dedupe_FarApartKept()
{
   Print("[Test_Dedupe_FarApartKept]");
   double src[2] = {1.0000, 2.0000};
   double levels[];
   MakeDyn(levels, src, 2);
   const int n = CSRDetector::Dedupe(levels, 0.0010);
   AssertEqInt(n, 2, "far apart kept");
}

void Test_Dedupe_TolZeroNoMerge()
{
   Print("[Test_Dedupe_TolZeroNoMerge]");
   double src[3] = {1.0, 1.0, 2.0};
   double levels[];
   MakeDyn(levels, src, 3);
   //  tol=0 must never merge (per impl: tol>0 required).
   const int n = CSRDetector::Dedupe(levels, 0.0);
   AssertEqInt(n, 3, "tol==0 never merges");
}

void Test_Dedupe_ChainCluster()
{
   Print("[Test_Dedupe_ChainCluster]");
   //  Three increments of 0.001, tol 0.002 (clear margin over running mean drift)
   //  → all roll into one cluster.
   double src[3] = {1.000, 1.001, 1.002};
   double levels[];
   MakeDyn(levels, src, 3);
   const int n = CSRDetector::Dedupe(levels, 0.002);
   AssertEqInt(n, 1, "chain merges into single cluster");
   if(n == 1) AssertEqDbl(levels[0], 1.001, 1e-9, "cluster value = mean of all members");
}

void Test_Dedupe_UnsortedInput()
{
   Print("[Test_Dedupe_UnsortedInput]");
   double src[4] = {3.0, 1.0, 1.0005, 2.999};
   double levels[];
   MakeDyn(levels, src, 4);
   const int n = CSRDetector::Dedupe(levels, 0.002);
   AssertEqInt(n, 2, "unsorted input still dedupes correctly");
   if(n == 2)
     {
      //  Cluster A: {1.0, 1.0005} → 1.00025
      //  Cluster B: {2.999, 3.0}  → 2.9995
      AssertEqDbl(levels[0], 1.00025, 1e-9, "first dedupe cluster");
      AssertEqDbl(levels[1], 2.9995,  1e-9, "second dedupe cluster");
     }
}

void Test_Dedupe_SingleAndEmpty()
{
   Print("[Test_Dedupe_SingleAndEmpty]");
   double s_src[1] = {1.5};
   double single[];
   MakeDyn(single, s_src, 1);
   AssertEqInt(CSRDetector::Dedupe(single, 0.1), 1, "single level untouched");
   double empty[];
   AssertEqInt(CSRDetector::Dedupe(empty, 0.1), 0, "empty array safe");
}

//==================================================================
//  CountTouches tests
//==================================================================

void Test_Touches_None()
{
   Print("[Test_Touches_None]");
   double h[3] = {10, 11, 12};
   double l[3] = {9, 10, 11};
   AssertEqInt(CSRDetector::CountTouches(h, l, 3, 100.0, 0.5), 0, "level out of range → 0");
}

void Test_Touches_ViaHighs()
{
   Print("[Test_Touches_ViaHighs]");
   double h[3] = {10.0, 10.05, 11.0};
   double l[3] = {9.0,  9.5,   10.5};
   //  level=10.0, tol=0.1 → bar 0 touches via high (|10-10|=0), bar 1 via high (|10.05-10|=0.05).
   AssertEqInt(CSRDetector::CountTouches(h, l, 3, 10.0, 0.1), 2, "two bars touch via high");
}

void Test_Touches_MixedHighAndLow()
{
   Print("[Test_Touches_MixedHighAndLow]");
   double h[3] = {10.5, 11.0, 12.0};
   double l[3] = {9.95, 10.0, 11.5};
   //  level=10.0, tol=0.1: bar 0 via low (|9.95-10|=0.05), bar 1 via low (|10-10|=0).
   //  Bar 2: |11.5-10|=1.5 (no), |12-10|=2.0 (no).
   AssertEqInt(CSRDetector::CountTouches(h, l, 3, 10.0, 0.1), 2, "two touches mixed (both via low)");
}

void Test_Touches_NoDoubleCount()
{
   Print("[Test_Touches_NoDoubleCount]");
   //  A single bar that touches via BOTH high and low must count as 1, not 2.
   double h[1] = {10.05};
   double l[1] = {9.95};
   AssertEqInt(CSRDetector::CountTouches(h, l, 1, 10.0, 0.1), 1, "high+low both within tol counts as 1");
}

//==================================================================
void OnStart()
{
   Print("===== SRDetector test suite =====");
   //  DetectSwings
   Test_SwingHigh_ObviousMiddle();
   Test_SwingLow_ObviousMiddle();
   Test_BoundaryNoSwing();
   Test_TieNotSwing();
   Test_EachSideSensitivity();
   Test_InsufficientBars();
   //  Dedupe
   Test_Dedupe_TwoCloseLevels();
   Test_Dedupe_FarApartKept();
   Test_Dedupe_TolZeroNoMerge();
   Test_Dedupe_ChainCluster();
   Test_Dedupe_UnsortedInput();
   Test_Dedupe_SingleAndEmpty();
   //  CountTouches
   Test_Touches_None();
   Test_Touches_ViaHighs();
   Test_Touches_MixedHighAndLow();
   Test_Touches_NoDoubleCount();
   PrintFormat("===== Done.  passed=%d  failed=%d =====", g_passed, g_failed);
}
//+------------------------------------------------------------------+
