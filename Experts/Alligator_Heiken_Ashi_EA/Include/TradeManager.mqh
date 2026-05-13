//+------------------------------------------------------------------+
//|  TradeManager.mqh                                                |
//|  Phase 5 — break-even, trailing, forced exits, decide().         |
//|  Phase 8 — Lips-break softening (ATR buffer / N-bar confirm /    |
//|  min-hold bars); defaults reproduce §3.4 exactly.               |
//|  Path A Stage 2 (Task C) — Decide rewrite:                       |
//|    + MA_PARTIAL_AND_BE  (replaces MA_MOVE_BE; close partial @+1R)|
//|    + MA_TIGHTEN_SL_LIPS (replaces MA_CLOSE_LIPS; pre-BE only)    |
//|    + trail-delay gate (MA_TRAIL waits N bars after BE move)      |
//|    + TightenLipsPrice pure helper                                |
//|                                                                  |
//|  Spec: §3.2 (BE), §3.3 (trail), §3.4 (forced exits),             |
//|        §14 #1 (closed candles), §14 #2 (no per-tick).            |
//|                                                                  |
//|  Pure (unit-tested):                                             |
//|    CalcBETrigger, CalcBESL, CalcTrailSL, TightenLipsPrice,       |
//|    IsImprovement, IsBeyondLips, Decide                           |
//|  Live (integration-tested via EA):                               |
//|    ModifySL, CloseAtMarket                                       |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_TRADE_MANAGER_MQH
#define ALLIGATOR_HA_TRADE_MANAGER_MQH

#include <Trade\Trade.mqh>

enum EManageAction
  {
   MA_NONE              = 0,
   MA_MOVE_BE           = 1,   // DEPRECATED: removed in Task D; Decide no longer returns this
   MA_TRAIL             = 2,
   MA_CLOSE_LIPS        = 3,   // DEPRECATED: removed in Task D; Decide no longer returns this
   MA_CLOSE_FRIDAY      = 4,
   MA_CLOSE_NYOPEN      = 5,
   MA_PARTIAL_AND_BE    = 6,   // Stage 2: at +trigger_R, partial-close + move SL to BE+buffer
   MA_TIGHTEN_SL_LIPS   = 7,   // Stage 2: pre-BE Lips break, tighten SL to Lips ± buf×ATR (clamped to entry)
  };

struct ManageDecision
  {
   EManageAction     action;
   double            new_sl;
   string            reason;
  };

struct ManageContext
  {
   bool              is_buy;
   double            entry;
   double            current_sl;
   double            close_m15_s1;
   double            lips_m15_s1;
   double            atr_m15_s1;
   double            pip;
   double            be_trigger_R;
   double            be_buffer_pips;
   double            trail_atr_buffer;
   bool              is_friday_close_time;
   bool              is_ny_open_carryover;
   //--- Phase 8: Lips-break softening. All default to the spec no-op:
   //---   lips_break_atr_buffer == 0   -> exact §3.4 break test
   //---   lips_break_confirm_bars <= 1 -> only the s1 bar must be beyond
   //---   lips_break_min_hold_bars == 0-> Lips exit allowed from the first eval
   double            lips_break_atr_buffer;    // multiplier on atr_m15_s1
   int               lips_break_confirm_bars;  // 1..3
   int               lips_break_min_hold_bars; // bars since entry below which Lips exit is suppressed
   int               bars_since_entry;
   double            close_m15_s2;             // bar before s1 (0 = not available / not needed)
   double            lips_m15_s2;
   double            close_m15_s3;             // two bars before s1 (0 = not available / not needed)
   double            lips_m15_s3;
   //--- Stage 2: partial-close-and-BE + trail-delay
   bool              partial_done;             // true after MA_PARTIAL_AND_BE has fired for this trade
   double            partial_close_trigger_R;  // e.g. 1.0 → partial fires at entry ± 1×R
   int               trail_delay_bars;         // MA_TRAIL suppressed until this many M15 bars after BE move
   int               bars_since_BE_move;       // caller-computed from g_state.be_move_time
   double            entry_R_distance;         // |entry - original_sl|, snapshotted by caller at entry
  };

