//+------------------------------------------------------------------+
//|  SessionTime.mqh                                                 |
//|  Centralized server-time -> NY-local conversion (invariant #6).  |
//|  Phase 6: DST-aware. Existing 2-arg signatures kept stable —     |
//|  callers pass an auto-derived offset.                            |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_SESSION_TIME_MQH
#define ALLIGATOR_HA_SESSION_TIME_MQH

class CSessionTime
  {
public:
   static datetime   ServerToNY     (const datetime server_time, const int offset_hr);
   static string     NYDateString   (const datetime server_time, const int offset_hr);
   static int        NYWeekday      (const datetime server_time, const int offset_hr);
   static int        NYHour         (const datetime server_time, const int offset_hr);
   static bool       IsUSInDST      (const int year, const int month, const int day);
   static bool       IsBrokerInDST  (const int year, const int month, const int day);
   static int        DeriveOffsetHours(const datetime server_dt,
                                       const int broker_gmt_offset_hr);
  };

//+------------------------------------------------------------------+
//| ServerToNY: simple offset addition. Caller passes the offset in  |
//| via DeriveOffsetHours(server_dt, broker_gmt_offset_hr).          |
//+------------------------------------------------------------------+
datetime CSessionTime::ServerToNY(const datetime server_time, const int offset_hr)
  {
   return server_time + (datetime)(offset_hr * 3600);
  }

string CSessionTime::NYDateString(const datetime server_time, const int offset_hr)
  {
   const datetime ny = ServerToNY(server_time, offset_hr);
   MqlDateTime mdt; TimeToStruct(ny, mdt);
   return StringFormat("%04d%02d%02d", mdt.year, mdt.mon, mdt.day);
  }

int CSessionTime::NYWeekday(const datetime server_time, const int offset_hr)
  {
   const datetime ny = ServerToNY(server_time, offset_hr);
   MqlDateTime mdt; TimeToStruct(ny, mdt);
   return mdt.day_of_week;
  }

int CSessionTime::NYHour(const datetime server_time, const int offset_hr)
  {
   const datetime ny = ServerToNY(server_time, offset_hr);
   MqlDateTime mdt; TimeToStruct(ny, mdt);
   return mdt.hour;
  }

//+------------------------------------------------------------------+
//| US DST: 2nd Sunday of March → 1st Sunday of November (post-2007).|
//| Pure calendar math — no MT5 API. day_of_week: 0=Sun..6=Sat.      |
//+------------------------------------------------------------------+
bool CSessionTime::IsUSInDST(const int year, const int month, const int day)
  {
   if(month < 3 || month > 11) return false;
   if(month > 3 && month < 11) return true;

   MqlDateTime mdt; ZeroMemory(mdt);
   mdt.year = year; mdt.mon = month; mdt.day = 1;
   const datetime first_of_month = StructToTime(mdt);
   MqlDateTime f; TimeToStruct(first_of_month, f);
   const int first_sunday = 1 + ((7 - f.day_of_week) % 7);

   if(month == 3) return day >= first_sunday + 7;   // 2nd Sunday
   /* month == 11 */ return day < first_sunday;     // before 1st Sunday
  }

//+------------------------------------------------------------------+
//| EU DST: last Sunday March → last Sunday October. Used for the    |
//| broker's local time when broker tracks EU/CET DST. Caller can    |
//| pass result into DeriveOffsetHours as broker_gmt_offset_hr base. |
//+------------------------------------------------------------------+
bool CSessionTime::IsBrokerInDST(const int year, const int month, const int day)
  {
   if(month < 3 || month > 10) return false;
   if(month > 3 && month < 10) return true;

   MqlDateTime mdt; ZeroMemory(mdt);
   mdt.year = year; mdt.mon = month;
   mdt.day = 31;                          // probe end of month (March/October both have 31 days)
   const datetime probe = StructToTime(mdt);
   MqlDateTime p; TimeToStruct(probe, p);
   const int last_sunday = 31 - p.day_of_week;

   if(month == 3)  return day >= last_sunday;
   /* month == 10 */ return day < last_sunday;
  }

//+------------------------------------------------------------------+
//| DeriveOffsetHours — caller-provided broker GMT offset + server   |
//| date drives target. NY = -5 (EST) or -4 (EDT). Result = NY_off - |
//| broker_gmt_offset. Pure — no MT5 API except calendar math.       |
//+------------------------------------------------------------------+
int CSessionTime::DeriveOffsetHours(const datetime server_dt,
                                    const int broker_gmt_offset_hr)
  {
   MqlDateTime s; TimeToStruct(server_dt, s);
   const int ny_off = IsUSInDST(s.year, s.mon, s.day) ? -4 : -5;
   return ny_off - broker_gmt_offset_hr;
  }

#endif // ALLIGATOR_HA_SESSION_TIME_MQH
//+------------------------------------------------------------------+
