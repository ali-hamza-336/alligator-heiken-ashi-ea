//+------------------------------------------------------------------+
//|  SignalEngine.mqh                                                |
//|  Pure entry-signal decision logic.                               |
//|                                                                  |
//|  Spec: EA_Action_Plan.md §2.1 (Type A — mouth opens),            |
//|        §2.2 (Type B — HA breakout), §2.1 cond 4 / §2.2 cond 5    |
//|        (1H Alligator soft filter), §4.7 (same-instrument hedge). |
//|                                                                  |
//|  Phase 3 — Task 1: alignment + tangle helpers (pure).            |
//|  Live wrapper (BuildContext, HasOpenPositionForSymbol) is added  |
//|  in a later task; this file currently contains pure logic only.  |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_SIGNAL_ENGINE_MQH
#define ALLIGATOR_HA_SIGNAL_ENGINE_MQH

#include "IndicatorHub.mqh"
#include "HeikenAshi.mqh"
#include "MarketFilters.mqh"

//+------------------------------------------------------------------+
//| Signal kinds. SIGNAL_NONE = no entry on this bar.                |
//+------------------------------------------------------------------+
enum ESignalKind
  {
   SIGNAL_NONE         = 0,
   SIGNAL_TYPE_A_BUY   = 1,
   SIGNAL_TYPE_A_SELL  = 2,
   SIGNAL_TYPE_B_BUY   = 3,
   SIGNAL_TYPE_B_SELL  = 4
  };

//+------------------------------------------------------------------+
//| Everything the pure detectors need to make a yes/no decision.    |
//| Caller (EA) populates from IndicatorHub + CHeikenAshi + inputs.  |
//| HA arrays size-2: idx 0 = older (shift 2), idx 1 = newer (shift 1)|
//| last5_*: shifts 1..5 in any order (only min/max used).           |
//+------------------------------------------------------------------+
struct SignalContext
  {
   //--- M15 Alligator at shift 1 (curr closed) and shift 2 (prev)
   double            m15_jaw_curr;
   double            m15_teeth_curr;
   double            m15_lips_curr;
   double            m15_jaw_prev;
   double            m15_teeth_prev;
   double            m15_lips_prev;
   //--- 1H Alligator at shift 1
   double            h1_jaw;
   double            h1_teeth;
   double            h1_lips;
   //--- ATR M15 at shift 1
   double            atr;
   //--- HA last 2 closed bars
   double            ha_o[2];
   double            ha_h[2];
   double            ha_l[2];
   double            ha_c[2];
   //--- last 5 closed M15 bars
   double            last5_high[5];
   double            last5_low[5];
   //--- tunables echoed from inputs
   double            mouth_open_mult;
   double            sl_buffer_mult;
   double            tangle_tol_mult;
   double            ha_wick_tol_price;
  };

struct SignalResult
  {
   ESignalKind       kind;
   double            entry_price;       // caller fetches separately
   double            sl_price;
   string            reject_reason;
  };

