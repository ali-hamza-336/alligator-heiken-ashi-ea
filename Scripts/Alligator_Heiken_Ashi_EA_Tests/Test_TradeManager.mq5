//+------------------------------------------------------------------+
//|  Test_TradeManager.mq5                                           |
//|  Phase 5 unit tests for BE / trail / Lips-break math + Decide(). |
//|  Phase 8: + Lips-break softening (ATR buffer / confirm bars /    |
//|  min-hold bars). Defaults are the spec no-op.                    |
//|  Path A Stage 2 Task C: Decide rewrite — MA_PARTIAL_AND_BE +     |
//|  trail-delay gate; TightenLipsPrice helper.                      |
//|  Approach C revert (2026-05-15): MA_TIGHTEN_SL_LIPS replaced by  |
//|  MA_CLOSE_LIPS in Decide; TightenLipsPrice helper kept (dormant).|
//+------------------------------------------------------------------+
#property copyright "Path A Stage 2 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\TradeManager.mqh"

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
// CalcBETrigger
//==================================================================
void Test_BETrigger_Buy()
{
   Print("[Test_BETrigger_Buy]");
   //  BUY entry=1.1000 SL=1.0950 → R=0.0050; trigger at +1R = 1.1050
   AssertEqDbl(CTradeManager::CalcBETrigger(true, 1.1000, 1.0950, 1.0),
               1.1050, 1e-9, "BUY +1R trigger");
}
void Test_BETrigger_Sell()
{
   Print("[Test_BETrigger_Sell]");
   //  SELL entry=1.1000 SL=1.1050 → R=0.0050; trigger at -1R = 1.0950
   AssertEqDbl(CTradeManager::CalcBETrigger(false, 1.1000, 1.1050, 1.0),
               1.0950, 1e-9, "SELL +1R trigger");
}
void Test_BETrigger_FractionalR()
{
   Print("[Test_BETrigger_FractionalR]");
   //  BUY entry=2000 SL=1990 → R=10; trigger at +0.8R = 2008
   AssertEqDbl(CTradeManager::CalcBETrigger(true, 2000.0, 1990.0, 0.8),
               2008.0, 1e-9, "BUY +0.8R");
}

//==================================================================
// CalcBESL
//==================================================================
void Test_BESL_Buy_5digit()
{
   Print("[Test_BESL_Buy_5digit]");
   //  BUY entry=1.1000 buffer=2 pips on pip=0.0001 → 1.10020
   AssertEqDbl(CTradeManager::CalcBESL(true, 1.1000, 2.0, 0.0001),
               1.10020, 1e-9, "BUY BE+2pip 5-digit");
}
void Test_BESL_Sell_5digit()
{
   Print("[Test_BESL_Sell_5digit]");
   AssertEqDbl(CTradeManager::CalcBESL(false, 1.1000, 2.0, 0.0001),
               1.09980, 1e-9, "SELL BE-2pip 5-digit");
}
void Test_BESL_Gold()
{
   Print("[Test_BESL_Gold]");
   //  BUY entry=2000 buffer=2 cents on pip=0.01 → 2000.02
   AssertEqDbl(CTradeManager::CalcBESL(true, 2000.0, 2.0, 0.01),
               2000.02, 1e-9, "BUY BE+2c gold");
}

//==================================================================
// CalcTrailSL
//==================================================================
void Test_TrailSL_Buy()
{
   Print("[Test_TrailSL_Buy]");
   //  BUY: lips=1.1050 ATR=0.0010 buffer=0.3 → 1.1050 - 0.0003 = 1.1047
   AssertEqDbl(CTradeManager::CalcTrailSL(true, 1.1050, 0.0010, 0.3),
               1.1047, 1e-9, "BUY trail = lips - 0.3*ATR");
}
void Test_TrailSL_Sell()
{
   Print("[Test_TrailSL_Sell]");
   AssertEqDbl(CTradeManager::CalcTrailSL(false, 1.1050, 0.0010, 0.3),
               1.1053, 1e-9, "SELL trail = lips + 0.3*ATR");
}

