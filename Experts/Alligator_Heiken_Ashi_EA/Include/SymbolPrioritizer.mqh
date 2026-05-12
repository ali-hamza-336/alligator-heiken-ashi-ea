//+------------------------------------------------------------------+
//|  SymbolPrioritizer.mqh                                           |
//|  Pure: rank symbols by 1H ADX descending; count those above the  |
//|  Min_ADX_1H threshold. Live wrapper pulls ADX values from the    |
//|  IndicatorHub.                                                   |
//|                                                                  |
//|  Spec: EA_Action_Plan.md §4.3 (ADX filter), §4.4 (priority).     |
//|                                                                  |
//|  Phase 6 owns the once-per-NY-session snapshot timing; for       |
//|  Phase 3 we just compute the ranking once at OnInit + use a flat |
//|  per-symbol `ADX >= Min_ADX_1H` gate at signal-evaluation time.  |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_SYMBOL_PRIORITIZER_MQH
#define ALLIGATOR_HA_SYMBOL_PRIORITIZER_MQH

#include "IndicatorHub.mqh"

struct ADXSnapshot
  {
   string            sym;
   double            adx;
   bool              valid;     // false if hub.GetADX1H failed (no data yet)
  };

class CSymbolPrioritizer
  {
public:
   //--- Pure: copy `in` into `out`, sort descending by adx (invalid → last),
   //--- return count of valid entries with adx >= min_adx.
   static int        RankByADX(const ADXSnapshot &in[], const int n, const double min_adx,
                               ADXSnapshot &out[]);

   //--- Live: populate snapshot for each symbol from hub.
   static bool       Snapshot (CIndicatorHub *hub, const string &symbols[], ADXSnapshot &out[]);
  };

//+------------------------------------------------------------------+
//| Selection-sort descending. Invalid snapshots sort last by being  |
//| treated as -DBL_MAX during comparison.                           |
//+------------------------------------------------------------------+
int CSymbolPrioritizer::RankByADX(const ADXSnapshot &in[], const int n, const double min_adx,
                                  ADXSnapshot &out[])
  {
   ArrayResize(out, n);
   for(int i = 0; i < n; i++) out[i] = in[i];

   for(int i = 0; i < n - 1; i++)
     {
      int    best     = i;
      double best_key = out[i].valid ? out[i].adx : -DBL_MAX;
      for(int j = i + 1; j < n; j++)
        {
         const double k = out[j].valid ? out[j].adx : -DBL_MAX;
         if(k > best_key) { best = j; best_key = k; }
        }
      if(best != i)
        {
         ADXSnapshot tmp = out[i];
         out[i]    = out[best];
         out[best] = tmp;
        }
     }

   int above = 0;
   for(int i = 0; i < n; i++)
      if(out[i].valid && out[i].adx >= min_adx) above++;
   return above;
  }

//+------------------------------------------------------------------+
bool CSymbolPrioritizer::Snapshot(CIndicatorHub *hub, const string &symbols[], ADXSnapshot &out[])
  {
   const int n = ArraySize(symbols);
   ArrayResize(out, n);
   for(int i = 0; i < n; i++)
     {
      out[i].sym   = symbols[i];
      double v     = 0.0;
      out[i].valid = (hub != NULL) && hub.GetADX1H(symbols[i], 1, v);
      out[i].adx   = out[i].valid ? v : 0.0;
     }
   return true;
  }

#endif // ALLIGATOR_HA_SYMBOL_PRIORITIZER_MQH
//+------------------------------------------------------------------+
