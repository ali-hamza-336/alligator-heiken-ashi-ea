//+------------------------------------------------------------------+
//|  Test_SignalEngine.mq5                                           |
//|  Phase 3 unit tests for the pure entry-signal logic.             |
//|  Live wrappers (BuildContext, hedge helper) are integration-      |
//|  tested via the EA on attach.                                    |
//+------------------------------------------------------------------+
#property copyright "Phase 3 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\SignalEngine.mqh"

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
//| Bullish alignment: Lips>Teeth>Jaw with separation > mult*ATR.    |
//+------------------------------------------------------------------+
void Test_BullAligned_Separated()
{
   Print("[Test_BullAligned_Separated]");
   //  Lips=1.105 Teeth=1.103 Jaw=1.100, ATR=0.0010, mult=0.4 → threshold 0.0004
   //  separation = 1.105 - 1.100 = 0.005 > 0.0004 → aligned
   Assert(CSignalEngine::IsBullAligned(1.105, 1.103, 1.100, 0.0010, 0.4),
          "clean bull alignment with ample separation");
}

void Test_BullAligned_TooClose()
{
   Print("[Test_BullAligned_TooClose]");
   //  Lips=1.1003 Jaw=1.1000 → sep 0.0003 < threshold 0.0004 → rejected
   Assert(!CSignalEngine::IsBullAligned(1.1003, 1.1002, 1.1000, 0.0010, 0.4),
          "lines ordered but separation under threshold");
}

void Test_BullAligned_WrongOrder()
{
   Print("[Test_BullAligned_WrongOrder]");
   //  Lips < Teeth → not bull
   Assert(!CSignalEngine::IsBullAligned(1.100, 1.103, 1.105, 0.0010, 0.4),
          "Lips below Teeth is not bull alignment");
}

//+------------------------------------------------------------------+
//| Bearish alignment mirror.                                        |
//+------------------------------------------------------------------+
void Test_BearAligned_Mirror()
{
   Print("[Test_BearAligned_Mirror]");
   Assert(CSignalEngine::IsBearAligned(1.100, 1.103, 1.105, 0.0010, 0.4),
          "Lips<Teeth<Jaw with separation");
   Assert(!CSignalEngine::IsBearAligned(1.105, 1.103, 1.100, 0.0010, 0.4),
          "bull layout fails bear check");
}

//+------------------------------------------------------------------+
//| Tangled detection: pairwise within tol*ATR.                      |
//+------------------------------------------------------------------+
void Test_Tangled_Within()
{
   Print("[Test_Tangled_Within]");
   //  All three lines within 0.3 × ATR (= 0.0003) of each other
   Assert(CSignalEngine::IsTangled(1.1001, 1.1000, 1.0999, 0.0010, 0.3),
          "tight cluster is tangled");
}

void Test_Tangled_NotWhenSpread()
{
   Print("[Test_Tangled_NotWhenSpread]");
   //  Lips far above the others → not tangled
   Assert(!CSignalEngine::IsTangled(1.1010, 1.1000, 1.0999, 0.0010, 0.3),
          "spread layout is not tangled");
}

//+------------------------------------------------------------------+
//| 1H soft filter: opposite-direction open mouth blocks; tangled or |
//| same-direction is fine.                                          |
//+------------------------------------------------------------------+
void Test_H1Filter_AllowsBuyWhenH1Tangled()
{
   Print("[Test_H1Filter_AllowsBuyWhenH1Tangled]");
   //  All three within 0.3*ATR → not in opposite mouth → allow buy
   Assert(CSignalEngine::H1AllowsBuy(1.1001, 1.1000, 1.0999, 0.001, 0.4),
          "buy allowed under tangled 1H");
}

void Test_H1Filter_RejectsBuyWhenH1Bear()
{
   Print("[Test_H1Filter_RejectsBuyWhenH1Bear]");
   //  H1 lips<teeth<jaw with separation > 0.4*ATR → opposite mouth open → reject
   Assert(!CSignalEngine::H1AllowsBuy(1.100, 1.103, 1.110, 0.001, 0.4),
          "buy rejected when H1 in clean bear");
}