//==================================================================
// IsImprovement (never move SL backward — invariant #7)
//==================================================================
void Test_IsImprovement_Buy()
{
   Print("[Test_IsImprovement_Buy]");
   Assert( CTradeManager::IsImprovement(true,  1.1050, 1.1040), "BUY new>current -> improve");
   Assert(!CTradeManager::IsImprovement(true,  1.1030, 1.1040), "BUY new<current -> reject");
   Assert(!CTradeManager::IsImprovement(true,  1.1040, 1.1040), "BUY equal -> reject (no-op)");
}
void Test_IsImprovement_Sell()
{
   Print("[Test_IsImprovement_Sell]");
   Assert( CTradeManager::IsImprovement(false, 1.1040, 1.1050), "SELL new<current -> improve");
   Assert(!CTradeManager::IsImprovement(false, 1.1060, 1.1050), "SELL new>current -> reject");
   Assert(!CTradeManager::IsImprovement(false, 1.1050, 1.1050), "SELL equal -> reject (no-op)");
}
void Test_IsImprovement_NoCurrentSL()
{
   Print("[Test_IsImprovement_NoCurrentSL]");
   //  current_sl == 0 means "no SL set". Treat any positive new_sl as improvement.
   Assert( CTradeManager::IsImprovement(true,  1.1040, 0.0), "BUY any vs no-SL -> improve");
   Assert( CTradeManager::IsImprovement(false, 1.1040, 0.0), "SELL any vs no-SL -> improve");
}

//==================================================================
// IsBeyondLips (Lips break — spec §3.4 first bullet)
//==================================================================
void Test_IsBeyondLips_BuyBreak()
{
   Print("[Test_IsBeyondLips_BuyBreak]");
   //  BUY: close BELOW lips → break
   Assert( CTradeManager::IsBeyondLips(true,  1.1040, 1.1050), "BUY close<lips -> break");
   Assert(!CTradeManager::IsBeyondLips(true,  1.1060, 1.1050), "BUY close>lips -> no");
   Assert(!CTradeManager::IsBeyondLips(true,  1.1050, 1.1050), "BUY close==lips -> no");
}
void Test_IsBeyondLips_SellBreak()
{
   Print("[Test_IsBeyondLips_SellBreak]");
   Assert( CTradeManager::IsBeyondLips(false, 1.1060, 1.1050), "SELL close>lips -> break");
   Assert(!CTradeManager::IsBeyondLips(false, 1.1040, 1.1050), "SELL close<lips -> no");
}
void Test_IsBeyondLips_Buffered()
{
   Print("[Test_IsBeyondLips_Buffered]");
   //  Phase 8: with a 1-pip buffer, a 0.5-pip poke is not a break; a 2-pip move is.
   Assert(!CTradeManager::IsBeyondLips(true,  1.10495, 1.1050, 0.0001), "BUY 0.5pip below, buf=1pip -> no break");
   Assert( CTradeManager::IsBeyondLips(true,  1.10480, 1.1050, 0.0001), "BUY 2pip below,   buf=1pip -> break");
   Assert(!CTradeManager::IsBeyondLips(false, 1.10505, 1.1050, 0.0001), "SELL 0.5pip above, buf=1pip -> no break");
   Assert( CTradeManager::IsBeyondLips(false, 1.10520, 1.1050, 0.0001), "SELL 2pip above,   buf=1pip -> break");
   //  default buffer arg (0) reproduces the exact spec test
   Assert( CTradeManager::IsBeyondLips(true,  1.1040, 1.1050), "BUY close<lips, default buf=0 -> break");
}

