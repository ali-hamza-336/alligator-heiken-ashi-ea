//+------------------------------------------------------------------+
//|  HeikenAshi.mqh                                                  |
//|  Heiken Ashi candle computation.                                 |
//|                                                                  |
//|  Spec: EA_Action_Plan.md §1.4 (15M HA), §2.2 (HA breakout entry) |
//|                                                                  |
//|  Convention: input arrays are in CHRONOLOGICAL order              |
//|  (index 0 = oldest, index n-1 = most recent). This matches what  |
//|  MQL5 CopyOpen/Close/etc. returns into a non-series array, so    |
//|  the live wrapper can pass results straight through.             |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_HEIKEN_ASHI_MQH
#define ALLIGATOR_HA_HEIKEN_ASHI_MQH

class CHeikenAshi
  {
public:
   static bool       Compute(const double &o[], const double &h[], const double &l[], const double &c[],
                             const int count,
                             double &ha_o[], double &ha_h[], double &ha_l[], double &ha_c[]);

   static bool       GetClosed(const string sym, const ENUM_TIMEFRAMES tf,
                               const int from_shift, const int count,
                               double &ha_o[], double &ha_h[], double &ha_l[], double &ha_c[]);
  };

//+------------------------------------------------------------------+
//| Pure HA math.                                                    |
//| Bootstrap (i=0): ha_open = (open+close)/2, then recursive.       |
//| Recursive (i>=1): ha_open = (ha_open[i-1] + ha_close[i-1]) / 2.  |
//| ha_close = (o+h+l+c)/4 always.                                   |
//| ha_high  = max(high, ha_open, ha_close).                         |
//| ha_low   = min(low,  ha_open, ha_close).                         |
//+------------------------------------------------------------------+
bool CHeikenAshi::Compute(const double &o[], const double &h[], const double &l[], const double &c[],
                          const int count,
                          double &ha_o[], double &ha_h[], double &ha_l[], double &ha_c[])
  {
   if(count <= 0) return false;
   if(ArraySize(o) < count || ArraySize(h) < count || ArraySize(l) < count || ArraySize(c) < count)
      return false;

   ArrayResize(ha_o, count);
   ArrayResize(ha_h, count);
   ArrayResize(ha_l, count);
   ArrayResize(ha_c, count);

   for(int i = 0; i < count; i++)
     {
      const double prev_open  = (i == 0) ? o[0] : ha_o[i-1];
      const double prev_close = (i == 0) ? c[0] : ha_c[i-1];

      ha_o[i] = (prev_open + prev_close) / 2.0;
      ha_c[i] = (o[i] + h[i] + l[i] + c[i]) / 4.0;
      ha_h[i] = MathMax(h[i], MathMax(ha_o[i], ha_c[i]));
      ha_l[i] = MathMin(l[i], MathMin(ha_o[i], ha_c[i]));
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Live wrapper. Pulls `count` closed bars starting at `from_shift` |
//| (must be >=1 — invariant #1, never bar 0).                       |
//+------------------------------------------------------------------+
bool CHeikenAshi::GetClosed(const string sym, const ENUM_TIMEFRAMES tf,
                            const int from_shift, const int count,
                            double &ha_o[], double &ha_h[], double &ha_l[], double &ha_c[])
  {
   if(from_shift < 1 || count < 1)
      return false;

   double o[], h[], l[], c[];
   if(CopyOpen (sym, tf, from_shift, count, o) != count) return false;
   if(CopyHigh (sym, tf, from_shift, count, h) != count) return false;
   if(CopyLow  (sym, tf, from_shift, count, l) != count) return false;
   if(CopyClose(sym, tf, from_shift, count, c) != count) return false;

   return Compute(o, h, l, c, count, ha_o, ha_h, ha_l, ha_c);
  }

#endif // ALLIGATOR_HA_HEIKEN_ASHI_MQH
//+------------------------------------------------------------------+
