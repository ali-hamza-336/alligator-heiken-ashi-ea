//+------------------------------------------------------------------+
//|  PositionManager.mqh                                             |
//|  Phase 4 — sizing + order placement.                             |
//|                                                                  |
//|  Spec: EA_Action_Plan.md §2.3 (sizing formula),                  |
//|        §3.1 (initial TP), §3.5 (TP/SL attached),                 |
//|        §9 (risk + slippage inputs).                              |
//|                                                                  |
//|  Pure (unit-tested):                                             |
//|    PipValuePerLot, RiskPctForStreak, LotSizeFor, NormalizeLot,   |
//|    InitialTPPrice, SlippagePoints                                |
//|  Live (integration-tested via EA):                               |
//|    BuildPlan, Place                                              |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_POSITION_MANAGER_MQH
#define ALLIGATOR_HA_POSITION_MANAGER_MQH

#include <Trade\Trade.mqh>
#include "SignalEngine.mqh"
#include "MarketFilters.mqh"
#include "SRDetector.mqh"

//+------------------------------------------------------------------+
//| Built once by BuildPlan, handed to Place. Caller logs preview    |
//| before sending.                                                  |
//+------------------------------------------------------------------+
struct OrderPlan
  {
   string            sym_broker;        // resolved broker name (e.g. "USTEC")
   string            sym_canonical;     // user-facing name      (e.g. "NAS100")
   ESignalKind       kind;
   bool              is_buy;
   double            entry;             // trigger M15 close — used for sizing/TP only
   double            sl;
   double            tp;
   double            risk_pct;
   int               streak_position;
   double            lot_raw;           // pre-normalization (logged for diagnostics)
   double            lots;              // post-normalization, what's actually sent
   int               slippage_pts;
   long              magic;
   string            comment;
   bool              valid;
   string            invalid_reason;
  };

//+------------------------------------------------------------------+
//| Result of Place. Caller logs and decides whether to persist state.|
//+------------------------------------------------------------------+
struct PlaceResult
  {
   bool              sent;              // OrderSend completed (with any retcode)
   bool              filled;            // retcode == TRADE_RETCODE_DONE
   ulong             ticket;
   uint              retcode;
   string            comment;
   int               retries;
   double            fill_price;        // POSITION_PRICE_OPEN after fill
  };

class CPositionManager
  {
public:
   //--- Pure
   static double     PipValuePerLot   (const double tick_value, const double tick_size,
                                       const double pip);
   static double     RiskPctForStreak (const int streak_position,
                                       const double r1, const double r2, const double r3);
   static double     LotSizeFor       (const double equity, const double risk_pct,
                                       const double sl_distance_price,
                                       const double pip_value_per_lot, const double pip);
   static double     NormalizeLot     (const double raw_lot,
                                       const double vol_min, const double vol_max,
                                       const double vol_step);
   static double     SLDistanceFloor  (const long stops_level_pts, const double point,
                                       const double atr, const double min_sl_atr_mult);
   static bool       IsSLOnCorrectSide(const bool is_buy, const double entry, const double sl);
   static double     InitialTPPrice   (const bool is_buy,
                                       const double entry, const double sl,
                                       const double &sr_in_direction[]);
   static int        SlippagePoints   (const string canonical,
                                       const int slip_fx_pips, const int slip_gold_cents,
                                       const int slip_nas_points,
                                       const double point, const double pip);

   //--- Live: assemble plan from broker data + signal result + state
   static bool       BuildPlan(const string sym_broker, const string sym_canonical,
                               const SignalResult &sig, const double entry_price,
                               const double atr, const double equity,
                               const int streak_position,
                               const double r1, const double r2, const double r3,
                               const long magic,
                               const int slip_fx_pips, const int slip_gold_cents,
                               const int slip_nas_points,
                               const int sr_lookback_h1, const int sr_lookback_h4,
                               const int sr_swing_each_side,
                               const double min_sl_atr_mult, const double max_lot,
                               OrderPlan &out);

   //--- Live: send the order via CTrade. Bounded retries on transient retcodes.
   static bool       Place(const OrderPlan &plan, PlaceResult &out);
  };