//==================================================================
// TightenLipsPrice (Stage 2 Approach C)
//==================================================================
void Test_TightenLipsPrice_Buy()
{
   Print("[Test_TightenLipsPrice_Buy]");
   //  BUY: lips=1.1050 ATR=0.001 buf=0.5 entry=1.1100 → 1.1050-0.0005=1.1045. Below entry, no clamp.
   AssertEqDbl(CTradeManager::TightenLipsPrice(true, 1.1050, 0.001, 0.5, 1.1100),
               1.1045, 1e-9, "BUY tighten = lips - 0.5*ATR (below entry, no clamp)");
}
void Test_TightenLipsPrice_Sell()
{
   Print("[Test_TightenLipsPrice_Sell]");
   //  SELL: lips=1.0950 ATR=0.001 buf=0.5 entry=1.0900 → 1.0950+0.0005=1.0955. Above entry, no clamp.
   AssertEqDbl(CTradeManager::TightenLipsPrice(false, 1.0950, 0.001, 0.5, 1.0900),
               1.0955, 1e-9, "SELL tighten = lips + 0.5*ATR (above entry, no clamp)");
}
void Test_TightenLipsPrice_ClampToEntry_Buy()
{
   Print("[Test_TightenLipsPrice_ClampToEntry_Buy]");
   //  BUY: lips very close to entry → raw above entry → clamp to entry (SL stays on loss side).
   //  lips=1.1080 ATR=0.0001 buf=0.3 entry=1.1075 → raw=1.1080-0.00003=1.10797 > entry=1.1075 → 1.1075
   AssertEqDbl(CTradeManager::TightenLipsPrice(true, 1.1080, 0.0001, 0.3, 1.1075),
               1.1075, 1e-9, "BUY raw>entry -> clamp to entry");
}
void Test_TightenLipsPrice_ClampToEntry_Sell()
{
   Print("[Test_TightenLipsPrice_ClampToEntry_Sell]");
   //  SELL: lips just below entry → raw below entry → clamp to entry.
   //  lips=1.0920 ATR=0.0001 buf=0.3 entry=1.0925 → raw=1.0920+0.00003=1.09203 < entry=1.0925 → 1.0925
   AssertEqDbl(CTradeManager::TightenLipsPrice(false, 1.0920, 0.0001, 0.3, 1.0925),
               1.0925, 1e-9, "SELL raw<entry -> clamp to entry");
}