class CSignalEngine
  {
public:
   //--- Pure (unit-tested)
   static bool       IsBullAligned(const double lips, const double teeth, const double jaw,
                                   const double atr,  const double mouth_open_mult);
   static bool       IsBearAligned(const double lips, const double teeth, const double jaw,
                                   const double atr,  const double mouth_open_mult);
   static bool       IsTangled    (const double lips, const double teeth, const double jaw,
                                   const double atr,  const double tangle_tol_mult);

   //--- 1H soft filter: a buy is rejected only if 1H is in CLEAN bear with
   //--- separation > mouth_open_mult*ATR; tangled or same-direction is fine.
   //--- Mirror for sell. Spec §2.1 cond 4 / §2.2 cond 5.
   static bool       H1AllowsBuy (const double h1_lips, const double h1_teeth, const double h1_jaw,
                                  const double atr, const double mouth_open_mult);
   static bool       H1AllowsSell(const double h1_lips, const double h1_teeth, const double h1_jaw,
                                  const double atr, const double mouth_open_mult);

   //--- HA pattern helpers. Convention: arrays are size-2,
   //--- index 0 = older (shift 2), index 1 = newer (shift 1) — matches
   //--- CHeikenAshi::GetClosed output. Spec §2.2 cond 2/3.
   static bool       HABothGreen     (const double &ha_o[], const double &ha_c[]);
   static bool       HABothRed       (const double &ha_o[], const double &ha_c[]);
   static bool       NewerNoLowerWick(const double &ha_o[], const double &ha_l[],
                                      const double &ha_c[], const double tol_price);
   static bool       NewerNoUpperWick(const double &ha_o[], const double &ha_h[],
                                      const double &ha_c[], const double tol_price);

   //--- Stop-loss math. Spec §2.1 (Type A: Jaw ± buf*ATR),
   //--- §2.2 (Type B: lowest-of-5 / highest-of-5 ± buf*ATR).
   static double     SLForTypeABuy (const double jaw, const double atr, const double sl_buf_mult);
   static double     SLForTypeASell(const double jaw, const double atr, const double sl_buf_mult);
   static double     SLForTypeBBuy (const double &lows[],  const int n,
                                    const double atr, const double sl_buf_mult);
   static double     SLForTypeBSell(const double &highs[], const int n,
                                    const double atr, const double sl_buf_mult);

   //--- Type A detector (pure). Spec §2.1.
   //--- Fires only on the bar where M15 transitioned from not-aligned (prev)
   //--- to aligned (curr) — the transition itself is the latch. Returns true
   //--- on signal, populating out.kind / out.sl_price. On rejection from H1
   //--- soft filter, returns false with out.reject_reason set.
   static bool       DetectTypeA(const SignalContext &ctx, SignalResult &out);

   //--- Type B detector (pure). Spec §2.2.
   //--- M15 tangled, both HA candles green/red, newer HA bar wick under
   //--- tolerance, both HA closes above/below all three M15 Alligator
   //--- lines, H1 not in opposite mouth.
   static bool       DetectTypeB(const SignalContext &ctx, SignalResult &out);

   //--- Live data assembly. Pulls indicators from `hub` + HA from rates +
   //--- last 5 M15 highs/lows. Tunables echoed from EA inputs. Returns
   //--- false on first failed read (caller logs and skips).
   static bool       BuildContext(CIndicatorHub *hub, const string sym,
                                  const double mouth_open_mult, const double sl_buffer_mult,
                                  const double tangle_tol_mult, const double ha_wick_tol_pips,
                                  SignalContext &out);

   //--- Same-instrument hedge guard (spec §4.7). Returns true iff there is
   //--- already an open position on `sym` carrying our magic.
   static bool       HasOpenPositionForSymbol(const string sym, const long magic);
  };

//+------------------------------------------------------------------+
//| Bullish alignment with separation: Lips>Teeth>Jaw AND             |
//|   (Lips - Jaw) > mouth_open_mult * ATR.                           |
//+------------------------------------------------------------------+
bool CSignalEngine::IsBullAligned(const double lips, const double teeth, const double jaw,
                                  const double atr,  const double mouth_open_mult)
  {
   if(atr <= 0) return false;
   if(!(lips > teeth && teeth > jaw)) return false;
   return (lips - jaw) > mouth_open_mult * atr;
  }

//+------------------------------------------------------------------+
//| Bearish alignment with separation: Lips<Teeth<Jaw AND             |
//|   (Jaw - Lips) > mouth_open_mult * ATR.                           |
//+------------------------------------------------------------------+
bool CSignalEngine::IsBearAligned(const double lips, const double teeth, const double jaw,
                                  const double atr,  const double mouth_open_mult)
  {
   if(atr <= 0) return false;
   if(!(lips < teeth && teeth < jaw)) return false;
   return (jaw - lips) > mouth_open_mult * atr;
  }