void Test_H1Filter_AllowsBuyWhenH1Bull()
{
   Print("[Test_H1Filter_AllowsBuyWhenH1Bull]");
   //  H1 lips>teeth>jaw → same direction → allow
   Assert(CSignalEngine::H1AllowsBuy(1.110, 1.103, 1.100, 0.001, 0.4),
          "buy allowed when H1 also bull");
}

void Test_H1Filter_SellMirror()
{
   Print("[Test_H1Filter_SellMirror]");
   Assert(CSignalEngine::H1AllowsSell(1.100, 1.103, 1.110, 0.001, 0.4),
          "sell allowed under H1 bear");
   Assert(!CSignalEngine::H1AllowsSell(1.110, 1.103, 1.100, 0.001, 0.4),
          "sell rejected when H1 in clean bull");
   Assert(CSignalEngine::H1AllowsSell(1.1001, 1.1000, 1.0999, 0.001, 0.4),
          "sell allowed under tangled H1");
}

//+------------------------------------------------------------------+
//| HA pattern helpers. Arrays size-2, idx 0 = older (shift 2).      |
//+------------------------------------------------------------------+
void Test_HABothGreen_True()
{
   Print("[Test_HABothGreen_True]");
   double o[2] = {100.0, 101.0};
   double c[2] = {101.0, 102.0};
   Assert(CSignalEngine::HABothGreen(o, c), "both bars closed > opened");
}

void Test_HABothGreen_FalseMixed()
{
   Print("[Test_HABothGreen_FalseMixed]");
   double o[2] = {101.0, 100.0};   // bar0 red
   double c[2] = {100.0, 101.0};
   Assert(!CSignalEngine::HABothGreen(o, c), "first bar red rejects");
}

void Test_HABothRed_Mirror()
{
   Print("[Test_HABothRed_Mirror]");
   double o[2] = {101.0, 102.0};
   double c[2] = {100.0, 101.0};
   Assert(CSignalEngine::HABothRed(o, c), "both red");
}

void Test_NewerNoLowerWick_True()
{
   Print("[Test_NewerNoLowerWick_True]");
   //  Newer bar (idx 1): open=101 close=102, low=101 → no lower wick
   double o[2] = {100, 101}, l[2] = {99, 101}, c[2] = {101, 102};
   Assert(CSignalEngine::NewerNoLowerWick(o, l, c, 0.0001),
          "newer bar low equals open ≈ no wick");
}

void Test_NewerNoLowerWick_WithinTol()
{
   Print("[Test_NewerNoLowerWick_WithinTol]");
   //  Wick of 0.00005 vs tol 0.0001 → still pass
   double o[2] = {100, 101}, l[2] = {99, 100.99995}, c[2] = {101, 102};
   Assert(CSignalEngine::NewerNoLowerWick(o, l, c, 0.0001),
          "wick within tolerance passes");
}

void Test_NewerNoLowerWick_TooDeep()
{
   Print("[Test_NewerNoLowerWick_TooDeep]");
   double o[2] = {100, 101}, l[2] = {99, 100.5}, c[2] = {101, 102};
   Assert(!CSignalEngine::NewerNoLowerWick(o, l, c, 0.0001),
          "0.5 wick exceeds tol");
}

void Test_NewerNoUpperWick_Mirror()
{
   Print("[Test_NewerNoUpperWick_Mirror]");
   //  Bear: newer bar open=101 close=100 high=101 → no upper wick
   double o[2] = {102, 101}, h[2] = {103, 101}, c[2] = {101, 100};
   Assert(CSignalEngine::NewerNoUpperWick(o, h, c, 0.0001),
          "newer bear bar high ≈ open");
}

//+------------------------------------------------------------------+
//| SL math. Type A: Jaw ± buf*ATR. Type B: low5/high5 ± buf*ATR.    |
//+------------------------------------------------------------------+
void Test_SLBuy_TypeA()
{
   Print("[Test_SLBuy_TypeA]");
   //  Jaw=1.100, ATR=0.001, buf=0.2 → SL = 1.100 - 0.0002 = 1.0998
   AssertEqDbl(CSignalEngine::SLForTypeABuy(1.100, 0.001, 0.2), 1.0998, 1e-9,
               "type A buy SL = jaw - 0.2*atr");
}

void Test_SLSell_TypeA()
{
   Print("[Test_SLSell_TypeA]");
   AssertEqDbl(CSignalEngine::SLForTypeASell(1.100, 0.001, 0.2), 1.1002, 1e-9,
               "type A sell SL = jaw + 0.2*atr");
}