//==================================================================
// Decide — composition. Post-revert priority order (top-to-bottom):
//   1. NY-open carryover   → MA_CLOSE_NYOPEN
//   2. Friday close        → MA_CLOSE_FRIDAY
//   3. Zero-close guard    → MA_NONE (invariant #10)
//   4. PartialAndBE (pre)  → MA_PARTIAL_AND_BE  (when !partial_done & at +trigger_R;
//                                                 dormant at Trigger_R=3.0 default)
//   5. Lips break (pre)    → MA_CLOSE_LIPS      (when !partial_done & Lips break;
//                                                 Stage 1.1 restored 2026-05-15)
//   6. Trail (post-BE)     → MA_TRAIL           (when partial_done & delay elapsed & improves)
//   7. otherwise           → MA_NONE
//==================================================================
ManageContext MakeCtx_BuyHealthy(const double entry, const double sl,
                                  const double close_s1, const double lips,
                                  const double atr)
{
   ManageContext c;
   ZeroMemory(c);                         // new Phase-8 fields -> spec no-op
   c.is_buy = true;
   c.entry = entry;
   c.current_sl = sl;
   c.close_m15_s1 = close_s1;
   c.lips_m15_s1 = lips;
   c.atr_m15_s1 = atr;
   c.pip = 0.0001;
   c.be_trigger_R = 1.0;
   c.be_buffer_pips = 2.0;
   c.trail_atr_buffer = 0.3;
   c.is_friday_close_time = false;
   c.is_ny_open_carryover = false;
   //  Phase-8 Lips-break softening — explicit spec no-op values (also what
   //  ZeroMemory leaves, listed here for clarity):
   c.lips_break_atr_buffer   = 0.0;
   c.lips_break_confirm_bars  = 1;
   c.lips_break_min_hold_bars = 0;
   c.bars_since_entry         = 99;       // well past any min-hold
   c.close_m15_s2 = 0.0; c.lips_m15_s2 = 0.0;
   c.close_m15_s3 = 0.0; c.lips_m15_s3 = 0.0;
   //  Stage 2 fields. Defaults keep the test surface clean:
   //   - partial_done=false   -> pre-BE phase (PartialAndBE + TightenSLLips eligible)
   //   - trail_delay_bars=0   -> no trail delay (matches pre-Stage-2 behaviour when partial_done is set)
   //   - bars_since_BE_move=99-> well past any delay
   //   - entry_R_distance     -> snapshot of initial R (|entry - original_sl|)
   c.partial_done             = false;
   c.partial_close_trigger_R  = 1.0;
   c.trail_delay_bars         = 0;
   c.bars_since_BE_move       = 99;
   c.entry_R_distance         = MathAbs(entry - sl);
   return c;
}
void Test_Decide_NYOpenCarryover_WinsAll()
{
   Print("[Test_Decide_NYOpenCarryover_WinsAll]");
   ManageContext c = MakeCtx_BuyHealthy(1.10, 1.095, 1.105, 1.106, 0.001);
   c.is_ny_open_carryover = true;
   c.is_friday_close_time = true;        // both true — NY-open wins
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_CLOSE_NYOPEN, "NY-open beats Friday + everything");
}
void Test_Decide_FridayClose()
{
   Print("[Test_Decide_FridayClose]");
   ManageContext c = MakeCtx_BuyHealthy(1.10, 1.095, 1.105, 1.106, 0.001);
   c.is_friday_close_time = true;
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_CLOSE_FRIDAY, "Friday close beats trail/BE");
}
void Test_Decide_LipsBreak_Buy()
{
   Print("[Test_Decide_LipsBreak_Buy]");
   //  Post-revert: BUY, !partial_done, close below lips, close < +1R → MA_CLOSE_LIPS (market close).
   //  entry=1.1000 SL=1.0950 R=0.005; close=1.1040 (+0.8R, below +1R trigger).
   //  lips=1.1050 (close below → Lips break). Phase-8 softening defaults (buf=0, confirm=1) pass.
   //  MA_CLOSE_LIPS doesn't modify SL; d.new_sl = 0.0 (sentinel: unused by close-at-market dispatch).
   ManageContext c = MakeCtx_BuyHealthy(1.1000, 1.0950, /*close*/1.1040, /*lips*/1.1050, 0.001);
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_CLOSE_LIPS, "BUY close<lips, pre-BE -> MA_CLOSE_LIPS");
   AssertEqDbl(d.new_sl, 0.0, 1e-9, "MA_CLOSE_LIPS leaves new_sl at sentinel 0.0");
}
void Test_Decide_CloseLips_Sell()
{
   Print("[Test_Decide_CloseLips_Sell]");
   //  Post-revert SELL mirror of Test_Decide_LipsBreak_Buy — closes BUY/SELL symmetry gap.
   //  SELL entry=1.1000 SL=1.1050 (R=0.005, SL above entry). close=1.0960 (-0.4R below entry
   //  = +0.8R profit for SELL, below +1R trigger=1.0950 → no PartialAndBE).
   //  close 1.0960 > lips 1.0950 → SELL Lips break (price moved against SELL).
   //  Post-revert: action is MA_CLOSE_LIPS (market close at current price), not SL tighten.
   ManageContext c = MakeCtx_BuyHealthy(1.1000, 1.1050, /*close*/1.0960, /*lips*/1.0950, 0.001);
   c.is_buy = false;
   c.entry_R_distance = MathAbs(1.1000 - 1.1050);   // re-snapshot for SELL-side R
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_CLOSE_LIPS, "SELL close>lips, pre-BE -> MA_CLOSE_LIPS");
   AssertEqDbl(d.new_sl, 0.0, 1e-9, "MA_CLOSE_LIPS leaves new_sl at sentinel 0.0");
}
void Test_Decide_TrailWhenBEDone()
{
   Print("[Test_Decide_TrailWhenBEDone]");
   //  Stage 2: partial_done=true -> post-BE.
   //  lips=1.1080, ATR=0.001, buffer=0.3 → trail target = 1.1077; > current SL → improvement.
   //  close ABOVE lips so no Lips-break (also moot post-BE).
   ManageContext c = MakeCtx_BuyHealthy(1.1000, 1.1002, /*close*/1.1090, /*lips*/1.1080, 0.001);
   c.partial_done       = true;
   c.bars_since_BE_move = 99;     // delay elapsed
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_TRAIL, "BE done & trail improves -> MA_TRAIL");
   AssertEqDbl(d.new_sl, 1.1077, 1e-9, "trail SL = lips - 0.3*ATR");
}
void Test_Decide_TrailNoImprovement()
{
   Print("[Test_Decide_TrailNoImprovement]");
   //  Stage 2: post-BE, trail target (1.1077) < current (1.1080) → no improvement.
   ManageContext c = MakeCtx_BuyHealthy(1.1000, 1.1080, /*close*/1.1090, /*lips*/1.1080, 0.001);
   c.partial_done       = true;
   c.bars_since_BE_move = 99;
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_NONE, "trail not improving -> no-op");
}
void Test_Decide_PartialAndBE_Buy()
{
   Print("[Test_Decide_PartialAndBE_Buy]");
   //  Stage 2 (was Test_Decide_BEMove_Buy): BUY entry=1.10 SL=1.095 R=0.005, close=1.106 → +1.2R.
   //  !partial_done → MA_PARTIAL_AND_BE. lips=1.1055 (close above lips, no Lips break anyway).
   ManageContext c = MakeCtx_BuyHealthy(1.1000, 1.0950, /*close*/1.1060, /*lips*/1.1055, 0.001);
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_PARTIAL_AND_BE, "BUY +1R reached, !partial_done -> MA_PARTIAL_AND_BE");
   AssertEqDbl(d.new_sl, 1.10020, 1e-9, "BE SL = entry + 2 pip buffer");
}
void Test_Decide_BENotYetTriggered()
{
   Print("[Test_Decide_BENotYetTriggered]");
   //  BUY entry=1.10 SL=1.095 (R=0.005). close=1.1040 = +0.8R, below trigger. lips=1.1030 (close above → no break).
   ManageContext c = MakeCtx_BuyHealthy(1.1000, 1.0950, /*close*/1.1040, /*lips*/1.1030, 0.001);
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_NONE, "below trigger & no lips break -> no-op");
}
void Test_Decide_PartialAndBE_Sell()
{
   Print("[Test_Decide_PartialAndBE_Sell]");
   //  Stage 2 (was Test_Decide_BEMove_Sell): SELL entry=1.10 SL=1.105 R=0.005, close=1.094 → +1.2R.
   ManageContext c = MakeCtx_BuyHealthy(1.1000, 1.1050, /*close*/1.0940, /*lips*/1.0945, 0.001);
   c.is_buy = false;
   c.entry_R_distance = MathAbs(1.1000 - 1.1050);  // re-snapshot for the sell-side R
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_PARTIAL_AND_BE, "SELL +1R reached, !partial_done -> MA_PARTIAL_AND_BE");
   AssertEqDbl(d.new_sl, 1.09980, 1e-9, "SELL BE SL = entry - 2 pip buffer");
}