//+------------------------------------------------------------------+
//| Tangled / sleeping: every pairwise distance among Lips, Teeth,    |
//| Jaw is within tangle_tol_mult * ATR.                              |
//+------------------------------------------------------------------+
bool CSignalEngine::IsTangled(const double lips, const double teeth, const double jaw,
                              const double atr,  const double tangle_tol_mult)
  {
   if(atr <= 0) return false;
   const double tol = tangle_tol_mult * atr;
   return  MathAbs(lips - teeth) <= tol
        && MathAbs(teeth - jaw)  <= tol
        && MathAbs(lips - jaw)   <= tol;
  }

//+------------------------------------------------------------------+
//| Buy is allowed unless 1H is in clean bear-mouth-open.            |
//+------------------------------------------------------------------+
bool CSignalEngine::H1AllowsBuy(const double h1_lips, const double h1_teeth, const double h1_jaw,
                                const double atr, const double mouth_open_mult)
  { return !IsBearAligned(h1_lips, h1_teeth, h1_jaw, atr, mouth_open_mult); }

//+------------------------------------------------------------------+
//| Sell is allowed unless 1H is in clean bull-mouth-open.           |
//+------------------------------------------------------------------+
bool CSignalEngine::H1AllowsSell(const double h1_lips, const double h1_teeth, const double h1_jaw,
                                 const double atr, const double mouth_open_mult)
  { return !IsBullAligned(h1_lips, h1_teeth, h1_jaw, atr, mouth_open_mult); }

//+------------------------------------------------------------------+
//| HA pattern helpers (operate on size-2 arrays, idx 0=older).      |
//+------------------------------------------------------------------+
bool CSignalEngine::HABothGreen(const double &ha_o[], const double &ha_c[])
  {
   if(ArraySize(ha_o) < 2 || ArraySize(ha_c) < 2) return false;
   return ha_c[0] > ha_o[0] && ha_c[1] > ha_o[1];
  }

bool CSignalEngine::HABothRed(const double &ha_o[], const double &ha_c[])
  {
   if(ArraySize(ha_o) < 2 || ArraySize(ha_c) < 2) return false;
   return ha_c[0] < ha_o[0] && ha_c[1] < ha_o[1];
  }

//+------------------------------------------------------------------+
//| Newer (idx 1) bar wick under tolerance.                           |
//| Lower wick = body_low - low (negative wicks treated as zero).     |
//+------------------------------------------------------------------+
bool CSignalEngine::NewerNoLowerWick(const double &ha_o[], const double &ha_l[],
                                     const double &ha_c[], const double tol_price)
  {
   if(ArraySize(ha_o) < 2 || ArraySize(ha_l) < 2 || ArraySize(ha_c) < 2) return false;
   const double body_low = MathMin(ha_o[1], ha_c[1]);
   return (body_low - ha_l[1]) <= tol_price;
  }

bool CSignalEngine::NewerNoUpperWick(const double &ha_o[], const double &ha_h[],
                                     const double &ha_c[], const double tol_price)
  {
   if(ArraySize(ha_o) < 2 || ArraySize(ha_h) < 2 || ArraySize(ha_c) < 2) return false;
   const double body_high = MathMax(ha_o[1], ha_c[1]);
   return (ha_h[1] - body_high) <= tol_price;
  }

//+------------------------------------------------------------------+
//| SL math.                                                          |
//+------------------------------------------------------------------+
double CSignalEngine::SLForTypeABuy(const double jaw, const double atr, const double m)
  { return jaw - m * atr; }

double CSignalEngine::SLForTypeASell(const double jaw, const double atr, const double m)
  { return jaw + m * atr; }

double CSignalEngine::SLForTypeBBuy(const double &lows[], const int n,
                                    const double atr, const double m)
  {
   if(n <= 0 || ArraySize(lows) < n) return 0.0;
   double lo = lows[0];
   for(int i = 1; i < n; i++) if(lows[i] < lo) lo = lows[i];
   return lo - m * atr;
  }

