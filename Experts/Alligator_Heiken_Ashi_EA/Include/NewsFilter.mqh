//+------------------------------------------------------------------+
//|  NewsFilter.mqh                                                  |
//|  Phase 7 — high-impact economic-news blackout. Pure helpers      |
//|  (currency map / impact tier / blackout window) + a live wrapper |
//|  that queries the MT5 economic calendar. Auto-skips in the       |
//|  Strategy Tester (calendar unavailable there). Fail-open.        |
//|                                                                  |
//|  Spec: §4.5.                                                     |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_NEWS_FILTER_MQH
#define ALLIGATOR_HA_NEWS_FILTER_MQH

class CNewsFilter
  {
public:
   //--- pure ---
   // canonical in {EURUSD,GBPUSD,USDJPY,USDCHF,AUDUSD,USDCAD,NZDUSD,XAUUSD,NAS100}.
   // Fills `out` with the ISO currency codes whose high-impact news should block this symbol.
   //   6 alpha chars (FX pair) -> {base, quote}, e.g. "USDJPY" -> {"USD","JPY"}
   //   starts with "XAU"/"XAG"  -> {"USD"}
   //   anything else (NAS100 / indices) -> {"USD"}
   // Returns the count written to `out`.
   static int    CurrenciesForSymbol(const string canonical, string &out[]);

   // filter_str (case-insensitive): "high" -> HIGH only; "medium+" or "medium" -> HIGH|MODERATE;
   // "all" -> HIGH|MODERATE|LOW; anything else -> treated as "high". NONE never passes.
   static bool   ImpactPasses(const ENUM_CALENDAR_EVENT_IMPORTANCE imp, const string filter_str);

   // true iff event_time in [now - before_min*60, now + after_min*60] (inclusive both ends).
   static bool   IsWithinBlackout(const datetime event_time, const datetime now,
                                  const int before_min, const int after_min);

   //--- live (integration-tested via the EA, not unit-tested) ---
   // true => block new entries right now for `canonical`. `reason` is set when blocked.
   // enabled==false -> false. MQLInfoInteger(MQL_TESTER) -> false (logs once). API failure -> false (logs).
   static bool   IsBlocked(const string canonical, const datetime now,
                           const bool enabled, const string impact_filter,
                           const int before_min, const int after_min, string &reason);
  };

//+------------------------------------------------------------------+
//| Map canonical symbol to relevant blocking currencies.            |
//| FX 6-char alpha: {base, quote}. XAU/XAG metals: {USD}.          |
//| Anything else (NAS100, indices): {USD}.                          |
//+------------------------------------------------------------------+
int CNewsFilter::CurrenciesForSymbol(const string canonical, string &out[])
  {
   string s = canonical;
   StringToUpper(s);
   if(StringLen(s) >= 3 &&
      (StringSubstr(s, 0, 3) == "XAU" || StringSubstr(s, 0, 3) == "XAG"))
     { ArrayResize(out, 1); out[0] = "USD"; return 1; }
   bool fx6 = (StringLen(s) == 6);
   for(int i = 0; fx6 && i < 6; i++)
     { ushort c = StringGetCharacter(s, i); if(c < 'A' || c > 'Z') fx6 = false; }
   if(fx6)
     { ArrayResize(out, 2); out[0] = StringSubstr(s, 0, 3); out[1] = StringSubstr(s, 3, 3); return 2; }
   ArrayResize(out, 1); out[0] = "USD"; return 1;   // NAS100 / other USD-denominated indices
  }

//+------------------------------------------------------------------+
//| Impact tier filter. NONE never passes any tier (spec §4.5).      |
//| Unrecognised filter_str falls through to "high" behaviour.       |
//+------------------------------------------------------------------+
bool CNewsFilter::ImpactPasses(const ENUM_CALENDAR_EVENT_IMPORTANCE imp, const string filter_str)
  {
   string f = filter_str;
   StringToLower(f); StringTrimLeft(f); StringTrimRight(f);
   if(f == "all")
      return (imp == CALENDAR_IMPORTANCE_LOW ||
              imp == CALENDAR_IMPORTANCE_MODERATE ||
              imp == CALENDAR_IMPORTANCE_HIGH);
   if(f == "medium+" || f == "medium")
      return (imp == CALENDAR_IMPORTANCE_MODERATE || imp == CALENDAR_IMPORTANCE_HIGH);
   return (imp == CALENDAR_IMPORTANCE_HIGH);   // "high" and any unrecognised value
  }

//+------------------------------------------------------------------+
//| True iff event_time falls in [now-before_min*60, now+after_min*60]|
//| (inclusive on both ends, per spec §4.5).                         |
//+------------------------------------------------------------------+
bool CNewsFilter::IsWithinBlackout(const datetime event_time, const datetime now,
                                   const int before_min, const int after_min)
  {
   return (event_time >= now - ((datetime)before_min * 60)) &&
          (event_time <= now + ((datetime)after_min  * 60));
  }

//+------------------------------------------------------------------+
//| Live gate: queries MT5 economic calendar for the blackout window. |
//| Fail-open: any API error or empty result returns false.          |
//| Strategy Tester: calendar unavailable — returns false, logs once. |
//+------------------------------------------------------------------+
bool CNewsFilter::IsBlocked(const string canonical, const datetime now,
                            const bool enabled, const string impact_filter,
                            const int before_min, const int after_min, string &reason)
  {
   reason = "";
   if(!enabled) return false;
   if(MQLInfoInteger(MQL_TESTER))
     {
      static bool logged_tester = false;
      if(!logged_tester)
        {
         Print("CNewsFilter: Strategy Tester detected - news filter disabled for this run.");
         logged_tester = true;
        }
      return false;
     }

   string ccy[];
   const int nccy = CurrenciesForSymbol(canonical, ccy);

   const datetime from = now - ((datetime)before_min * 60);
   const datetime to   = now + ((datetime)after_min  * 60);
   MqlCalendarValue values[];
   const int nv = CalendarValueHistory(values, from, to);   // all countries; window IS the blackout
   if(nv < 0)                                                // genuine API error
      PrintFormat("CNewsFilter: CalendarValueHistory error, ret=%d err=%d (fail-open, not blocking)", nv, GetLastError());
   if(nv <= 0) return false;                                 // error OR clean "no events" — either way, don't block

   for(int i = 0; i < nv; i++)
     {
      if(!IsWithinBlackout(values[i].time, now, before_min, after_min)) continue;   // belt-and-braces

      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(!ImpactPasses(ev.importance, impact_filter)) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(ev.country_id, country)) continue;

      bool relevant = false;
      for(int k = 0; k < nccy; k++)
         if(country.currency == ccy[k]) { relevant = true; break; }
      if(!relevant) continue;

      reason = StringFormat("news: %s %s at %s (impact=%d)",
                            country.currency, ev.name,
                            TimeToString(values[i].time, TIME_DATE | TIME_MINUTES),
                            (int)ev.importance);
      return true;
     }
   return false;
  }

#endif // ALLIGATOR_HA_NEWS_FILTER_MQH
//+------------------------------------------------------------------+