//==================================================================
// Decide — Phase 8 Lips-break softening (post-revert: now gates MA_CLOSE_LIPS)
//==================================================================
void Test_Decide_LipsBreak_AtrBuffer()
{
   Print("[Test_Decide_LipsBreak_AtrBuffer]");
   //  BUY, close 10 pip below lips, ATR=0.001. !partial_done.
   //  buffer mult=0.1 → lb_buf=0.0001 → close still well past → MA_CLOSE_LIPS.
   ManageContext c1 = MakeCtx_BuyHealthy(1.1000, 1.0950, /*close*/1.10400, /*lips*/1.10500, 0.001);
   c1.lips_break_atr_buffer = 0.1;
   Assert(CTradeManager::Decide(c1).action == MA_CLOSE_LIPS, "buf mult=0.1 (lb_buf=1pip) -> MA_CLOSE_LIPS");
   //  buffer mult=1.5 → lb_buf=0.0015 > (lips-close=0.001) → not a break.
   //  close 1.104 < +1R trigger 1.105 → no PartialAndBE; → MA_NONE.
   ManageContext c2 = MakeCtx_BuyHealthy(1.1000, 1.0950, /*close*/1.10400, /*lips*/1.10500, 0.001);
   c2.lips_break_atr_buffer = 1.5;
   Assert(CTradeManager::Decide(c2).action == MA_NONE, "buf mult=1.5 (lb_buf=15pip) -> Lips break suppressed -> MA_NONE");
}
void Test_Decide_LipsBreak_ConfirmBars()
{
   Print("[Test_Decide_LipsBreak_ConfirmBars]");
   //  confirm=2: s1 is beyond lips but s2 is not -> not a break -> MA_NONE (no PartialAndBE trigger either).
   ManageContext c1 = MakeCtx_BuyHealthy(1.1000, 1.0950, /*close s1*/1.10400, /*lips s1*/1.10500, 0.001);
   c1.lips_break_confirm_bars = 2;
   c1.close_m15_s2 = 1.10550; c1.lips_m15_s2 = 1.10500;   // s2 above lips -> not beyond
   Assert(CTradeManager::Decide(c1).action != MA_CLOSE_LIPS, "confirm=2, s2 not beyond -> not MA_CLOSE_LIPS");
   //  confirm=2: both s1 and s2 beyond lips -> break -> MA_CLOSE_LIPS.
   ManageContext c2 = MakeCtx_BuyHealthy(1.1000, 1.0950, /*close s1*/1.10400, /*lips s1*/1.10500, 0.001);
   c2.lips_break_confirm_bars = 2;
   c2.close_m15_s2 = 1.10450; c2.lips_m15_s2 = 1.10500;   // s2 below lips -> beyond
   Assert(CTradeManager::Decide(c2).action == MA_CLOSE_LIPS, "confirm=2, both bars beyond -> MA_CLOSE_LIPS");
   //  confirm=3: s1 & s2 beyond but s3 not -> not a break.
   ManageContext c3 = MakeCtx_BuyHealthy(1.1000, 1.0950, /*close s1*/1.10400, /*lips s1*/1.10500, 0.001);
   c3.lips_break_confirm_bars = 3;
   c3.close_m15_s2 = 1.10450; c3.lips_m15_s2 = 1.10500;
   c3.close_m15_s3 = 1.10600; c3.lips_m15_s3 = 1.10500;   // s3 above lips
   Assert(CTradeManager::Decide(c3).action != MA_CLOSE_LIPS, "confirm=3, s3 not beyond -> not MA_CLOSE_LIPS");
}
void Test_Decide_LipsBreak_MinHold()
{
   Print("[Test_Decide_LipsBreak_MinHold]");
   //  min_hold=4: bars_since_entry=2 -> Lips exit suppressed. close 1.104 < +1R trigger 1.105 -> MA_NONE.
   ManageContext c1 = MakeCtx_BuyHealthy(1.1000, 1.0950, /*close*/1.10400, /*lips*/1.10500, 0.001);
   c1.lips_break_min_hold_bars = 4; c1.bars_since_entry = 2;
   Assert(CTradeManager::Decide(c1).action == MA_NONE, "min_hold=4, bars=2 -> Lips exit suppressed -> MA_NONE");
   //  bars_since_entry=5 -> hold elapsed -> MA_CLOSE_LIPS.
   ManageContext c2 = MakeCtx_BuyHealthy(1.1000, 1.0950, /*close*/1.10400, /*lips*/1.10500, 0.001);
   c2.lips_break_min_hold_bars = 4; c2.bars_since_entry = 5;
   Assert(CTradeManager::Decide(c2).action == MA_CLOSE_LIPS, "min_hold=4, bars=5 -> MA_CLOSE_LIPS");
   //  min_hold does NOT suppress higher-priority time exits (Friday).
   ManageContext c3 = MakeCtx_BuyHealthy(1.1000, 1.0950, /*close*/1.10400, /*lips*/1.10500, 0.001);
   c3.lips_break_min_hold_bars = 999; c3.bars_since_entry = 0; c3.is_friday_close_time = true;
   Assert(CTradeManager::Decide(c3).action == MA_CLOSE_FRIDAY, "min_hold huge but Friday close still fires");
}

