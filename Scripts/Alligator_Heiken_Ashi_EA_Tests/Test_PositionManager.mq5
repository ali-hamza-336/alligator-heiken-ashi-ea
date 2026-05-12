//+------------------------------------------------------------------+
//|  Test_PositionManager.mq5                                        |
//|  Phase 4 unit tests for sizing + order helpers (pure parts).     |
//|  Live wrappers (BuildPlan, Place) are integration-tested via EA. |
//+------------------------------------------------------------------+
#property copyright "Phase 4 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\PositionManager.mqh"

int g_passed = 0;
int g_failed = 0;

void Assert(const bool cond, const string label)
{
   if(cond) { g_passed++; PrintFormat("  PASS: %s", label); }
   else     { g_failed++; PrintFormat("  FAIL: %s", label); }
}
void AssertEqDbl(const double got, const double exp, const double tol, const string label)
{
   if(MathAbs(got - exp) <= tol) { g_passed++; PrintFormat("  PASS: %s", label); }
   else { g_failed++; PrintFormat("  FAIL: %s exp=%.6f got=%.6f tol=%.6f", label, exp, got, tol); }
}

//==================================================================
// PipValuePerLot
//==================================================================
void Test_PipValue_EURUSD_5digit()
{
   Print("[Test_PipValue_EURUSD_5digit]");
   //  USD account, EURUSD: tick_value=$1, tick_size=0.00001, pip=0.0001
   //  → pip_value = 1 * (0.0001/0.00001) = $10
   AssertEqDbl(CPositionManager::PipValuePerLot(1.00, 0.00001, 0.0001),
               10.0, 1e-6, "EURUSD pip value = $10");
}
void Test_PipValue_USDJPY_3digit()
{
   Print("[Test_PipValue_USDJPY_3digit]");
   //  USD account, USDJPY @ ~150: tick_value≈$0.0667, tick_size=0.001, pip=0.01
   //  → pip_value = 0.0667 * (0.01/0.001) = $0.667 (broker reports in account ccy)
   AssertEqDbl(CPositionManager::PipValuePerLot(0.0667, 0.001, 0.01),
               0.667, 1e-3, "USDJPY 3-digit pip value");
}
void Test_PipValue_XAUUSD()
{
   Print("[Test_PipValue_XAUUSD]");
   //  USD account, XAUUSD: tick_value=$1, tick_size=0.01, pip=0.01
   //  → pip_value = $1 per pip per lot
   AssertEqDbl(CPositionManager::PipValuePerLot(1.00, 0.01, 0.01),
               1.0, 1e-6, "XAUUSD pip value = $1");
}
void Test_PipValue_NAS100()
{
   Print("[Test_PipValue_NAS100]");
   //  USD account, NAS100: tick_value=$1, tick_size=0.01, pip=0.01
   //  → pip_value = $1 (1 point on NAS100)
   AssertEqDbl(CPositionManager::PipValuePerLot(1.00, 0.01, 0.01),
               1.0, 1e-6, "NAS100 pip value = $1/point");
}
void Test_PipValue_GuardZeroTickSize()
{
   Print("[Test_PipValue_GuardZeroTickSize]");
   AssertEqDbl(CPositionManager::PipValuePerLot(1.00, 0.0, 0.0001),
               0.0, 1e-9, "tick_size=0 returns 0");
}

//==================================================================
// RiskPctForStreak
//==================================================================
void Test_RiskPct_Position1()
{
   Print("[Test_RiskPct_Position1]");
   AssertEqDbl(CPositionManager::RiskPctForStreak(1, 0.30, 0.50, 0.70),
               0.30, 1e-9, "streak=1 → 0.30");
}
void Test_RiskPct_Position2()
{
   Print("[Test_RiskPct_Position2]");
   AssertEqDbl(CPositionManager::RiskPctForStreak(2, 0.30, 0.50, 0.70),
               0.50, 1e-9, "streak=2 → 0.50");
}
void Test_RiskPct_Position3()
{
   Print("[Test_RiskPct_Position3]");
   AssertEqDbl(CPositionManager::RiskPctForStreak(3, 0.30, 0.50, 0.70),
               0.70, 1e-9, "streak=3 → 0.70");
}
void Test_RiskPct_OutOfRange()
{
   Print("[Test_RiskPct_OutOfRange]");
   //  Defensive: out-of-range streak returns 0 so caller's lot collapses
   //  to invalid (caught downstream) rather than silently using a guess.
   AssertEqDbl(CPositionManager::RiskPctForStreak(0, 0.30, 0.50, 0.70),
               0.0, 1e-9, "streak=0 → 0");
   AssertEqDbl(CPositionManager::RiskPctForStreak(4, 0.30, 0.50, 0.70),
               0.0, 1e-9, "streak=4 → 0");
}

