//+------------------------------------------------------------------+
//|  Test_SessionTime.mq5                                            |
//|  Phase 6 unit tests for ServerToNY + DST conversion helpers.     |
//|  Phase 6 has DST helpers shipped; Phase 5 fixed-offset cases     |
//|  preserved below.                                                 |
//+------------------------------------------------------------------+
#property copyright "Phase 6 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\SessionTime.mqh"

int g_passed = 0;
int g_failed = 0;

void Assert(const bool cond, const string label)
{
   if(cond) { g_passed++; PrintFormat("  PASS: %s", label); }
   else     { g_failed++; PrintFormat("  FAIL: %s", label); }
}
void AssertEqStr(const string got, const string exp, const string label)
{
   if(got == exp) { g_passed++; PrintFormat("  PASS: %s", label); }
   else { g_failed++; PrintFormat("  FAIL: %s exp='%s' got='%s'", label, exp, got); }
}
void AssertEqInt(const int got, const int exp, const string label)
{
   if(got == exp) { g_passed++; PrintFormat("  PASS: %s", label); }
   else { g_failed++; PrintFormat("  FAIL: %s exp=%d got=%d", label, exp, got); }
}

datetime MakeDt(int y, int m, int d, int h, int mi)
{
   MqlDateTime mdt; ZeroMemory(mdt);
   mdt.year=y; mdt.mon=m; mdt.day=d; mdt.hour=h; mdt.min=mi;
   return StructToTime(mdt);
}

//==================================================================
// ServerToNY — fixed-offset cases (Phase 6 DST helpers tested below).
//==================================================================
void Test_ServerToNY_BasicShift()
{
   Print("[Test_ServerToNY_BasicShift]");
   //  Server = 2026-05-08 14:00 (CEST = GMT+3 broker), offset_hr = -7
   //  NY     = 2026-05-08 07:00
   const datetime server = MakeDt(2026,5,8,14,0);
   const datetime ny     = CSessionTime::ServerToNY(server, -7);
   const datetime expect = MakeDt(2026,5,8,7,0);
   Assert(ny == expect, "shift -7h: 14:00 -> 07:00 same date");
}
void Test_ServerToNY_DateRollback()
{
   Print("[Test_ServerToNY_DateRollback]");
   //  Server 2026-05-09 03:00 -> NY 2026-05-08 20:00 (date rolls back)
   const datetime server = MakeDt(2026,5,9,3,0);
   AssertEqInt(CSessionTime::NYHour(server, -7), 20, "NY hour after rollback");
   AssertEqStr(CSessionTime::NYDateString(server, -7), "20260508", "NY date after rollback");
}

//==================================================================
// NYDateString / NYWeekday / NYHour
//==================================================================
void Test_NYDateString_Format()
{
   Print("[Test_NYDateString_Format]");
   //  Server 2026-05-08 14:00 + (-7h) -> NY 2026-05-08 07:00
   AssertEqStr(CSessionTime::NYDateString(MakeDt(2026,5,8,14,0), -7),
               "20260508", "YYYYMMDD format");
}
void Test_NYWeekday_Friday()
{
   Print("[Test_NYWeekday_Friday]");
   //  2026-05-08 is a Friday.
   AssertEqInt(CSessionTime::NYWeekday(MakeDt(2026,5,8,14,0), -7), 5, "Friday = 5");
}
void Test_NYWeekday_Sunday()
{
   Print("[Test_NYWeekday_Sunday]");
   //  2026-05-10 is a Sunday.
   AssertEqInt(CSessionTime::NYWeekday(MakeDt(2026,5,10,14,0), -7), 0, "Sunday = 0");
}
void Test_NYHour_Noon()
{
   Print("[Test_NYHour_Noon]");
   //  Server 2026-05-08 19:00 + (-7h) -> NY 12:00
   AssertEqInt(CSessionTime::NYHour(MakeDt(2026,5,8,19,0), -7), 12, "noon NY");
}
void Test_NYHour_AtNYOpen()
{
   Print("[Test_NYHour_AtNYOpen]");
   //  Server 2026-05-08 15:00 + (-7h) -> NY 08:00 (NY open)
   AssertEqInt(CSessionTime::NYHour(MakeDt(2026,5,8,15,0), -7), 8, "NY 08:00 open");
}