class CTradeManager
  {
public:
   //--- Pure
   static double          CalcBETrigger    (const bool is_buy, const double entry,
                                            const double sl, const double be_trigger_R);
   static double          CalcBESL         (const bool is_buy, const double entry,
                                            const double be_buffer_pips, const double pip);
   static double          CalcTrailSL      (const bool is_buy, const double lips,
                                            const double atr, const double trail_atr_buffer);
   static double          TightenLipsPrice (const bool is_buy, const double lips_s1,
                                            const double atr_m15_s1, const double trail_buf,
                                            const double entry_price);
   static bool            IsImprovement    (const bool is_buy, const double new_sl,
                                            const double current_sl);
   static bool            IsBeyondLips     (const bool is_buy, const double close_price,
                                            const double lips, const double buffer = 0.0);
   static ManageDecision  Decide           (const ManageContext &ctx);

   //--- Live
   static bool            ModifySL         (const ulong ticket, const double new_sl,
                                            const double tp);
   static bool            CloseAtMarket    (const ulong ticket, const int slippage_pts);
  };

//+------------------------------------------------------------------+
//| Spec §3.2: BE triggers when unrealized profit reaches +N×R, where|
//| R = |entry - SL|. Caller passes BE_Trigger_R (default 1.0).      |
//+------------------------------------------------------------------+
double CTradeManager::CalcBETrigger(const bool is_buy, const double entry,
                                    const double sl, const double be_trigger_R)
  {
   const double r = MathAbs(entry - sl);
   return is_buy ? entry + be_trigger_R * r : entry - be_trigger_R * r;
  }

//+------------------------------------------------------------------+
//| Spec §3.2: BE SL = entry ± BE_Buffer_Pips.                       |
//+------------------------------------------------------------------+
double CTradeManager::CalcBESL(const bool is_buy, const double entry,
                               const double be_buffer_pips, const double pip)
  {
   const double offset = be_buffer_pips * pip;
   return is_buy ? entry + offset : entry - offset;
  }

//+------------------------------------------------------------------+
//| Spec §3.3: trail SL = Lips ± Trail_ATR_Buffer × ATR.             |
//+------------------------------------------------------------------+
double CTradeManager::CalcTrailSL(const bool is_buy, const double lips,
                                  const double atr, const double trail_atr_buffer)
  {
   const double offset = trail_atr_buffer * atr;
   return is_buy ? lips - offset : lips + offset;
  }

//+------------------------------------------------------------------+
//| Stage 2 / Approach C: Lips-break tighten price.                  |
//| Pre-BE, a Lips break (close on the wrong side of the Lips line)  |
//| no longer market-closes the trade (old MA_CLOSE_LIPS) — it now   |
//| tightens the SL to Lips ± Trail_ATR_Buffer × ATR. Clamped to NOT |
//| cross entry, so SL stays strictly on the loss side of entry      |
//| pre-BE (post-BE the trail handles the same logic without clamp,  |
//| since by then SL is already past entry).                         |
//|                                                                  |
//| Same offset shape as CalcTrailSL — reuses Trail_ATR_Buffer       |
//| intentionally so a single knob controls how tight both behave.   |
//+------------------------------------------------------------------+
double CTradeManager::TightenLipsPrice(const bool is_buy, const double lips_s1,
                                        const double atr_m15_s1, const double trail_buf,
                                        const double entry_price)
  {
   const double offset = trail_buf * atr_m15_s1;
   const double raw    = is_buy ? lips_s1 - offset : lips_s1 + offset;
   if(is_buy)  return MathMin(raw, entry_price);
   return MathMax(raw, entry_price);
  }

//+------------------------------------------------------------------+
//| Spec §3.2/§3.3 last line — never move SL backward.               |
//| BUY: improvement = new_sl strictly > current_sl                   |
//| SELL: improvement = new_sl strictly < current_sl                  |
//| current_sl == 0 (no SL on broker) → any positive new_sl improves. |
//+------------------------------------------------------------------+
bool CTradeManager::IsImprovement(const bool is_buy, const double new_sl,
                                  const double current_sl)
  {
   if(new_sl <= 0) return false;
   if(current_sl <= 0) return true;
   if(is_buy)  return new_sl > current_sl;
   return new_sl < current_sl;
  }

