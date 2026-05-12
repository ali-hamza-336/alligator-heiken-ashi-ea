//+------------------------------------------------------------------+
//|  Test_SymbolResolver.mq5                                         |
//|  Phase 1 unit tests for CSV parser inside SymbolResolver.mqh.    |
//|  Broker-probe behavior (ResolveAll) is integration-tested via    |
//|  attaching the EA to a chart, not here.                          |
//+------------------------------------------------------------------+
#property copyright "Phase 1 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\SymbolResolver.mqh"

int g_passed = 0;
int g_failed = 0;

void Assert(const bool cond, const string label)
{
   if(cond) { g_passed++; PrintFormat("  PASS: %s", label); }
   else     { g_failed++; PrintFormat("  FAIL: %s", label); }
}

void AssertEqInt(const long got, const long expected, const string label)
{
   if(got == expected) { g_passed++; PrintFormat("  PASS: %s", label); }
   else { g_failed++; PrintFormat("  FAIL: %s  expected=%I64d got=%I64d", label, expected, got); }
}

void AssertEqStr(const string got, const string expected, const string label)
{
   if(got == expected) { g_passed++; PrintFormat("  PASS: %s", label); }
   else { g_failed++; PrintFormat("  FAIL: %s  expected='%s' got='%s'", label, expected, got); }
}

//+------------------------------------------------------------------+
void Test_ParseStandard()
{
   Print("[Test_ParseStandard]");
   CSymbolResolver r;
   string out[];
   int n = r.ParseCsv("EURUSD,GBPUSD,XAUUSD", out);
   AssertEqInt(n, 3, "count==3 for three symbols");
   if(n == 3)
     {
      AssertEqStr(out[0], "EURUSD", "out[0]");
      AssertEqStr(out[1], "GBPUSD", "out[1]");
      AssertEqStr(out[2], "XAUUSD", "out[2]");
     }
}

void Test_ParseWhitespace()
{
   Print("[Test_ParseWhitespace]");
   CSymbolResolver r;
   string out[];
   int n = r.ParseCsv("  EURUSD ,  GBPUSD  ", out);
   AssertEqInt(n, 2, "count==2 with surrounding whitespace");
   if(n == 2)
     {
      AssertEqStr(out[0], "EURUSD", "trimmed out[0]");
      AssertEqStr(out[1], "GBPUSD", "trimmed out[1]");
     }
}

void Test_ParseEmpty()
{
   Print("[Test_ParseEmpty]");
   CSymbolResolver r;
   string out[];
   int n = r.ParseCsv("", out);
   AssertEqInt(n, 0, "empty string => count==0");
}

void Test_ParseSingle()
{
   Print("[Test_ParseSingle]");
   CSymbolResolver r;
   string out[];
   int n = r.ParseCsv("EURUSD", out);
   AssertEqInt(n, 1, "single token => count==1");
   if(n >= 1) AssertEqStr(out[0], "EURUSD", "single out[0]");
}

void Test_ParseSkipsEmptyTokens()
{
   Print("[Test_ParseSkipsEmptyTokens]");
   CSymbolResolver r;
   string out[];
   // Trailing comma + double comma should be skipped, not produce empty entries.
   int n = r.ParseCsv("EURUSD,,GBPUSD,", out);
   AssertEqInt(n, 2, "double-comma + trailing-comma => 2 valid tokens");
   if(n == 2)
     {
      AssertEqStr(out[0], "EURUSD", "skip-empty out[0]");
      AssertEqStr(out[1], "GBPUSD", "skip-empty out[1]");
     }
}

void Test_ParseFullDefaultList()
{
   Print("[Test_ParseFullDefaultList]");
   CSymbolResolver r;
   string out[];
   int n = r.ParseCsv("EURUSD,GBPUSD,USDJPY,USDCHF,AUDUSD,USDCAD,NZDUSD,XAUUSD,NAS100", out);
   AssertEqInt(n, 9, "spec default list parses to 9 symbols");
   if(n == 9)
     {
      AssertEqStr(out[0], "EURUSD", "default out[0]");
      AssertEqStr(out[7], "XAUUSD", "default out[7]");
      AssertEqStr(out[8], "NAS100", "default out[8]");
     }
}

//+------------------------------------------------------------------+
void OnStart()
{
   Print("===== SymbolResolver test suite (CSV parser only) =====");
   Test_ParseStandard();
   Test_ParseWhitespace();
   Test_ParseEmpty();
   Test_ParseSingle();
   Test_ParseSkipsEmptyTokens();
   Test_ParseFullDefaultList();
   PrintFormat("===== Done.  passed=%d  failed=%d =====", g_passed, g_failed);
}
//+------------------------------------------------------------------+
