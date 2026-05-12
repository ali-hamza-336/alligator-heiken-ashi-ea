//+------------------------------------------------------------------+
//|  SRDetector.mqh                                                  |
//|  Auto support/resistance from swing highs/lows.                  |
//|                                                                  |
//|  Spec: EA_Action_Plan.md §6 (algorithm), §3.1 (TP usage),        |
//|        §4.8 (entry block usage).                                 |
//|                                                                  |
//|  Convention: input arrays in CHRONOLOGICAL order (index 0 =      |
//|  oldest, index n-1 = most recent). Matches CopyHigh/CopyLow      |
//|  output and HeikenAshi convention.                               |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_SR_DETECTOR_MQH
#define ALLIGATOR_HA_SR_DETECTOR_MQH

class CSRDetector
  {
public:
   //--- Pure logic (unit-tested)
   static int        DetectSwings(const double &highs[], const double &lows[], const int n,
                                  const int each_side,
                                  double &swing_highs[], double &swing_lows[]);
   static int        Dedupe(double &levels[], const double tol);
   static int        CountTouches(const double &highs[], const double &lows[], const int n,
                                  const double level, const double tol);

   //--- Live wrapper (integration-tested via EA)
   static bool       Build(const string sym, const ENUM_TIMEFRAMES tf,
                           const int lookback_bars, const int each_side,
                           const double atr,
                           double &resistance[], int &res_strength[],
                           double &support[],    int &sup_strength[]);
  };

//+------------------------------------------------------------------+
//| Swing high/low detection.                                        |
//| Swing high at index i: highs[i] > highs[j] for j in              |
//|   (i-each_side .. i-1) AND (i+1 .. i+each_side). Strict >.       |
//| Swing low: mirror with strict <.                                 |
//| Edges (i < each_side or i > n-1-each_side) cannot be swings —    |
//| they don't have a full window on both sides.                     |
//| Output arrays sized to count; returns count of swings (high+low).|
//+------------------------------------------------------------------+
int CSRDetector::DetectSwings(const double &highs[], const double &lows[], const int n,
                              const int each_side,
                              double &swing_highs[], double &swing_lows[])
  {
   ArrayResize(swing_highs, 0);
   ArrayResize(swing_lows,  0);
   if(n <= 0 || each_side < 1) return 0;
   if(ArraySize(highs) < n || ArraySize(lows) < n) return 0;
   if(n < 2 * each_side + 1) return 0;

   for(int i = each_side; i <= n - 1 - each_side; i++)
     {
      bool is_sh = true;
      bool is_sl = true;
      for(int k = 1; k <= each_side && (is_sh || is_sl); k++)
        {
         if(highs[i] <= highs[i-k] || highs[i] <= highs[i+k]) is_sh = false;
         if(lows [i] >= lows [i-k] || lows [i] >= lows [i+k]) is_sl = false;
        }
      if(is_sh)
        {
         const int m = ArraySize(swing_highs);
         ArrayResize(swing_highs, m + 1);
         swing_highs[m] = highs[i];
        }
      if(is_sl)
        {
         const int m = ArraySize(swing_lows);
         ArrayResize(swing_lows, m + 1);
         swing_lows[m] = lows[i];
        }
     }
   return ArraySize(swing_highs) + ArraySize(swing_lows);
  }

//+------------------------------------------------------------------+
//| In-place dedupe: sort ascending, walk through, merge consecutive |
//| levels within tol of the running cluster mean. Output is sorted. |
//| Cluster value = arithmetic mean of all members.                  |
//|                                                                  |
//| PRECONDITION: `levels` MUST be a dynamic array. ArrayResize is   |
//| called on it; passing a static (fixed-size) array silently fails |
//| the resize and the result is wrong.                              |
//+------------------------------------------------------------------+
int CSRDetector::Dedupe(double &levels[], const double tol)
  {
   const int n = ArraySize(levels);
   if(n <= 1) return n;

   ArraySort(levels);

   double out[];
   ArrayResize(out, 0);

   double cluster_sum   = levels[0];
   int    cluster_count = 1;

   for(int i = 1; i < n; i++)
     {
      const double cluster_mean = cluster_sum / cluster_count;
      if(MathAbs(levels[i] - cluster_mean) <= tol && tol > 0)
        {
         cluster_sum += levels[i];
         cluster_count++;
        }
      else
        {
         const int m = ArraySize(out);
         ArrayResize(out, m + 1);
         out[m] = cluster_sum / cluster_count;
         cluster_sum = levels[i];
         cluster_count = 1;
        }
     }
   //  Flush trailing cluster
   const int m = ArraySize(out);
   ArrayResize(out, m + 1);
   out[m] = cluster_sum / cluster_count;

   ArrayResize(levels, ArraySize(out));
   for(int i = 0; i < ArraySize(out); i++)
      levels[i] = out[i];
   return ArraySize(levels);
  }

//+------------------------------------------------------------------+
//| Count bars whose high or low came within `tol` of `level`.       |
//+------------------------------------------------------------------+
int CSRDetector::CountTouches(const double &highs[], const double &lows[], const int n,
                              const double level, const double tol)
  {
   if(n <= 0 || tol < 0) return 0;
   if(ArraySize(highs) < n || ArraySize(lows) < n) return 0;
   int count = 0;
   for(int i = 0; i < n; i++)
     {
      if(MathAbs(highs[i] - level) <= tol) { count++; continue; }
      if(MathAbs(lows [i] - level) <= tol) { count++; }
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Live wrapper — pulls bars, runs full pipeline.                   |
//| Dedupe tol = 0.5*ATR (spec §6.2). Touch tol = 0.3*ATR (§6.3).    |
//+------------------------------------------------------------------+
bool CSRDetector::Build(const string sym, const ENUM_TIMEFRAMES tf,
                        const int lookback_bars, const int each_side,
                        const double atr,
                        double &resistance[], int &res_strength[],
                        double &support[],    int &sup_strength[])
  {
   ArrayResize(resistance,   0);
   ArrayResize(res_strength, 0);
   ArrayResize(support,      0);
   ArrayResize(sup_strength, 0);

   if(lookback_bars < 2 * each_side + 1) return false;
   if(atr <= 0) return false;

   double highs[], lows[];
   if(CopyHigh(sym, tf, 1, lookback_bars, highs) != lookback_bars) return false;
   if(CopyLow (sym, tf, 1, lookback_bars, lows ) != lookback_bars) return false;

   double sh[], sl[];
   DetectSwings(highs, lows, lookback_bars, each_side, sh, sl);

   const double dedupe_tol = 0.5 * atr;
   const double touch_tol  = 0.3 * atr;

   if(ArraySize(sh) > 0)
     {
      Dedupe(sh, dedupe_tol);
      ArrayResize(resistance,   ArraySize(sh));
      ArrayResize(res_strength, ArraySize(sh));
      for(int i = 0; i < ArraySize(sh); i++)
        {
         resistance[i]   = sh[i];
         res_strength[i] = CountTouches(highs, lows, lookback_bars, sh[i], touch_tol);
        }
     }
   if(ArraySize(sl) > 0)
     {
      Dedupe(sl, dedupe_tol);
      ArrayResize(support,      ArraySize(sl));
      ArrayResize(sup_strength, ArraySize(sl));
      for(int i = 0; i < ArraySize(sl); i++)
        {
         support[i]      = sl[i];
         sup_strength[i] = CountTouches(highs, lows, lookback_bars, sl[i], touch_tol);
        }
     }
   return true;
  }

#endif // ALLIGATOR_HA_SR_DETECTOR_MQH
//+------------------------------------------------------------------+