//+------------------------------------------------------------------+
//| Spec §2.3 pip-value math: tick_value × (pip / tick_size).        |
//| tick_value is reported by broker in account currency, so this    |
//| works uniformly across FX / metals / indices.                    |
//+------------------------------------------------------------------+
double CPositionManager::PipValuePerLot(const double tick_value, const double tick_size,
                                        const double pip)
  {
   if(tick_size <= 0) return 0.0;
   return tick_value * (pip / tick_size);
  }

//+------------------------------------------------------------------+
//| Spec §2.3: fixed risk array {r1, r2, r3} indexed by streak       |
//| position 1/2/3. Out-of-range returns 0 so caller's lot collapses |
//| to invalid (caught downstream) rather than silently using a      |
//| guess. Spec §14 #1 — never compute as `prev × multiplier`.       |
//+------------------------------------------------------------------+
double CPositionManager::RiskPctForStreak(const int streak_position,
                                          const double r1, const double r2, const double r3)
  {
   if(streak_position == 1) return r1;
   if(streak_position == 2) return r2;
   if(streak_position == 3) return r3;
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Spec §2.3 lot formula:                                           |
//|   Risk_Amount   = equity × risk_pct / 100                        |
//|   SL_pips       = sl_distance_price / pip                        |
//|   Lot           = Risk_Amount / (SL_pips × pip_value_per_lot)    |
//| Returns 0.0 on any non-positive input — caller treats as invalid.|
//+------------------------------------------------------------------+
double CPositionManager::LotSizeFor(const double equity, const double risk_pct,
                                    const double sl_distance_price,
                                    const double pip_value_per_lot, const double pip)
  {
   if(equity <= 0 || risk_pct <= 0)        return 0.0;
   if(sl_distance_price <= 0 || pip <= 0)  return 0.0;
   if(pip_value_per_lot <= 0)              return 0.0;
   const double risk_amount = equity * risk_pct / 100.0;
   const double sl_pips     = sl_distance_price / pip;
   return risk_amount / (sl_pips * pip_value_per_lot);
  }

//+------------------------------------------------------------------+
//| Round DOWN to broker volume_step so the placed lot never breaches|
//| the risk %. Below min → return 0 (skip trade); above max → cap.  |
//+------------------------------------------------------------------+
double CPositionManager::NormalizeLot(const double raw_lot,
                                      const double vol_min, const double vol_max,
                                      const double vol_step)
  {
   if(raw_lot <= 0 || vol_step <= 0) return 0.0;
   const double stepped = MathFloor(raw_lot / vol_step) * vol_step;
   if(stepped < vol_min) return 0.0;          // below broker min → caller skips
   if(stepped > vol_max) return vol_max;
   return NormalizeDouble(stepped, 8);
  }

//+------------------------------------------------------------------+
//| Path A: minimum allowed SL distance for a new entry =            |
//|   max(broker stops_level × point, min_sl_atr_mult × ATR).        |
//| A tangled-Alligator (Type-B) entry can otherwise put the         |
//| structural SL a fraction of a pip from entry — which the broker  |
//| rejects (Invalid stops) and which blows up the risk-based lot.   |
//| A non-positive ATR (or mult, or stops_level) just drops that     |
//| term; if both terms are 0 the floor is 0 and the caller's other  |
//| checks (sl_dist<=0, lot collapse) still apply.                   |
//+------------------------------------------------------------------+
double CPositionManager::SLDistanceFloor(const long stops_level_pts, const double point,
                                         const double atr, const double min_sl_atr_mult)
  {
   const double a = (stops_level_pts > 0 && point > 0) ? (double)stops_level_pts * point : 0.0;
   const double b = (atr > 0 && min_sl_atr_mult > 0)   ? min_sl_atr_mult * atr           : 0.0;
   return MathMax(a, b);
  }

//+------------------------------------------------------------------+
//| Path A Stage 1.1: caller's signal generator can occasionally hand |
//| us an SL on the wrong side of entry (e.g. A_SELL with sl below   |
//| entry); the broker rejects those with retcode 10016 Invalid stops.|
//| BUY needs sl<entry, SELL needs sl>entry. sl==entry is wrong-side |
//| too (zero-distance stop).                                         |
//+------------------------------------------------------------------+
bool CPositionManager::IsSLOnCorrectSide(const bool is_buy, const double entry, const double sl)
  {
   return is_buy ? (sl < entry) : (sl > entry);
  }

//+------------------------------------------------------------------+
//| Spec §3.1: TP = closer of (2R, nearest in-direction S/R).        |
//| Caller passes only S/R levels on the correct side of entry       |
//| (resistance for BUY, support for SELL); we still defensively     |
//| skip wrong-side and >5R levels here. If no qualifying S/R, TP    |
//| defaults to 2R from entry.                                       |
//+------------------------------------------------------------------+
double CPositionManager::InitialTPPrice(const bool is_buy,
                                        const double entry, const double sl,
                                        const double &sr_in_direction[])
  {
   const double r       = MathAbs(entry - sl);
   const double tp_2R   = is_buy ? entry + 2.0 * r : entry - 2.0 * r;
   const double window  = 5.0 * r;

   double best = 0;
   bool   has  = false;
   const int n = ArraySize(sr_in_direction);
   for(int i = 0; i < n; i++)
     {
      const double lvl = sr_in_direction[i];
      const double d   = is_buy ? (lvl - entry) : (entry - lvl);
      if(d <= 0)        continue;            // wrong side of entry
      if(d > window)    continue;            // beyond 5R window
      //  "Nearest" S/R = closest to entry. For BUY that's the smallest
      //  level above entry; for SELL the largest below.
      if(!has) { best = lvl; has = true; }
      else
        {
         if(is_buy)  { if(lvl < best) best = lvl; }
         else        { if(lvl > best) best = lvl; }
        }
     }
   if(!has) return tp_2R;
   //  Closer of (nearest S/R, 2R). For BUY both are above entry, so
   //  the nearer one to entry is the smaller price; mirror for SELL.
   if(is_buy)  return MathMin(best, tp_2R);
   return MathMax(best, tp_2R);
  }

//+------------------------------------------------------------------+
//| Spec §9 slippage block. FX inputs are in pips → convert to       |
//| points via pip/point ratio (10 on 5/3-digit, 1 on 4/2-digit).    |
//| Gold input is in cents; XAUUSD point is typically 0.01, so cents |
//| ≈ points (broker-dependent). NAS input is points already.        |
//+------------------------------------------------------------------+
int CPositionManager::SlippagePoints(const string canonical,
                                     const int slip_fx_pips, const int slip_gold_cents,
                                     const int slip_nas_points,
                                     const double point, const double pip)
  {
   if(canonical == "XAUUSD") return slip_gold_cents;
   if(canonical == "NAS100") return slip_nas_points;
   if(point <= 0) return slip_fx_pips;
   const double factor = pip / point;
   return (int)MathRound(slip_fx_pips * factor);
  }

//+------------------------------------------------------------------+
//| BuildPlan — read broker data, compute lot + TP, populate plan.   |
//| Returns false (and stamps out.invalid_reason) if any sub-step    |
//| fails or the lot collapses to zero.                              |
//+------------------------------------------------------------------+
bool CPositionManager::BuildPlan(const string sym_broker, const string sym_canonical,
                                 const SignalResult &sig, const double entry_price,
                                 const double atr, const double equity,
                                 const int streak_position,
                                 const double r1, const double r2, const double r3,
                                 const long magic,
                                 const int slip_fx_pips, const int slip_gold_cents,
                                 const int slip_nas_points,
                                 const int sr_lookback_h1, const int sr_lookback_h4,
                                 const int sr_swing_each_side,
                                 const double min_sl_atr_mult, const double max_lot,
                                 OrderPlan &out)
  {
   //--- Static fields
   out.sym_broker      = sym_broker;
   out.sym_canonical   = sym_canonical;
   out.kind            = sig.kind;
   out.is_buy          = (sig.kind == SIGNAL_TYPE_A_BUY || sig.kind == SIGNAL_TYPE_B_BUY);
   out.entry           = entry_price;
   out.sl              = sig.sl_price;
   out.tp              = 0.0;
   out.streak_position = streak_position;
   out.magic           = magic;
   out.lot_raw         = 0.0;
   out.lots            = 0.0;
   out.slippage_pts    = 0;
   out.valid           = false;
   out.invalid_reason  = "";

   //--- Risk %
   out.risk_pct = RiskPctForStreak(streak_position, r1, r2, r3);
   if(out.risk_pct <= 0)
     { out.invalid_reason = StringFormat("bad streak_position=%d", streak_position); return false; }

   //--- Symbol meta
   const double tick_size  = SymbolInfoDouble (sym_broker, SYMBOL_TRADE_TICK_SIZE);
   const double tick_value = SymbolInfoDouble (sym_broker, SYMBOL_TRADE_TICK_VALUE);
   const double point      = SymbolInfoDouble (sym_broker, SYMBOL_POINT);
   const double pip        = CMarketFilters::PipSize(sym_broker);
   const double vol_min    = SymbolInfoDouble (sym_broker, SYMBOL_VOLUME_MIN);
   const double vol_max    = SymbolInfoDouble (sym_broker, SYMBOL_VOLUME_MAX);
   const double vol_step   = SymbolInfoDouble (sym_broker, SYMBOL_VOLUME_STEP);
   if(tick_size <= 0 || tick_value <= 0 || point <= 0 || pip <= 0
      || vol_min <= 0 || vol_step <= 0)
     { out.invalid_reason = "broker symbol meta missing/zero"; return false; }

   //--- SL distance (price)
   const double sl_dist = MathAbs(out.entry - out.sl);
   if(sl_dist <= 0)
     { out.invalid_reason = "sl_distance==0"; return false; }

   //--- Path A Stage 1.1: reject signals whose SL is on the wrong side of entry
   //--- (broker would reject with retcode 10016 Invalid stops).
   if(!IsSLOnCorrectSide(out.is_buy, out.entry, out.sl))
     { out.invalid_reason = StringFormat("SL on wrong side of entry (is_buy=%d entry=%.5f sl=%.5f)",
                                          (int)out.is_buy, out.entry, out.sl); return false; }

   //--- Path A: reject if the structural SL is closer to entry than the floor
   //--- (broker stops level OR min_sl_atr_mult×ATR) — see SLDistanceFloor.
   {
      const long   stops_level_pts = SymbolInfoInteger(sym_broker, SYMBOL_TRADE_STOPS_LEVEL);
      const double sl_floor = SLDistanceFloor(stops_level_pts, point, atr, min_sl_atr_mult);
      if(sl_dist < sl_floor)
        { out.invalid_reason = StringFormat("SL too tight: dist=%.5f < floor=%.5f (stops_lvl=%dpts, %.2f*ATR=%.5f)",
                                            sl_dist, sl_floor, (int)stops_level_pts, min_sl_atr_mult, min_sl_atr_mult*atr);
          return false; }
   }

   //--- Pip-value & lot (lot hard-capped at max_lot — belt-and-braces vs blow-ups)
   const double pip_value = PipValuePerLot(tick_value, tick_size, pip);
   out.lot_raw = LotSizeFor(equity, out.risk_pct, sl_dist, pip_value, pip);
   out.lots    = NormalizeLot(MathMin(out.lot_raw, max_lot), vol_min, vol_max, vol_step);
   if(out.lots <= 0)
     { out.invalid_reason = StringFormat("lot collapsed (raw=%.4f min=%.2f)", out.lot_raw, vol_min);
       return false; }

   //--- Slippage points
   out.slippage_pts = SlippagePoints(sym_canonical, slip_fx_pips, slip_gold_cents,
                                     slip_nas_points, point, pip);

   //--- Initial TP via S/R scan (H1 + H4). MQL5 doesn't permit pointers
   //--- to dynamic-array references, so branch on direction explicitly.
   double sr_dir[];
   {
      double res_h1[], sup_h1[], res_h4[], sup_h4[];
      int    rsh[],    ssh[],    rs4[],    ss4[];
      const bool ok_h1 = CSRDetector::Build(sym_broker, PERIOD_H1, sr_lookback_h1,
                                            sr_swing_each_side, atr,
                                            res_h1, rsh, sup_h1, ssh);
      const bool ok_h4 = CSRDetector::Build(sym_broker, PERIOD_H4, sr_lookback_h4,
                                            sr_swing_each_side, atr,
                                            res_h4, rs4, sup_h4, ss4);
      const int n1 = (out.is_buy ? (ok_h1 ? ArraySize(res_h1) : 0)
                                 : (ok_h1 ? ArraySize(sup_h1) : 0));
      const int n2 = (out.is_buy ? (ok_h4 ? ArraySize(res_h4) : 0)
                                 : (ok_h4 ? ArraySize(sup_h4) : 0));
      ArrayResize(sr_dir, n1 + n2);
      for(int i = 0; i < n1; i++) sr_dir[i]      = (out.is_buy ? res_h1[i] : sup_h1[i]);
      for(int i = 0; i < n2; i++) sr_dir[n1 + i] = (out.is_buy ? res_h4[i] : sup_h4[i]);
   }
   out.tp = InitialTPPrice(out.is_buy, out.entry, out.sl, sr_dir);

   //--- Comment + flag valid
   const string kind_str =
      (out.kind == SIGNAL_TYPE_A_BUY ) ? "A_BUY"  :
      (out.kind == SIGNAL_TYPE_A_SELL) ? "A_SELL" :
      (out.kind == SIGNAL_TYPE_B_BUY ) ? "B_BUY"  : "B_SELL";
   out.comment = StringFormat("AHA P%d %s", streak_position, kind_str);
   out.valid   = true;
   return true;
  }

//+------------------------------------------------------------------+
//| Place — CTrade wrapper with bounded retries on transient errors. |
//| Retries 200ms × ≤2 on REQUOTE / PRICE_CHANGED / PRICE_OFF; any   |
//| other failing retcode is final. On TRADE_RETCODE_DONE, looks up  |
//| the new position to capture ticket + actual fill price.          |
//+------------------------------------------------------------------+
bool CPositionManager::Place(const OrderPlan &plan, PlaceResult &out)
  {
   out.sent       = false;
   out.filled     = false;
   out.ticket     = 0;
   out.retcode    = 0;
   out.comment    = "";
   out.retries    = 0;
   out.fill_price = 0.0;

   if(!plan.valid) { out.comment = "plan invalid: " + plan.invalid_reason; return false; }

   CTrade trade;
   trade.SetExpertMagicNumber(plan.magic);
   trade.SetDeviationInPoints(plan.slippage_pts);
   trade.SetTypeFillingBySymbol(plan.sym_broker);

   for(int attempt = 0; attempt < 3; attempt++)
     {
      bool sent = false;
      if(plan.is_buy) sent = trade.Buy (plan.lots, plan.sym_broker, 0.0, plan.sl, plan.tp, plan.comment);
      else            sent = trade.Sell(plan.lots, plan.sym_broker, 0.0, plan.sl, plan.tp, plan.comment);
      out.sent    = sent;
      out.retcode = trade.ResultRetcode();
      out.retries = attempt;
      if(out.retcode == TRADE_RETCODE_DONE) break;
      if(out.retcode == TRADE_RETCODE_REQUOTE
         || out.retcode == TRADE_RETCODE_PRICE_CHANGED
         || out.retcode == TRADE_RETCODE_PRICE_OFF)
        { Sleep(200); continue; }
      break;   // hard error — don't retry
     }

   if(out.retcode != TRADE_RETCODE_DONE)
     {
      out.comment = StringFormat("retcode=%u %s", out.retcode, trade.ResultComment());
      return false;
     }

   //--- Position exists now; capture ticket + actual fill price
   if(PositionSelect(plan.sym_broker))
     {
      out.ticket     = (ulong)PositionGetInteger(POSITION_TICKET);
      out.fill_price = PositionGetDouble(POSITION_PRICE_OPEN);
      out.filled     = true;
     }
   out.comment = trade.ResultComment();
   return true;
  }

#endif // ALLIGATOR_HA_POSITION_MANAGER_MQH
//+------------------------------------------------------------------+
