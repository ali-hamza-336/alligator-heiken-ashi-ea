//+------------------------------------------------------------------+
//|  SessionManager.mqh                                              |
//|  Phase 6 — pure session-window predicates + IsTradingAllowed     |
//|  composer. NY-local time only; caller converts via CSessionTime. |
//|                                                                  |
//|  Spec: §5.1, §5.2, §5.3, §5.7.                                   |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_SESSION_MANAGER_MQH
#define ALLIGATOR_HA_SESSION_MANAGER_MQH

#include "StreakManager.mqh"   // for ETradingMode

struct TradeAllowResult
  {
   bool              allowed;
   string            reason;
  };

class CSessionManager
  {
public:
   static bool       IsInNYWindow      (const int ny_weekday, const int ny_hour,
                                         const int ny_start, const int ny_end);
   static bool       IsInTokyoWindow   (const int ny_weekday, const int ny_hour);
   static bool       IsInLondonWindow  (const int ny_weekday, const int ny_hour);
   static bool       IsAnySessionWindow(const int ny_weekday, const int ny_hour,
                                         const int ny_start, const int ny_end);
   static bool       IsFridayCloseTime (const int ny_weekday, const int ny_hour,
                                         const int friday_close_hour);

   static TradeAllowResult IsTradingAllowed(const ETradingMode mode,
                                             const int ny_weekday, const int ny_hour,
                                             const int ny_start, const int ny_end,
                                             const int friday_close_hour);
  };

//+------------------------------------------------------------------+
//| §5.1: NY 08:00 – 15:00 weekdays (Mon..Fri = 1..5).               |
//+------------------------------------------------------------------+
bool CSessionManager::IsInNYWindow(const int ny_weekday, const int ny_hour,
                                   const int ny_start, const int ny_end)
  {
   if(ny_weekday < 1 || ny_weekday > 5) return false;
   return ny_hour >= ny_start && ny_hour < ny_end;
  }

//+------------------------------------------------------------------+
//| §5.1: Tokyo 19:00 (prev day) – 04:00 NY. Treats the 19-23 chunk  |
//| of the previous NY weekday and the 0-4 chunk of the current as   |
//| "Tokyo session".                                                  |
//+------------------------------------------------------------------+
bool CSessionManager::IsInTokyoWindow(const int ny_weekday, const int ny_hour)
  {
   if(ny_weekday >= 1 && ny_weekday <= 5)
     {
      if(ny_hour >= 19) return true;
      if(ny_hour < 4)   return true;
     }
   if(ny_weekday == 0 && ny_hour >= 19) return true;       // Sun evening = Mon Tokyo
   return false;
  }

//+------------------------------------------------------------------+
//| §5.1: London 03:00 – 12:00 NY. Weekdays only.                    |
//+------------------------------------------------------------------+
bool CSessionManager::IsInLondonWindow(const int ny_weekday, const int ny_hour)
  {
   if(ny_weekday < 1 || ny_weekday > 5) return false;
   return ny_hour >= 3 && ny_hour < 12;
  }

//+------------------------------------------------------------------+
//| Recovery-mode window = NY ∪ London ∪ Tokyo.                      |
//+------------------------------------------------------------------+
bool CSessionManager::IsAnySessionWindow(const int ny_weekday, const int ny_hour,
                                         const int ny_start, const int ny_end)
  {
   if(IsInNYWindow    (ny_weekday, ny_hour, ny_start, ny_end)) return true;
   if(IsInLondonWindow(ny_weekday, ny_hour))                   return true;
   if(IsInTokyoWindow (ny_weekday, ny_hour))                   return true;
   return false;
  }

//+------------------------------------------------------------------+
//| §5.7: Friday close hour reached (NY local).                      |
//+------------------------------------------------------------------+
bool CSessionManager::IsFridayCloseTime(const int ny_weekday, const int ny_hour,
                                        const int friday_close_hour)
  {
   return ny_weekday == 5 && ny_hour >= friday_close_hour;
  }

//+------------------------------------------------------------------+
//| Composer. Reason strings are stable so log-grepping by Phase-6   |
//| reason works downstream.                                          |
//+------------------------------------------------------------------+
TradeAllowResult CSessionManager::IsTradingAllowed(const ETradingMode mode,
                                                   const int ny_weekday, const int ny_hour,
                                                   const int ny_start, const int ny_end,
                                                   const int friday_close_hour)
  {
   TradeAllowResult r;
   r.allowed = false;
   r.reason  = "";

   if(IsFridayCloseTime(ny_weekday, ny_hour, friday_close_hour))
     { r.reason = StringFormat("session: Friday close hour %02d:00 NY", ny_hour); return r; }

   if(mode == MODE_LOCKED)
     { r.reason = "session: cycle locked (TP or 3-SL)"; return r; }

   if(mode == MODE_DEFAULT)
     {
      if(IsInNYWindow(ny_weekday, ny_hour, ny_start, ny_end))
        { r.allowed = true; r.reason = "session: default NY window"; return r; }
      r.reason = StringFormat("session: default mode, outside NY window dow=%d hr=%02d",
                              ny_weekday, ny_hour);
      return r;
     }

   //--- MODE_RECOVERY
   if(IsAnySessionWindow(ny_weekday, ny_hour, ny_start, ny_end))
     { r.allowed = true; r.reason = "session: recovery (any session)"; return r; }
   r.reason = StringFormat("session: recovery, outside any session dow=%d hr=%02d",
                           ny_weekday, ny_hour);
   return r;
  }

#endif // ALLIGATOR_HA_SESSION_MANAGER_MQH
//+------------------------------------------------------------------+