//==================================================================
// LotSizeFor
//==================================================================
void Test_LotSize_EURUSD_BasicCase()
{
   Print("[Test_LotSize_EURUSD_BasicCase]");
   //  Equity=100k, risk=0.30%, SL=20 pips, pip_value=$10/lot, pip=0.0001
   //  Risk_amount = $300; SL price distance = 20*0.0001 = 0.002
   //  Lot_raw = 300 / (20 * 10) = 1.50
   AssertEqDbl(CPositionManager::LotSizeFor(100000.0, 0.30, 0.0020, 10.0, 0.0001),
               1.50, 1e-6, "EURUSD baseline 1.50 lots");
}
void Test_LotSize_USDJPY_Case()
{
   Print("[Test_LotSize_USDJPY_Case]");
   //  Equity=100k, risk=0.50%, SL=15 pips, pip_value=$0.667, pip=0.01
   //  SL price = 15*0.01 = 0.15; Risk = $500
   //  Lot_raw = 500 / (15 * 0.667) ≈ 49.97
   AssertEqDbl(CPositionManager::LotSizeFor(100000.0, 0.50, 0.15, 0.667, 0.01),
               49.975, 0.05, "USDJPY ~49.97 lots (raw, before clamp)");
}
void Test_LotSize_XAUUSD_Case()
{
   Print("[Test_LotSize_XAUUSD_Case]");
   //  Equity=100k, risk=0.70%, SL=200 cents, pip_value=$1, pip=0.01
   //  SL price = 200*0.01 = 2.00; Risk = $700
   //  Lot_raw = 700 / (200 * 1) = 3.50
   AssertEqDbl(CPositionManager::LotSizeFor(100000.0, 0.70, 2.0, 1.0, 0.01),
               3.50, 1e-6, "XAUUSD 3.50 lots");
}
void Test_LotSize_GuardZeroPipValue()
{
   Print("[Test_LotSize_GuardZeroPipValue]");
   AssertEqDbl(CPositionManager::LotSizeFor(100000.0, 0.30, 0.002, 0.0, 0.0001),
               0.0, 1e-9, "pip_value=0 returns 0");
}
void Test_LotSize_GuardZeroSL()
{
   Print("[Test_LotSize_GuardZeroSL]");
   AssertEqDbl(CPositionManager::LotSizeFor(100000.0, 0.30, 0.0, 10.0, 0.0001),
               0.0, 1e-9, "SL distance 0 returns 0");
}

//==================================================================
// NormalizeLot
//==================================================================
void Test_NormalizeLot_RoundDownToStep()
{
   Print("[Test_NormalizeLot_RoundDownToStep]");
   //  1.234 with step 0.01 → 1.23 (round DOWN, never exceed risk)
   AssertEqDbl(CPositionManager::NormalizeLot(1.234, 0.01, 100.0, 0.01),
               1.23, 1e-9, "1.234 → 1.23 (step 0.01)");
}
void Test_NormalizeLot_ClampToMin()
{
   Print("[Test_NormalizeLot_ClampToMin]");
   //  Raw 0.005 < min 0.01 → return 0 (don't trade — caller flags invalid)
   AssertEqDbl(CPositionManager::NormalizeLot(0.005, 0.01, 100.0, 0.01),
               0.0, 1e-9, "below min → 0 (skip trade)");
}
void Test_NormalizeLot_ClampToMax()
{
   Print("[Test_NormalizeLot_ClampToMax]");
   AssertEqDbl(CPositionManager::NormalizeLot(150.0, 0.01, 50.0, 0.01),
               50.0, 1e-9, "above max → max");
}
void Test_NormalizeLot_StepPoint1()
{
   Print("[Test_NormalizeLot_StepPoint1]");
   //  1.27 with step 0.1 → 1.2
   AssertEqDbl(CPositionManager::NormalizeLot(1.27, 0.01, 100.0, 0.1),
               1.2, 1e-9, "1.27 → 1.2 (step 0.1)");
}
void Test_NormalizeLot_StepIntegerWhole()
{
   Print("[Test_NormalizeLot_StepIntegerWhole]");
   //  3.7 with step 1.0 → 3.0
   AssertEqDbl(CPositionManager::NormalizeLot(3.7, 1.0, 100.0, 1.0),
               3.0, 1e-9, "3.7 → 3.0 (step 1)");
}