//==================================================================
// Phase 6 additions: IsUSInDST / IsBrokerInDST / DeriveOffsetHours
//==================================================================
void Test_USDST_JanWinter()
{
   Print("[Test_USDST_JanWinter]");
   Assert(!CSessionTime::IsUSInDST(2026, 1, 15), "Jan 15 EST");
}
void Test_USDST_JulSummer()
{
   Print("[Test_USDST_JulSummer]");
   Assert(CSessionTime::IsUSInDST(2026, 7, 15), "Jul 15 EDT");
}
void Test_USDST_MarchBoundary()
{
   Print("[Test_USDST_MarchBoundary]");
   //  2026: 1st Sunday Mar = Mar 1; 2nd Sunday = Mar 8 → DST starts Mar 8
   Assert(!CSessionTime::IsUSInDST(2026, 3, 7), "Mar 7 still EST");
   Assert( CSessionTime::IsUSInDST(2026, 3, 8), "Mar 8 EDT (2nd Sun)");
   Assert( CSessionTime::IsUSInDST(2026, 3, 31), "Mar 31 EDT");
   //  2027: 1st Sunday Mar = Mar 7; 2nd Sunday = Mar 14 → DST starts Mar 14
   //  Exercises the first_sunday=7 max case the 2026 tests can't reach.
   Assert(!CSessionTime::IsUSInDST(2027, 3, 13), "Mar 13 still EST (2027)");
   Assert( CSessionTime::IsUSInDST(2027, 3, 14), "Mar 14 EDT (2027, first_sunday=7)");
}
void Test_USDST_NovemberBoundary()
{
   Print("[Test_USDST_NovemberBoundary]");
   //  2026: 1st Sunday Nov = Nov 1 → DST ends Nov 1
   Assert( CSessionTime::IsUSInDST(2026, 10, 31), "Oct 31 still EDT");
   Assert(!CSessionTime::IsUSInDST(2026, 11, 1),  "Nov 1 EST (1st Sun)");
   Assert(!CSessionTime::IsUSInDST(2026, 11, 30), "Nov 30 EST");
}
void Test_BrokerDST_JanWinter()
{
   Print("[Test_BrokerDST_JanWinter]");
   Assert(!CSessionTime::IsBrokerInDST(2026, 1, 15), "Jan 15 CET");
}
void Test_BrokerDST_JulSummer()
{
   Print("[Test_BrokerDST_JulSummer]");
   Assert(CSessionTime::IsBrokerInDST(2026, 7, 15), "Jul 15 CEST");
}
void Test_BrokerDST_MarchBoundary()
{
   Print("[Test_BrokerDST_MarchBoundary]");
   //  2026: last Sunday Mar = Mar 29 → CEST starts Mar 29
   Assert(!CSessionTime::IsBrokerInDST(2026, 3, 28), "Mar 28 still CET");
   Assert( CSessionTime::IsBrokerInDST(2026, 3, 29), "Mar 29 CEST");
}
void Test_BrokerDST_OctoberBoundary()
{
   Print("[Test_BrokerDST_OctoberBoundary]");
   //  2026: last Sunday Oct = Oct 25 → CEST ends Oct 25
   Assert( CSessionTime::IsBrokerInDST(2026, 10, 24), "Oct 24 still CEST");
   Assert(!CSessionTime::IsBrokerInDST(2026, 10, 25), "Oct 25 CET");
}
void Test_DeriveOffset_SummerCEST()
{
   Print("[Test_DeriveOffset_SummerCEST]");
   //  2026-07-15: broker GMT+3 (CEST), US in EDT (-4)  →  offset = -4 - 3 = -7
   AssertEqInt(CSessionTime::DeriveOffsetHours(MakeDt(2026,7,15,12,0), 3),
               -7, "summer CEST broker → EDT NY = -7");
}
void Test_DeriveOffset_WinterCET()
{
   Print("[Test_DeriveOffset_WinterCET]");
   //  2026-01-15: broker GMT+2 (CET), US in EST (-5)  →  offset = -5 - 2 = -7
   AssertEqInt(CSessionTime::DeriveOffsetHours(MakeDt(2026,1,15,12,0), 2),
               -7, "winter CET broker → EST NY = -7");
}
void Test_DeriveOffset_SpringMismatch()
{
   Print("[Test_DeriveOffset_SpringMismatch]");
   //  2026-03-10: US already in EDT (after Mar 8), EU still in CET → broker GMT+2,
   //  US -4. Offset = -4 - 2 = -6 (one of the brief mismatch windows).
   AssertEqInt(CSessionTime::DeriveOffsetHours(MakeDt(2026,3,10,12,0), 2),
               -6, "US-already-EDT, broker-still-CET → -6");
}

void OnStart()
{
   g_passed = 0; g_failed = 0;
   Test_ServerToNY_BasicShift();
   Test_ServerToNY_DateRollback();
   Test_NYDateString_Format();
   Test_NYWeekday_Friday();
   Test_NYWeekday_Sunday();
   Test_NYHour_Noon();
   Test_NYHour_AtNYOpen();
   Test_USDST_JanWinter();
   Test_USDST_JulSummer();
   Test_USDST_MarchBoundary();
   Test_USDST_NovemberBoundary();
   Test_BrokerDST_JanWinter();
   Test_BrokerDST_JulSummer();
   Test_BrokerDST_MarchBoundary();
   Test_BrokerDST_OctoberBoundary();
   Test_DeriveOffset_SummerCEST();
   Test_DeriveOffset_WinterCET();
   Test_DeriveOffset_SpringMismatch();
   PrintFormat("===== Done. passed=%d failed=%d =====", g_passed, g_failed);
}