//+------------------------------------------------------------------+
//| Spec §3.4 (+ Phase-8 LipsBreak_ATR_Buffer): M15 close on the      |
//| opposite side of Lips by more than `buffer` → full break.        |
//| BUY break = close < lips - buffer. SELL break = close > lips +   |
//| buffer. buffer == 0 reproduces the exact spec test.             |
//+------------------------------------------------------------------+
bool CTradeManager::IsBeyondLips(const bool is_buy, const double close_price,
                                 const double lips, const double buffer)
  {
   if(is_buy) return close_price < lips - buffer;
   return close_price > lips + buffer;
  }

//+------------------------------------------------------------------+
//| Decide — single pass over the bar context. Stage 2 priority:     |
//|   1. NY-open carryover     (spec §5.5 — wins over everything)    |
//|   2. Friday close          (spec §5.7)                           |
//|   3. Zero-close guard      (invariant #10)                       |
//|   4. MA_PARTIAL_AND_BE     (Stage 2: at +trigger_R, !partial_done)|
//|   5. MA_TIGHTEN_SL_LIPS    (Stage 2: Lips break, !partial_done,  |
//|                              Phase-8 softening still gates it)   |
//|   6. MA_TRAIL              (post-BE; gated by Trail_Delay_Bars)  |
//|   7. otherwise             MA_NONE                               |
//|                                                                  |
//| Stage 2 BE-done detection uses ctx.partial_done (explicit flag), |
//| not current_sl >= entry. After partial fires, current_sl ≈ entry,|
//| so the old derivation breaks down; the flag is cleaner.          |
//|                                                                  |
//| R = ctx.entry_R_distance (caller-snapshotted at entry). Used     |
//| directly instead of MathAbs(entry - current_sl), since the latter|
//| collapses to ~0 after BE move + would misfire PartialAndBE.      |
//+------------------------------------------------------------------+
ManageDecision CTradeManager::Decide(const ManageContext &ctx)
  {
   ManageDecision d;
   d.action = MA_NONE;
   d.new_sl = 0.0;
   d.reason = "";

   if(ctx.is_ny_open_carryover)
     { d.action = MA_CLOSE_NYOPEN; d.reason = "NY-open carryover from previous cycle"; return d; }
   if(ctx.is_friday_close_time)
     { d.action = MA_CLOSE_FRIDAY; d.reason = "Friday close hour reached (NY)";        return d; }
   //--- No closed-bar data for the open position's symbol on this event
   //--- (caller passes 0 sentinels when the new M15 bar belongs to a
   //--- different symbol than the open position). Price-based actions
   //--- (PartialAndBE, TightenSLLips, trail) need a real close; skip them.
   //--- The time-based exits above still fire regardless. Invariant #10.
   if(ctx.close_m15_s1 <= 0.0)
      return d;

   //--- Stage 2 step 4: MA_PARTIAL_AND_BE — only pre-partial, at +trigger_R.
   if(!ctx.partial_done)
     {
      const double trig_price = ctx.is_buy
                                ? ctx.entry + ctx.partial_close_trigger_R * ctx.entry_R_distance
                                : ctx.entry - ctx.partial_close_trigger_R * ctx.entry_R_distance;
      const bool reached = ctx.is_buy ? (ctx.close_m15_s1 >= trig_price)
                                      : (ctx.close_m15_s1 <= trig_price);
      if(reached)
        {
         const double be_sl = CalcBESL(ctx.is_buy, ctx.entry, ctx.be_buffer_pips, ctx.pip);
         d.action = MA_PARTIAL_AND_BE;
         d.new_sl = be_sl;
         d.reason = StringFormat("partial+BE: close=%.5f %s trigger=%.5f -> SL %.5f",
                                 ctx.close_m15_s1, ctx.is_buy ? ">=" : "<=", trig_price, be_sl);
         return d;
        }
     }

   //--- Stage 2 step 5: MA_TIGHTEN_SL_LIPS — only pre-partial (post-BE trail covers).
   //--- Phase-8 softening (min-hold, ATR buffer, N-bar confirm) gates it.
   if(!ctx.partial_done && ctx.bars_since_entry >= ctx.lips_break_min_hold_bars)
     {
      const double lb_buf = ctx.lips_break_atr_buffer * ctx.atr_m15_s1;
      bool broken = IsBeyondLips(ctx.is_buy, ctx.close_m15_s1, ctx.lips_m15_s1, lb_buf);
      if(broken && ctx.lips_break_confirm_bars >= 2)
         broken = IsBeyondLips(ctx.is_buy, ctx.close_m15_s2, ctx.lips_m15_s2, lb_buf);
      if(broken && ctx.lips_break_confirm_bars >= 3)
         broken = IsBeyondLips(ctx.is_buy, ctx.close_m15_s3, ctx.lips_m15_s3, lb_buf);
      if(broken)
        {
         const double tighten = TightenLipsPrice(ctx.is_buy, ctx.lips_m15_s1, ctx.atr_m15_s1,
                                                 ctx.trail_atr_buffer, ctx.entry);
         if(IsImprovement(ctx.is_buy, tighten, ctx.current_sl))
           {
            d.action = MA_TIGHTEN_SL_LIPS;
            d.new_sl = tighten;
            d.reason = StringFormat("tighten SL on Lips break: close=%.5f %s lips=%.5f (buf=%.5f confirm=%d) -> SL %.5f",
                                    ctx.close_m15_s1, ctx.is_buy ? "<" : ">", ctx.lips_m15_s1,
                                    lb_buf, ctx.lips_break_confirm_bars, tighten);
            return d;
           }
         //--- broken but not an improvement -> fall through to trail / none
        }
     }

   //--- Stage 2 step 6: MA_TRAIL — post-BE only, gated by trail_delay_bars.
   if(ctx.partial_done && ctx.bars_since_BE_move >= ctx.trail_delay_bars)
     {
      const double trail = CalcTrailSL(ctx.is_buy, ctx.lips_m15_s1, ctx.atr_m15_s1,
                                       ctx.trail_atr_buffer);
      if(IsImprovement(ctx.is_buy, trail, ctx.current_sl))
        {
         d.action = MA_TRAIL;
         d.new_sl = trail;
         d.reason = StringFormat("trail %s lips=%.5f atr=%.5f buf=%.2f -> %.5f",
                                 ctx.is_buy ? "BUY" : "SELL", ctx.lips_m15_s1,
                                 ctx.atr_m15_s1, ctx.trail_atr_buffer, trail);
         return d;
        }
     }

   return d;
  }

//+------------------------------------------------------------------+
//| Live: ModifySL via CTrade. Preserves TP. Returns true on retcode |
//| TRADE_RETCODE_DONE. Caller checks IsImprovement before calling.  |
//+------------------------------------------------------------------+
bool CTradeManager::ModifySL(const ulong ticket, const double new_sl, const double tp)
  {
   CTrade trade;
   if(!trade.PositionModify(ticket, new_sl, tp))
     {
      PrintFormat("CTradeManager.ModifySL: ticket=%I64u retcode=%u %s",
                   ticket, trade.ResultRetcode(), trade.ResultComment());
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Live: CloseAtMarket via CTrade with caller-provided slippage.    |
//+------------------------------------------------------------------+
bool CTradeManager::CloseAtMarket(const ulong ticket, const int slippage_pts)
  {
   CTrade trade;
   trade.SetDeviationInPoints(slippage_pts);
   if(!trade.PositionClose(ticket))
     {
      PrintFormat("CTradeManager.CloseAtMarket: ticket=%I64u retcode=%u %s",
                   ticket, trade.ResultRetcode(), trade.ResultComment());
      return false;
     }
   return true;
  }

#endif // ALLIGATOR_HA_TRADE_MANAGER_MQH
//+------------------------------------------------------------------+