//==================================================================
// Decide — Stage 2 new tests
//==================================================================
void Test_Decide_PartialAndBE_OnceOnly()
{
   Print("[Test_Decide_PartialAndBE_OnceOnly]");
   //  Already partialed: partial_done=true. Even at +1R, must NOT fire MA_PARTIAL_AND_BE again.
   //  bars_since_BE_move=0, trail_delay_bars=2 → trail also suppressed → MA_NONE.
   ManageContext c = MakeCtx_BuyHealthy(1.1000, 1.10020, /*close*/1.1060, /*lips*/1.1055, 0.001);
   c.partial_done       = true;
   c.bars_since_BE_move = 0;
   c.trail_delay_bars   = 2;
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_NONE, "partial_done=true & trail-delay not elapsed -> MA_NONE (no double partial)");
}
void Test_Decide_PartialAndBE_BeatsCloseLips()
{
   Print("[Test_Decide_PartialAndBE_BeatsCloseLips]");
   //  BUY entry=1.10 R=0.005 (entry_R_distance). close=1.1051 → just above +1R trigger 1.1050.
   //  ALSO close (1.1051) < lips (1.1055) → Lips break fires too.
   //  Priority: PartialAndBE wins over MA_CLOSE_LIPS.
   ManageContext c = MakeCtx_BuyHealthy(1.1000, 1.0950, /*close*/1.10510, /*lips*/1.10550, 0.001);
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_PARTIAL_AND_BE, "+1R AND Lips break: PartialAndBE wins");
}
void Test_Decide_TrailDelay_Suppressed()
{
   Print("[Test_Decide_TrailDelay_Suppressed]");
   //  partial_done=true, bars_since_BE_move=0, trail_delay_bars=2 → suppressed.
   ManageContext c = MakeCtx_BuyHealthy(1.1000, 1.1002, /*close*/1.1090, /*lips*/1.1080, 0.001);
   c.partial_done       = true;
   c.bars_since_BE_move = 0;
   c.trail_delay_bars   = 2;
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_NONE, "trail-delay not elapsed -> MA_NONE");
}
void Test_Decide_TrailDelay_Elapsed()
{
   Print("[Test_Decide_TrailDelay_Elapsed]");
   //  partial_done=true, bars_since_BE_move=3, trail_delay_bars=2 → delay elapsed → MA_TRAIL.
   ManageContext c = MakeCtx_BuyHealthy(1.1000, 1.1002, /*close*/1.1090, /*lips*/1.1080, 0.001);
   c.partial_done       = true;
   c.bars_since_BE_move = 3;
   c.trail_delay_bars   = 2;
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_TRAIL, "delay elapsed -> MA_TRAIL");
   AssertEqDbl(d.new_sl, 1.1077, 1e-9, "trail SL = lips - 0.3*ATR");
}
void Test_Decide_NoLipsBreakPostBE()
{
   Print("[Test_Decide_NoLipsBreakPostBE]");
   //  partial_done=true (post-BE). Close BELOW lips for BUY. Post-revert: MA_CLOSE_LIPS
   //  is gated on !partial_done, so post-BE the trail covers it instead.
   //  Here trail target = 1.1050-0.0003 = 1.1047. current_sl=1.10020 → improves → MA_TRAIL.
   ManageContext c = MakeCtx_BuyHealthy(1.1000, 1.10020, /*close*/1.1040, /*lips*/1.1050, 0.001);
   c.partial_done       = true;
   c.bars_since_BE_move = 99;
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_TRAIL, "post-BE, close<lips -> MA_TRAIL (not MA_CLOSE_LIPS)");
   Assert(d.action != MA_CLOSE_LIPS, "post-BE never returns MA_CLOSE_LIPS");
}
//==================================================================
// Decide — zero-close sentinel guard (cross-symbol bar events)
//==================================================================
void Test_Decide_ZeroCloseSellNoAction()
{
   Print("[Test_Decide_ZeroCloseSellNoAction]");
   //  SELL position, close_m15_s1 = 0 sentinel. Without the guard the
   //  sell-side BE trigger (close <= trigger) misfires on 0. Must be MA_NONE.
   ManageContext c;
   ZeroMemory(c);
   c.is_buy            = false;
   c.entry             = 1.36588;
   c.current_sl        = 1.36721;     // initial sell SL, above entry
   c.close_m15_s1      = 0.0;
   c.lips_m15_s1       = 0.0;
   c.atr_m15_s1        = 0.0;
   c.pip               = 0.0001;
   c.be_trigger_R      = 1.0;
   c.be_buffer_pips    = 2.0;
   c.trail_atr_buffer  = 0.3;
   c.is_friday_close_time = false;
   c.is_ny_open_carryover = false;
   c.partial_done             = false;
   c.partial_close_trigger_R  = 1.0;
   c.trail_delay_bars         = 0;
   c.bars_since_BE_move       = 99;
   c.entry_R_distance         = MathAbs(c.entry - c.current_sl);
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_NONE, "SELL + close=0 sentinel -> MA_NONE (no misfire)");
}
void Test_Decide_ZeroCloseBuyNoAction()
{
   Print("[Test_Decide_ZeroCloseBuyNoAction]");
   ManageContext c;
   ZeroMemory(c);
   c.is_buy            = true;
   c.entry             = 1.36118;
   c.current_sl        = 1.35970;
   c.close_m15_s1      = 0.0;
   c.lips_m15_s1       = 0.0;
   c.atr_m15_s1        = 0.0;
   c.pip               = 0.0001;
   c.be_trigger_R      = 1.0;
   c.be_buffer_pips    = 2.0;
   c.trail_atr_buffer  = 0.3;
   c.is_friday_close_time = false;
   c.is_ny_open_carryover = false;
   c.partial_done             = false;
   c.partial_close_trigger_R  = 1.0;
   c.trail_delay_bars         = 0;
   c.bars_since_BE_move       = 99;
   c.entry_R_distance         = MathAbs(c.entry - c.current_sl);
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_NONE, "BUY + close=0 sentinel -> MA_NONE");
}
void Test_Decide_ZeroCloseTimeExitStillFires()
{
   Print("[Test_Decide_ZeroCloseTimeExitStillFires]");
   //  Even with close=0, a Friday-close must still close (time-based, fires
   //  before the zero-guard).
   ManageContext c;
   ZeroMemory(c);
   c.is_buy            = false;
   c.entry             = 1.36588;
   c.current_sl        = 1.36721;
   c.close_m15_s1      = 0.0;
   c.lips_m15_s1       = 0.0;
   c.atr_m15_s1        = 0.0;
   c.pip               = 0.0001;
   c.be_trigger_R      = 1.0;
   c.be_buffer_pips    = 2.0;
   c.trail_atr_buffer  = 0.3;
   c.is_friday_close_time = true;
   c.is_ny_open_carryover = false;
   c.partial_done             = false;
   c.partial_close_trigger_R  = 1.0;
   c.trail_delay_bars         = 0;
   c.bars_since_BE_move       = 99;
   c.entry_R_distance         = MathAbs(c.entry - c.current_sl);
   const ManageDecision d = CTradeManager::Decide(c);
   Assert(d.action == MA_CLOSE_FRIDAY, "close=0 but Friday-close still fires");
}