void Test_SLBuy_TypeB()
{
   Print("[Test_SLBuy_TypeB]");
   double lows[5] = {1.0995, 1.0993, 1.0990, 1.0992, 1.0994};
   //  min = 1.0990, ATR=0.001, buf=0.2 → SL = 1.0988
   AssertEqDbl(CSignalEngine::SLForTypeBBuy(lows, 5, 0.001, 0.2), 1.0988, 1e-9,
               "type B buy SL = min(low5) - 0.2*atr");
}

void Test_SLSell_TypeB()
{
   Print("[Test_SLSell_TypeB]");
   double highs[5] = {1.1005, 1.1010, 1.1008, 1.1003, 1.1006};
   //  max = 1.1010, SL = 1.1010 + 0.0002 = 1.1012
   AssertEqDbl(CSignalEngine::SLForTypeBSell(highs, 5, 0.001, 0.2), 1.1012, 1e-9,
               "type B sell SL = max(high5) + 0.2*atr");
}

//+------------------------------------------------------------------+
//| DetectTypeA tests.                                               |
//+------------------------------------------------------------------+
SignalContext MakeCtxBullishTrigger()
{
   SignalContext c;
   //  curr = clean bull (Lips - Jaw = 0.007 > 0.0004)
   c.m15_jaw_curr = 1.100; c.m15_teeth_curr = 1.103; c.m15_lips_curr = 1.107;
   //  prev = tangled (so transition just happened)
   c.m15_jaw_prev = 1.1001; c.m15_teeth_prev = 1.1000; c.m15_lips_prev = 1.0999;
   //  H1 tangled → allow
   c.h1_jaw  = 1.1001; c.h1_teeth = 1.1000; c.h1_lips = 1.0999;
   c.atr = 0.0010;
   c.mouth_open_mult = 0.4; c.sl_buffer_mult = 0.2;
   c.tangle_tol_mult = 0.3; c.ha_wick_tol_price = 0.0001;
   //  ha + last5 unused for Type A but zero them so the struct is fully set
   for(int i = 0; i < 2; i++)
     { c.ha_o[i] = 0; c.ha_h[i] = 0; c.ha_l[i] = 0; c.ha_c[i] = 0; }
   for(int i = 0; i < 5; i++)
     { c.last5_high[i] = 0; c.last5_low[i] = 0; }
   return c;
}

void Test_DetectA_CleanBuy()
{
   Print("[Test_DetectA_CleanBuy]");
   SignalContext c = MakeCtxBullishTrigger();
   SignalResult r;
   const bool got = CSignalEngine::DetectTypeA(c, r);
   Assert(got, "DetectTypeA returns true on clean buy trigger");
   AssertEqInt(r.kind, SIGNAL_TYPE_A_BUY, "kind = A_BUY");
   AssertEqDbl(r.sl_price, 1.100 - 0.0002, 1e-9, "SL = jaw - 0.2*atr");
}

void Test_DetectA_NoTriggerWhenAlreadyOpen()
{
   Print("[Test_DetectA_NoTriggerWhenAlreadyOpen]");
   SignalContext c = MakeCtxBullishTrigger();
   //  Prev bar ALSO bull-aligned (Lips-Jaw = 0.007) → mouth was already open
   c.m15_jaw_prev = 1.099; c.m15_teeth_prev = 1.102; c.m15_lips_prev = 1.106;
   SignalResult r;
   Assert(!CSignalEngine::DetectTypeA(c, r), "no signal when prev bar already aligned");
}

void Test_DetectA_NoTriggerSeparationSmall()
{
   Print("[Test_DetectA_NoTriggerSeparationSmall]");
   SignalContext c = MakeCtxBullishTrigger();
   //  Curr lines too tight: lips - jaw = 0.0003 < 0.4 * 0.001
   c.m15_jaw_curr = 1.1000; c.m15_teeth_curr = 1.1001; c.m15_lips_curr = 1.1003;
   SignalResult r;
   Assert(!CSignalEngine::DetectTypeA(c, r), "rejected on insufficient separation");
}

