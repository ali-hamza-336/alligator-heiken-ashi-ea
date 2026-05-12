//+------------------------------------------------------------------+
//|  MarketFilters.mqh                                               |
//|  Two pre-trade gates: dead-market check (ATR ratio) and          |
//|  per-symbol spread cap.                                          |
//|                                                                  |
//|  Spec: EA_Action_Plan.md §4.1 (spread), §4.2 (ATR liquidity).    |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_MARKET_FILTERS_MQH
#define ALLIGATOR_HA_MARKET_FILTERS_MQH

//+------------------------------------------------------------------+
//| Per-symbol spread limits, populated from EA inputs.              |
//| Units match the spec: pips for FX, "points" for NAS100, cents    |
//| for XAUUSD (1 cent == 1 pip on gold by convention).              |
//+------------------------------------------------------------------+
struct SpreadLimits
  {
   double EURUSD;
   double GBPUSD;
   double USDJPY;
   double USDCHF;
   double AUDUSD;
   double USDCAD;
   double NZDUSD;
   double XAUUSD;
   double NAS100;
  };

class CMarketFilters
  {
public:
   //--- Pure (unit-tested)
   static bool       IsDeadMarket(const double &atr_series[], const int n,
                                  const double min_ratio);
   static bool       LookupSpreadLimit(const string canonical, const SpreadLimits &limits,
                                       double &out);

   //--- Live (integration-tested via EA)
   static double     PipSize(const string broker_symbol);
   static bool       CurrentSpreadPips(const string broker_symbol, double &out);
   static bool       IsSpreadOK(const string broker_symbol, const double limit_pips);
  };

//+------------------------------------------------------------------+
//| Spec §4.2: ATR_Now < min_ratio * ATR_Avg_20 → dead.              |
//| Convention: atr_series[0] = most recent (shift 1), [1..n-1] =    |
//| the older bars to average. Length must be at least 2 (one        |
//| current + one history). All-zero or negative-mean inputs return  |
//| false (treat unknowable as "not dead" — caller logs).            |
//+------------------------------------------------------------------+
bool CMarketFilters::IsDeadMarket(const double &atr_series[], const int n,
                                  const double min_ratio)
  {
   if(n < 2) return false;
   if(ArraySize(atr_series) < n) return false;
   if(min_ratio <= 0) return false;

   double sum = 0.0;
   for(int i = 1; i < n; i++)
      sum += atr_series[i];
   const double mean = sum / (n - 1);
   if(mean <= 0) return false;

   return atr_series[0] < min_ratio * mean;
  }

//+------------------------------------------------------------------+
//| Map canonical symbol → input limit.                              |
//| Canonical is the user-facing name (EURUSD, NAS100), not the      |
//| broker name (EURUSD.m, USTEC). Resolver runs upstream.           |
//+------------------------------------------------------------------+
bool CMarketFilters::LookupSpreadLimit(const string canonical, const SpreadLimits &limits,
                                       double &out)
  {
   if(canonical == "EURUSD") { out = limits.EURUSD; return true; }
   if(canonical == "GBPUSD") { out = limits.GBPUSD; return true; }
   if(canonical == "USDJPY") { out = limits.USDJPY; return true; }
   if(canonical == "USDCHF") { out = limits.USDCHF; return true; }
   if(canonical == "AUDUSD") { out = limits.AUDUSD; return true; }
   if(canonical == "USDCAD") { out = limits.USDCAD; return true; }
   if(canonical == "NZDUSD") { out = limits.NZDUSD; return true; }
   if(canonical == "XAUUSD") { out = limits.XAUUSD; return true; }
   if(canonical == "NAS100") { out = limits.NAS100; return true; }
   out = 0.0;
   return false;
  }

//+------------------------------------------------------------------+
//| Pip size convention:                                             |
//|   - 5-digit FX  (point=0.00001) → pip = 10*point = 0.0001        |
//|   - 3-digit JPY (point=0.001)   → pip = 10*point = 0.01          |
//|   - 4-digit FX  (point=0.0001)  → pip = point                    |
//|   - 2-digit JPY (point=0.01)    → pip = point                    |
//|   - Indices/metals (e.g. XAUUSD, NAS100) → pip = point           |
//+------------------------------------------------------------------+
double CMarketFilters::PipSize(const string broker_symbol)
  {
   const int    digits = (int)SymbolInfoInteger(broker_symbol, SYMBOL_DIGITS);
   const double point  = SymbolInfoDouble (broker_symbol, SYMBOL_POINT);
   if(digits == 5 || digits == 3) return point * 10.0;
   return point;
  }

//+------------------------------------------------------------------+
//| Current spread translated into pip units.                        |
//+------------------------------------------------------------------+
bool CMarketFilters::CurrentSpreadPips(const string broker_symbol, double &out)
  {
   const long spread_pts = SymbolInfoInteger(broker_symbol, SYMBOL_SPREAD);
   const double pip = PipSize(broker_symbol);
   if(pip <= 0) { out = 0; return false; }
   const double point = SymbolInfoDouble(broker_symbol, SYMBOL_POINT);
   out = ((double)spread_pts * point) / pip;
   return true;
  }

bool CMarketFilters::IsSpreadOK(const string broker_symbol, const double limit_pips)
  {
   double cur;
   if(!CurrentSpreadPips(broker_symbol, cur)) return false;
   return cur <= limit_pips;
  }

#endif // ALLIGATOR_HA_MARKET_FILTERS_MQH
//+------------------------------------------------------------------+
