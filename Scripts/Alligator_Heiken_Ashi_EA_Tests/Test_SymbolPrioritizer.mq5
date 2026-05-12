//+------------------------------------------------------------------+
//|  Test_SymbolPrioritizer.mq5                                      |
//|  Phase 3 unit tests for CSymbolPrioritizer::RankByADX (pure).    |
//|  Live `Snapshot` wrapper is integration-tested via the EA.       |
//+------------------------------------------------------------------+
#property copyright "Phase 3 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\SymbolPrioritizer.mqh"

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
void Test_Rank_BasicSort()
{
   Print("[Test_Rank_BasicSort]");
   ADXSnapshot in[3];
   in[0].sym="A"; in[0].adx=15.0; in[0].valid=true;
   in[1].sym="B"; in[1].adx=28.0; in[1].valid=true;
   in[2].sym="C"; in[2].adx=22.0; in[2].valid=true;
   ADXSnapshot out[];
   const int above = CSymbolPrioritizer::RankByADX(in, 3, 20.0, out);
   AssertEqInt(above, 2, "two symbols above 20.0");
   AssertEqStr(out[0].sym, "B", "highest first");
   AssertEqStr(out[1].sym, "C", "second highest second");
   AssertEqStr(out[2].sym, "A", "low ADX last");
}

void Test_Rank_AllBelow()
{
   Print("[Test_Rank_AllBelow]");
   ADXSnapshot in[2];
   in[0].sym="A"; in[0].adx=10.0; in[0].valid=true;
   in[1].sym="B"; in[1].adx=12.0; in[1].valid=true;
   ADXSnapshot out[];
   const int above = CSymbolPrioritizer::RankByADX(in, 2, 20.0, out);
   AssertEqInt(above, 0, "no symbol passes");
}

void Test_Rank_InvalidSnapshotsRankLast()
{
   Print("[Test_Rank_InvalidSnapshotsRankLast]");
   ADXSnapshot in[3];
   in[0].sym="A"; in[0].adx=30.0; in[0].valid=false; // no data
   in[1].sym="B"; in[1].adx=22.0; in[1].valid=true;
   in[2].sym="C"; in[2].adx=25.0; in[2].valid=true;
   ADXSnapshot out[];
   const int above = CSymbolPrioritizer::RankByADX(in, 3, 20.0, out);
   AssertEqInt(above, 2, "invalid excluded from above-min count");
   AssertEqStr(out[0].sym, "C", "valid 25 first");
   AssertEqStr(out[1].sym, "B", "valid 22 second");
}

//+------------------------------------------------------------------+
void OnStart()
{
   Print("===== Test_SymbolPrioritizer =====");

   Test_Rank_BasicSort();
   Test_Rank_AllBelow();
   Test_Rank_InvalidSnapshotsRankLast();

   PrintFormat("===== Done. passed=%d failed=%d =====", g_passed, g_failed);
}
//+------------------------------------------------------------------+