void Test_DetectA_RejectedByH1OppositeMouth()
{
   Print("[Test_DetectA_RejectedByH1OppositeMouth]");
   SignalContext c = MakeCtxBullishTrigger();
   //  H1 in clean bear with separation
   c.h1_lips = 1.090; c.h1_teeth = 1.095; c.h1_jaw = 1.100;
   SignalResult r;
   Assert(!CSignalEngine::DetectTypeA(c, r), "rejected by 1H bear");
}

void Test_DetectA_CleanSell()
{
   Print("[Test_DetectA_CleanSell]");
   SignalContext c;
   //  curr = clean bear (Jaw - Lips = 0.007)
   c.m15_jaw_curr = 1.107; c.m15_teeth_curr = 1.103; c.m15_lips_curr = 1.100;
   //  prev = tangled
   c.m15_jaw_prev = 1.1001; c.m15_teeth_prev = 1.1000; c.m15_lips_prev = 1.0999;
   c.h1_jaw  = 1.1001; c.h1_teeth = 1.1000; c.h1_lips = 1.0999;
   c.atr = 0.0010;
   c.mouth_open_mult = 0.4; c.sl_buffer_mult = 0.2;
   c.tangle_tol_mult = 0.3; c.ha_wick_tol_price = 0.0001;
   for(int i = 0; i < 2; i++)
     { c.ha_o[i] = 0; c.ha_h[i] = 0; c.ha_l[i] = 0; c.ha_c[i] = 0; }
   for(int i = 0; i < 5; i++)
     { c.last5_high[i] = 0; c.last5_low[i] = 0; }
   SignalResult r;
   Assert(CSignalEngine::DetectTypeA(c, r), "clean sell trigger");
   AssertEqInt(r.kind, SIGNAL_TYPE_A_SELL, "kind = A_SELL");
   AssertEqDbl(r.sl_price, 1.107 + 0.0002, 1e-9, "SL = jaw + 0.2*atr");
}

//+------------------------------------------------------------------+
//| DetectTypeB tests.                                                |
//+------------------------------------------------------------------+
SignalContext MakeCtxTypeBBuy()
{
   SignalContext c;
   //  Tangled M15: all three within 0.3*ATR (tol = 0.0003)
   c.m15_jaw_curr = 1.0999; c.m15_teeth_curr = 1.1000; c.m15_lips_curr = 1.1001;
   c.m15_jaw_prev = 1.0999; c.m15_teeth_prev = 1.1000; c.m15_lips_prev = 1.1001;
   //  H1 tangled → allow
   c.h1_jaw  = 1.1001; c.h1_teeth = 1.1000; c.h1_lips = 1.0999;
   c.atr = 0.0010;
   c.mouth_open_mult = 0.4; c.sl_buffer_mult = 0.2;
   c.tangle_tol_mult = 0.3; c.ha_wick_tol_price = 0.0001;
   //  HA: both green, newer with no lower wick, both closes above max_line=1.1001
   c.ha_o[0] = 1.1010; c.ha_h[0] = 1.1015; c.ha_l[0] = 1.1009; c.ha_c[0] = 1.1014;
   c.ha_o[1] = 1.1014; c.ha_h[1] = 1.1020; c.ha_l[1] = 1.1014; c.ha_c[1] = 1.1019;
   //  last5 for SL (min low = 1.1007)
   c.last5_low[0]  = 1.1009; c.last5_low[1]  = 1.1008; c.last5_low[2]  = 1.1007;
   c.last5_low[3]  = 1.1010; c.last5_low[4]  = 1.1011;
   //  last5 high (max = 1.1020)
   c.last5_high[0] = 1.1020; c.last5_high[1] = 1.1018; c.last5_high[2] = 1.1019;
   c.last5_high[3] = 1.1017; c.last5_high[4] = 1.1019;
   return c;
}

void Test_DetectB_CleanBuy()
{
   Print("[Test_DetectB_CleanBuy]");
   SignalContext c = MakeCtxTypeBBuy();
   SignalResult r;
   Assert(CSignalEngine::DetectTypeB(c, r), "type B buy fires");
   AssertEqInt(r.kind, SIGNAL_TYPE_B_BUY, "kind = B_BUY");
   //  SL = min(last5_low) - 0.0002 = 1.1007 - 0.0002 = 1.1005
   AssertEqDbl(r.sl_price, 1.1005, 1e-9, "SL = lowest5 - 0.2*atr");
}