//==================================================================
// SLDistanceFloor (Path A — minimum allowed SL distance)
//==================================================================
void Test_SLFloor_AtrTermDominates()
{
   Print("[Test_SLFloor_AtrTermDominates]");
   //  stops_level 10 pts × point 0.00001 = 0.00010; ATR 0.0050 × mult 1.0 = 0.0050.
   //  Floor = max(0.00010, 0.00500) = 0.00500.
   AssertEqDbl(CPositionManager::SLDistanceFloor(10, 0.00001, 0.0050, 1.0),
               0.00500, 1e-9, "ATR term wins");
}
void Test_SLFloor_StopsLevelTermDominates()
{
   Print("[Test_SLFloor_StopsLevelTermDominates]");
   //  stops_level 300 pts × point 0.00001 = 0.00300; ATR 0.0010 × mult 1.0 = 0.0010.
   //  Floor = max(0.00300, 0.00100) = 0.00300.
   AssertEqDbl(CPositionManager::SLDistanceFloor(300, 0.00001, 0.0010, 1.0),
               0.00300, 1e-9, "stops-level term wins");
}
void Test_SLFloor_ZeroAtr_FallsBackToStopsLevel()
{
   Print("[Test_SLFloor_ZeroAtr_FallsBackToStopsLevel]");
   //  ATR 0 → ATR term dropped; floor = stops_level term only.
   AssertEqDbl(CPositionManager::SLDistanceFloor(50, 0.00001, 0.0, 1.0),
               0.00050, 1e-9, "ATR=0 → stops-level only");
   //  Both zero → floor 0.
   AssertEqDbl(CPositionManager::SLDistanceFloor(0, 0.00001, 0.0, 1.0),
               0.0, 1e-9, "both terms 0 → floor 0");
}
void Test_SLFloor_MultZeroDropsAtrTerm()
{
   Print("[Test_SLFloor_MultZeroDropsAtrTerm]");
   //  mult 0 → ATR term dropped even with a real ATR; floor = stops_level term.
   AssertEqDbl(CPositionManager::SLDistanceFloor(20, 0.00001, 0.0080, 0.0),
               0.00020, 1e-9, "mult=0 → stops-level only");
}

//==================================================================
// InitialTPPrice
//==================================================================
void Test_TP_BuyDefault2R_NoSR()
{
   Print("[Test_TP_BuyDefault2R_NoSR]");
   double sr_above[]; ArrayResize(sr_above, 0);
   //  Entry=1.10000, SL=1.09800 → R=0.0020; no S/R → TP = entry + 2R = 1.10400
   const double tp = CPositionManager::InitialTPPrice(true,  1.10000, 1.09800, sr_above);
   AssertEqDbl(tp, 1.10400, 1e-9, "BUY no-SR → 2R");
}
void Test_TP_BuySRClosedThan2R()
{
   Print("[Test_TP_BuySRClosedThan2R]");
   //  R=0.0020; 2R=1.10400. S/R levels: 1.10300 (1.5R, in window 5R) & 1.10800 (4R)
   //  Nearest S/R above entry within 5R = 1.10300 → closer than 2R → TP=1.10300
   double sr_above[];
   ArrayResize(sr_above, 2);
   sr_above[0] = 1.10300; sr_above[1] = 1.10800;
   const double tp = CPositionManager::InitialTPPrice(true, 1.10000, 1.09800, sr_above);
   AssertEqDbl(tp, 1.10300, 1e-9, "BUY S/R at 1.5R → TP=S/R");
}
void Test_TP_BuySRBeyond5R_Default2R()
{
   Print("[Test_TP_BuySRBeyond5R_Default2R]");
   //  R=0.0020; 2R=1.10400; 5R=1.11000. S/R at 1.11500 is OUTSIDE 5R → default 2R.
   double sr_above[]; ArrayResize(sr_above, 1); sr_above[0] = 1.11500;
   const double tp = CPositionManager::InitialTPPrice(true, 1.10000, 1.09800, sr_above);
   AssertEqDbl(tp, 1.10400, 1e-9, "BUY S/R beyond 5R → 2R default");
}
void Test_TP_BuySRBelowEntryIgnored()
{
   Print("[Test_TP_BuySRBelowEntryIgnored]");
   //  S/R at 1.09900 is below entry → ignored for BUY. Default 2R applies.
   double sr_above[]; ArrayResize(sr_above, 1); sr_above[0] = 1.09900;
   const double tp = CPositionManager::InitialTPPrice(true, 1.10000, 1.09800, sr_above);
   AssertEqDbl(tp, 1.10400, 1e-9, "BUY S/R below entry ignored");
}
void Test_TP_SellMirror()
{
   Print("[Test_TP_SellMirror]");
   //  SELL: Entry=1.10000, SL=1.10200 → R=0.0020; 2R below = 1.09600
   //  S/R support at 1.09700 (1.5R below) → nearer than 2R → TP=1.09700
   double sr_below[]; ArrayResize(sr_below, 1); sr_below[0] = 1.09700;
   const double tp = CPositionManager::InitialTPPrice(false, 1.10000, 1.10200, sr_below);
   AssertEqDbl(tp, 1.09700, 1e-9, "SELL S/R at 1.5R → TP=S/R");
}
void Test_TP_SellNoSR_Default2R()
{
   Print("[Test_TP_SellNoSR_Default2R]");
   double sr_below[]; ArrayResize(sr_below, 0);
   const double tp = CPositionManager::InitialTPPrice(false, 1.10000, 1.10200, sr_below);
   AssertEqDbl(tp, 1.09600, 1e-9, "SELL no-SR → 2R below");
}