void OnStart()
{
   g_passed = 0; g_failed = 0;
   Test_BETrigger_Buy();
   Test_BETrigger_Sell();
   Test_BETrigger_FractionalR();
   Test_BESL_Buy_5digit();
   Test_BESL_Sell_5digit();
   Test_BESL_Gold();
   Test_TrailSL_Buy();
   Test_TrailSL_Sell();
   Test_IsImprovement_Buy();
   Test_IsImprovement_Sell();
   Test_IsImprovement_NoCurrentSL();
   Test_IsBeyondLips_BuyBreak();
   Test_IsBeyondLips_SellBreak();
   Test_IsBeyondLips_Buffered();
   Test_TightenLipsPrice_Buy();
   Test_TightenLipsPrice_Sell();
   Test_TightenLipsPrice_ClampToEntry_Buy();
   Test_TightenLipsPrice_ClampToEntry_Sell();
   Test_Decide_NYOpenCarryover_WinsAll();
   Test_Decide_FridayClose();
   Test_Decide_LipsBreak_Buy();
   Test_Decide_CloseLips_Sell();
   Test_Decide_TrailWhenBEDone();
   Test_Decide_TrailNoImprovement();
   Test_Decide_PartialAndBE_Buy();
   Test_Decide_BENotYetTriggered();
   Test_Decide_PartialAndBE_Sell();
   Test_Decide_LipsBreak_AtrBuffer();
   Test_Decide_LipsBreak_ConfirmBars();
   Test_Decide_LipsBreak_MinHold();
   Test_Decide_PartialAndBE_OnceOnly();
   Test_Decide_PartialAndBE_BeatsCloseLips();
   Test_Decide_TrailDelay_Suppressed();
   Test_Decide_TrailDelay_Elapsed();
   Test_Decide_NoLipsBreakPostBE();
   Test_Decide_ZeroCloseSellNoAction();
   Test_Decide_ZeroCloseBuyNoAction();
   Test_Decide_ZeroCloseTimeExitStillFires();
   PrintFormat("===== Done. passed=%d failed=%d =====", g_passed, g_failed);
}