void Test_DetectB_NoTriggerWhenAligned()
{
   Print("[Test_DetectB_NoTriggerWhenAligned]");
   SignalContext c = MakeCtxTypeBBuy();
   //  Make M15 fully bull aligned (not tangled)
   c.m15_jaw_curr = 1.0995; c.m15_teeth_curr = 1.1000; c.m15_lips_curr = 1.1010;
   SignalResult r;
   Assert(!CSignalEngine::DetectTypeB(c, r), "rejected when M15 not tangled");
}

void Test_DetectB_NoTriggerWickTooLong()
{
   Print("[Test_DetectB_NoTriggerWickTooLong]");
   SignalContext c = MakeCtxTypeBBuy();
   //  Newer body_low = 1.1014; set low to 1.1010 → wick = 0.0004 > tol 0.0001
   c.ha_l[1] = 1.1010;
   SignalResult r;
   Assert(!CSignalEngine::DetectTypeB(c, r), "rejected on too-deep lower wick");
}

void Test_DetectB_NoTriggerOlderBelowLines()
{
   Print("[Test_DetectB_NoTriggerOlderBelowLines]");
   SignalContext c = MakeCtxTypeBBuy();
   //  Push older HA close below max_line = 1.1001
   c.ha_o[0] = 1.0995; c.ha_c[0] = 1.0999;
   SignalResult r;
   Assert(!CSignalEngine::DetectTypeB(c, r), "rejected when older HA close not above lines");
}

void Test_DetectB_CleanSell()
{
   Print("[Test_DetectB_CleanSell]");
   SignalContext c = MakeCtxTypeBBuy();
   //  Flip HA for SELL: both red, both closes below min_line = 1.0999
   c.ha_o[0] = 1.0990; c.ha_h[0] = 1.0991; c.ha_l[0] = 1.0985; c.ha_c[0] = 1.0986;
   //  newer body_high = max(o,c) = 1.0986; high = 1.0986 → no upper wick
   c.ha_o[1] = 1.0986; c.ha_h[1] = 1.0986; c.ha_l[1] = 1.0980; c.ha_c[1] = 1.0981;
   SignalResult r;
   Assert(CSignalEngine::DetectTypeB(c, r), "type B sell fires");
   AssertEqInt(r.kind, SIGNAL_TYPE_B_SELL, "kind = B_SELL");
   //  SL = max(last5_high) + 0.2*atr = 1.1020 + 0.0002 = 1.1022
   AssertEqDbl(r.sl_price, 1.1022, 1e-9, "SL = highest5 + 0.2*atr");
}

//+------------------------------------------------------------------+
void OnStart()
{
   Print("===== Test_SignalEngine =====");

   Test_BullAligned_Separated();
   Test_BullAligned_TooClose();
   Test_BullAligned_WrongOrder();
   Test_BearAligned_Mirror();
   Test_Tangled_Within();
   Test_Tangled_NotWhenSpread();

   Test_H1Filter_AllowsBuyWhenH1Tangled();
   Test_H1Filter_RejectsBuyWhenH1Bear();
   Test_H1Filter_AllowsBuyWhenH1Bull();
   Test_H1Filter_SellMirror();

   Test_HABothGreen_True();
   Test_HABothGreen_FalseMixed();
   Test_HABothRed_Mirror();
   Test_NewerNoLowerWick_True();
   Test_NewerNoLowerWick_WithinTol();
   Test_NewerNoLowerWick_TooDeep();
   Test_NewerNoUpperWick_Mirror();

   Test_SLBuy_TypeA();
   Test_SLSell_TypeA();
   Test_SLBuy_TypeB();
   Test_SLSell_TypeB();

   Test_DetectA_CleanBuy();
   Test_DetectA_NoTriggerWhenAlreadyOpen();
   Test_DetectA_NoTriggerSeparationSmall();
   Test_DetectA_RejectedByH1OppositeMouth();
   Test_DetectA_CleanSell();

   Test_DetectB_CleanBuy();
   Test_DetectB_NoTriggerWhenAligned();
   Test_DetectB_NoTriggerWickTooLong();
   Test_DetectB_NoTriggerOlderBelowLines();
   Test_DetectB_CleanSell();

   PrintFormat("===== Done. passed=%d failed=%d =====", g_passed, g_failed);
}
//+------------------------------------------------------------------+