double CSignalEngine::SLForTypeBSell(const double &highs[], const int n,
                                     const double atr, const double m)
  {
   if(n <= 0 || ArraySize(highs) < n) return 0.0;
   double hi = highs[0];
   for(int i = 1; i < n; i++) if(highs[i] > hi) hi = highs[i];
   return hi + m * atr;
  }

//+------------------------------------------------------------------+
//| DetectTypeA: mouth-opens entry. BUY arm checked first; only one  |
//| arm can fire per bar (curr cannot be both bull-aligned and bear- |
//| aligned).                                                        |
//+------------------------------------------------------------------+
bool CSignalEngine::DetectTypeA(const SignalContext &ctx, SignalResult &out)
  {
   out.kind = SIGNAL_NONE;
   out.entry_price = 0;
   out.sl_price = 0;
   out.reject_reason = "";

   //--- BUY arm: bull-aligned now, NOT bull-aligned previously.
   const bool curr_bull = IsBullAligned(ctx.m15_lips_curr, ctx.m15_teeth_curr, ctx.m15_jaw_curr,
                                        ctx.atr, ctx.mouth_open_mult);
   const bool prev_bull = IsBullAligned(ctx.m15_lips_prev, ctx.m15_teeth_prev, ctx.m15_jaw_prev,
                                        ctx.atr, ctx.mouth_open_mult);
   if(curr_bull && !prev_bull)
     {
      if(!H1AllowsBuy(ctx.h1_lips, ctx.h1_teeth, ctx.h1_jaw, ctx.atr, ctx.mouth_open_mult))
        { out.reject_reason = "h1_opposite_bear"; return false; }
      out.kind     = SIGNAL_TYPE_A_BUY;
      out.sl_price = SLForTypeABuy(ctx.m15_jaw_curr, ctx.atr, ctx.sl_buffer_mult);
      return true;
     }

   //--- SELL arm: bear-aligned now, NOT bear-aligned previously.
   const bool curr_bear = IsBearAligned(ctx.m15_lips_curr, ctx.m15_teeth_curr, ctx.m15_jaw_curr,
                                        ctx.atr, ctx.mouth_open_mult);
   const bool prev_bear = IsBearAligned(ctx.m15_lips_prev, ctx.m15_teeth_prev, ctx.m15_jaw_prev,
                                        ctx.atr, ctx.mouth_open_mult);
   if(curr_bear && !prev_bear)
     {
      if(!H1AllowsSell(ctx.h1_lips, ctx.h1_teeth, ctx.h1_jaw, ctx.atr, ctx.mouth_open_mult))
        { out.reject_reason = "h1_opposite_bull"; return false; }
      out.kind     = SIGNAL_TYPE_A_SELL;
      out.sl_price = SLForTypeASell(ctx.m15_jaw_curr, ctx.atr, ctx.sl_buffer_mult);
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| DetectTypeB: HA breakout from a tangled M15 Alligator.            |
//+------------------------------------------------------------------+
bool CSignalEngine::DetectTypeB(const SignalContext &ctx, SignalResult &out)
  {
   out.kind = SIGNAL_NONE;
   out.entry_price = 0;
   out.sl_price = 0;
   out.reject_reason = "";

   if(!IsTangled(ctx.m15_lips_curr, ctx.m15_teeth_curr, ctx.m15_jaw_curr,
                 ctx.atr, ctx.tangle_tol_mult))
     { out.reject_reason = "not_tangled"; return false; }

   const double max_line = MathMax(ctx.m15_jaw_curr,
                                   MathMax(ctx.m15_teeth_curr, ctx.m15_lips_curr));
   const double min_line = MathMin(ctx.m15_jaw_curr,
                                   MathMin(ctx.m15_teeth_curr, ctx.m15_lips_curr));

   //--- BUY arm
   if(HABothGreen(ctx.ha_o, ctx.ha_c)
      && NewerNoLowerWick(ctx.ha_o, ctx.ha_l, ctx.ha_c, ctx.ha_wick_tol_price)
      && ctx.ha_c[0] > max_line && ctx.ha_c[1] > max_line)
     {
      if(!H1AllowsBuy(ctx.h1_lips, ctx.h1_teeth, ctx.h1_jaw, ctx.atr, ctx.mouth_open_mult))
        { out.reject_reason = "h1_opposite_bear"; return false; }
      out.kind     = SIGNAL_TYPE_B_BUY;
      out.sl_price = SLForTypeBBuy(ctx.last5_low, 5, ctx.atr, ctx.sl_buffer_mult);
      return true;
     }

   //--- SELL arm
   if(HABothRed(ctx.ha_o, ctx.ha_c)
      && NewerNoUpperWick(ctx.ha_o, ctx.ha_h, ctx.ha_c, ctx.ha_wick_tol_price)
      && ctx.ha_c[0] < min_line && ctx.ha_c[1] < min_line)
     {
      if(!H1AllowsSell(ctx.h1_lips, ctx.h1_teeth, ctx.h1_jaw, ctx.atr, ctx.mouth_open_mult))
        { out.reject_reason = "h1_opposite_bull"; return false; }
      out.kind     = SIGNAL_TYPE_B_SELL;
      out.sl_price = SLForTypeBSell(ctx.last5_high, 5, ctx.atr, ctx.sl_buffer_mult);
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Live wrapper: assemble a SignalContext from broker data.         |
//+------------------------------------------------------------------+
bool CSignalEngine::BuildContext(CIndicatorHub *hub, const string sym,
                                 const double mouth_open_mult, const double sl_buffer_mult,
                                 const double tangle_tol_mult, const double ha_wick_tol_pips,
                                 SignalContext &out)
  {
   if(hub == NULL) return false;
   if(!hub.GetAlligator(sym, PERIOD_M15, 1,
                        out.m15_jaw_curr, out.m15_teeth_curr, out.m15_lips_curr)) return false;
   if(!hub.GetAlligator(sym, PERIOD_M15, 2,
                        out.m15_jaw_prev, out.m15_teeth_prev, out.m15_lips_prev)) return false;
   if(!hub.GetAlligator(sym, PERIOD_H1, 1,
                        out.h1_jaw, out.h1_teeth, out.h1_lips)) return false;
   if(!hub.GetATR(sym, 1, out.atr)) return false;

   double ho[], hh[], hl[], hc[];
   if(!CHeikenAshi::GetClosed(sym, PERIOD_M15, 1, 2, ho, hh, hl, hc)) return false;
   //  GetClosed: idx 0 = older (shift 2), idx 1 = newer (shift 1) — copy direct.
   for(int i = 0; i < 2; i++)
     {
      out.ha_o[i] = ho[i]; out.ha_h[i] = hh[i];
      out.ha_l[i] = hl[i]; out.ha_c[i] = hc[i];
     }

   double h5[], l5[];
   if(CopyHigh(sym, PERIOD_M15, 1, 5, h5) != 5) return false;
   if(CopyLow (sym, PERIOD_M15, 1, 5, l5) != 5) return false;
   for(int i = 0; i < 5; i++) { out.last5_high[i] = h5[i]; out.last5_low[i] = l5[i]; }

   out.mouth_open_mult   = mouth_open_mult;
   out.sl_buffer_mult    = sl_buffer_mult;
   out.tangle_tol_mult   = tangle_tol_mult;
   out.ha_wick_tol_price = ha_wick_tol_pips * CMarketFilters::PipSize(sym);
   return true;
  }

//+------------------------------------------------------------------+
//| Same-instrument hedge guard.                                     |
//+------------------------------------------------------------------+
bool CSignalEngine::HasOpenPositionForSymbol(const string sym, const long magic)
  {
   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != sym)   continue;
      if(PositionGetInteger(POSITION_MAGIC)  != magic) continue;
      return true;
     }
   return false;
  }

#endif // ALLIGATOR_HA_SIGNAL_ENGINE_MQH
//+------------------------------------------------------------------+