//==================================================================
// SlippagePoints
//==================================================================
void Test_Slip_FX_5digit()
{
   Print("[Test_Slip_FX_5digit]");
   //  3 pips on a 5-digit broker (point=0.00001, pip=0.0001) → 30 points
   AssertEqDbl((double)CPositionManager::SlippagePoints("EURUSD", 3, 50, 5,
                                                        0.00001, 0.0001),
               30.0, 1e-9, "FX 3 pips on 5-digit → 30 points");
}
void Test_Slip_FX_4digit()
{
   Print("[Test_Slip_FX_4digit]");
   //  3 pips on a 4-digit broker (point=0.0001, pip=0.0001) → 3 points
   AssertEqDbl((double)CPositionManager::SlippagePoints("EURUSD", 3, 50, 5,
                                                        0.0001, 0.0001),
               3.0, 1e-9, "FX 3 pips on 4-digit → 3 points");
}
void Test_Slip_Gold()
{
   Print("[Test_Slip_Gold]");
   //  XAUUSD: 50 cents. point=0.01, pip=0.01 → 50 points exactly.
   AssertEqDbl((double)CPositionManager::SlippagePoints("XAUUSD", 3, 50, 5, 0.01, 0.01),
               50.0, 1e-9, "Gold 50 cents → 50 points");
}
void Test_Slip_Nas()
{
   Print("[Test_Slip_Nas]");
   AssertEqDbl((double)CPositionManager::SlippagePoints("NAS100", 3, 50, 5, 0.01, 0.01),
               5.0, 1e-9, "NAS100 5 points");
}

void OnStart()
{
   g_passed = 0; g_failed = 0;
   Test_PipValue_EURUSD_5digit();
   Test_PipValue_USDJPY_3digit();
   Test_PipValue_XAUUSD();
   Test_PipValue_NAS100();
   Test_PipValue_GuardZeroTickSize();
   Test_RiskPct_Position1();
   Test_RiskPct_Position2();
   Test_RiskPct_Position3();
   Test_RiskPct_OutOfRange();
   Test_LotSize_EURUSD_BasicCase();
   Test_LotSize_USDJPY_Case();
   Test_LotSize_XAUUSD_Case();
   Test_LotSize_GuardZeroPipValue();
   Test_LotSize_GuardZeroSL();
   Test_NormalizeLot_RoundDownToStep();
   Test_NormalizeLot_ClampToMin();
   Test_NormalizeLot_ClampToMax();
   Test_NormalizeLot_StepPoint1();
   Test_NormalizeLot_StepIntegerWhole();
   Test_SLFloor_AtrTermDominates();
   Test_SLFloor_StopsLevelTermDominates();
   Test_SLFloor_ZeroAtr_FallsBackToStopsLevel();
   Test_SLFloor_MultZeroDropsAtrTerm();
   Test_TP_BuyDefault2R_NoSR();
   Test_TP_BuySRClosedThan2R();
   Test_TP_BuySRBeyond5R_Default2R();
   Test_TP_BuySRBelowEntryIgnored();
   Test_TP_SellMirror();
   Test_TP_SellNoSR_Default2R();
   Test_Slip_FX_5digit();
   Test_Slip_FX_4digit();
   Test_Slip_Gold();
   Test_Slip_Nas();
   PrintFormat("===== Done. passed=%d failed=%d =====", g_passed, g_failed);
}
