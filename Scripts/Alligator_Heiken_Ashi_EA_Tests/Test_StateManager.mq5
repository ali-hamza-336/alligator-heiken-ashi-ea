//+------------------------------------------------------------------+
//|  Test_StateManager.mq5                                           |
//|  Phase 1 unit tests for Include/StateManager.mqh                 |
//|  Run: drag onto any chart in MT5. Output prints to Experts log.  |
//+------------------------------------------------------------------+
#property copyright "Phase 1 test harness"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "..\..\Experts\Alligator_Heiken_Ashi_EA\Include\StateManager.mqh"

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

void AssertEqDbl(const double got, const double expected, const double tol, const string label)
{
   if(MathAbs(got - expected) <= tol) { g_passed++; PrintFormat("  PASS: %s", label); }
   else { g_failed++; PrintFormat("  FAIL: %s  expected=%.6f got=%.6f", label, expected, got); }
}

//+------------------------------------------------------------------+
//| Test 1: InitDefault produces fresh-state values                   |
//+------------------------------------------------------------------+
void Test_InitDefault()
{
   Print("[Test_InitDefault]");
   CStateManager mgr;
   EAState s;
   mgr.InitDefault(s);
   AssertEqInt(s.streak_position,    1, "default streak_position == 1");
   Assert(s.current_cycle_id == "",     "default cycle_id empty");
   Assert(s.tp_hit_in_cycle == false,   "default tp_hit_in_cycle false");
   AssertEqDbl(s.daily_loss_pct, 0.0, 1e-9, "default daily_loss_pct == 0");
   AssertEqInt(s.last_sl_count,      0, "default last_sl_count == 0");
   AssertEqInt(s.trades_taken_today, 0, "default trades_taken_today == 0");
   AssertEqInt((long)s.open_trade_ticket, 0, "default open_trade_ticket == 0");
   Assert(s.initial_balance == 0.0, "InitDefault zeros initial_balance");
   Assert(s.partial_done == false, "InitDefault zeros partial_done");
   AssertEqInt((long)s.be_move_time, 0, "InitDefault zeros be_move_time");
}

//+------------------------------------------------------------------+
//| Test 2: Save then Load roundtrip preserves all fields             |
//+------------------------------------------------------------------+
void Test_Roundtrip()
{
   Print("[Test_Roundtrip]");
   CStateManager mgr;
   const string fname = "test_state_roundtrip.json";
   mgr.Delete(fname);

   EAState w;
   w.streak_position     = 2;
   w.current_cycle_id    = "20260503_NY";
   w.tp_hit_in_cycle     = false;
   w.daily_loss_pct      = 0.45;
   w.daily_loss_date     = "2026-05-03";
   w.last_sl_count       = 2;
   w.trades_taken_today  = 2;
   w.open_trade_ticket   = 12345678;
   w.open_trade_cycle_id = "20260503_NY";
   w.initial_balance     = 12345.67;
   w.partial_done        = true;
   w.be_move_time        = D'2026.05.10 16:30:00';
   w.last_save_time      = D'2026.05.03 14:30:00';

   Assert(mgr.Save(w, fname), "Save returns true");
   Assert(mgr.FileExists(fname), "file exists after Save");

   EAState r;
   Assert(mgr.Load(r, fname), "Load returns true");
   AssertEqInt(r.streak_position,    2, "roundtrip streak_position");
   AssertEqStr(r.current_cycle_id,   "20260503_NY", "roundtrip cycle_id");
   Assert(r.tp_hit_in_cycle == false, "roundtrip tp_hit_in_cycle");
   AssertEqDbl(r.daily_loss_pct, 0.45, 1e-6, "roundtrip daily_loss_pct");
   AssertEqStr(r.daily_loss_date,    "2026-05-03", "roundtrip daily_loss_date");
   AssertEqInt(r.last_sl_count,      2, "roundtrip last_sl_count");
   AssertEqInt(r.trades_taken_today, 2, "roundtrip trades_taken_today");
   AssertEqInt((long)r.open_trade_ticket, 12345678, "roundtrip open_trade_ticket");
   AssertEqStr(r.open_trade_cycle_id, "20260503_NY", "roundtrip open_trade_cycle_id");
   AssertEqDbl(r.initial_balance, 12345.67, 0.005, "initial_balance roundtrip");
   Assert(r.partial_done == true, "partial_done roundtrip");
   AssertEqInt((long)r.be_move_time, (long)w.be_move_time, "be_move_time roundtrip");
   AssertEqInt((long)r.last_save_time, (long)w.last_save_time, "roundtrip last_save_time");

   mgr.Delete(fname);
}

//+------------------------------------------------------------------+
//| Test 3: Load on missing file returns false + default state       |
//+------------------------------------------------------------------+
void Test_LoadMissing()
{
   Print("[Test_LoadMissing]");
   CStateManager mgr;
   const string fname = "test_state_does_not_exist_xyz.json";
   mgr.Delete(fname);

   EAState s;
   s.streak_position = 99; // poison value
   bool ok = mgr.Load(s, fname);
   Assert(!ok, "Load returns false for missing file");
   AssertEqInt(s.streak_position, 1, "state reset to default after missing load");
}

//+------------------------------------------------------------------+
//| Test 4: Load on corrupted file returns false + default state     |
//+------------------------------------------------------------------+
void Test_LoadCorrupt()
{
   Print("[Test_LoadCorrupt]");
   CStateManager mgr;
   const string fname = "test_state_corrupt.json";
   mgr.Delete(fname);

   // Write garbage
   int h = FileOpen(fname, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h == INVALID_HANDLE) { g_failed++; Print("  FAIL: could not create corrupt fixture"); return; }
   FileWriteString(h, "this is not valid json {{{");
   FileClose(h);

   EAState s;
   s.streak_position = 99;
   bool ok = mgr.Load(s, fname);
   Assert(!ok, "Load returns false for corrupted file");
   AssertEqInt(s.streak_position, 1, "state reset to default after corrupt load");

   mgr.Delete(fname);
}

//+------------------------------------------------------------------+
//| Test 5: Atomic write leaves no leftover .tmp                     |
//+------------------------------------------------------------------+
void Test_AtomicWriteCleanup()
{
   Print("[Test_AtomicWriteCleanup]");
   CStateManager mgr;
   const string fname = "test_state_atomic.json";
   const string tmp   = "test_state_atomic.json.tmp";
   mgr.Delete(fname);
   mgr.Delete(tmp);

   EAState w;
   mgr.InitDefault(w);
   w.streak_position = 3;
   Assert(mgr.Save(w, fname), "Save returns true");
   Assert(mgr.FileExists(fname), "final file exists");
   Assert(!mgr.FileExists(tmp),  "no leftover .tmp file");

   mgr.Delete(fname);
}

//+------------------------------------------------------------------+
//| Test 6: Save twice replaces previous content                     |
//+------------------------------------------------------------------+
void Test_SaveOverwrite()
{
   Print("[Test_SaveOverwrite]");
   CStateManager mgr;
   const string fname = "test_state_overwrite.json";
   mgr.Delete(fname);

   EAState a; mgr.InitDefault(a); a.streak_position = 1;
   EAState b; mgr.InitDefault(b); b.streak_position = 3;
   mgr.Save(a, fname);
   mgr.Save(b, fname);

   EAState r;
   Assert(mgr.Load(r, fname), "Load after overwrite");
   AssertEqInt(r.streak_position, 3, "second save wins");

   mgr.Delete(fname);
}

//+------------------------------------------------------------------+
//| Test 7: Load on JSON missing Stage-2 optional fields keeps        |
//| defaults and still returns true (legacy-tolerant pattern,         |
//| mirrors Phase-7 initial_balance behaviour)                        |
//+------------------------------------------------------------------+
void Test_LoadLegacyMissingFields()
{
   Print("[Test_LoadLegacyMissingFields]");
   CStateManager mgr;
   const string fname = "test_state_legacy_missing.json";
   mgr.Delete(fname);

   // Hand-rolled fixture: all original fields present, partial_done +
   // be_move_time omitted entirely (pre-Stage-2 file shape).
   const string body =
      "{\n"
      "  \"streak_position\": 2,\n"
      "  \"current_cycle_id\": \"20260503_NY\",\n"
      "  \"tp_hit_in_cycle\": false,\n"
      "  \"daily_loss_pct\": 0.450000,\n"
      "  \"daily_loss_date\": \"2026-05-03\",\n"
      "  \"last_sl_count\": 2,\n"
      "  \"trades_taken_today\": 2,\n"
      "  \"open_trade_ticket\": 12345678,\n"
      "  \"open_trade_cycle_id\": \"20260503_NY\",\n"
      "  \"initial_balance\": 12345.67,\n"
      "  \"last_save_time\": \"2026-05-03T14:30:00Z\"\n"
      "}\n";
   int h = FileOpen(fname, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h == INVALID_HANDLE) { g_failed++; Print("  FAIL: could not create legacy fixture"); return; }
   FileWriteString(h, body);
   FileClose(h);

   EAState r;
   Assert(mgr.Load(r, fname), "Load returns true for legacy JSON missing Stage-2 fields");
   AssertEqInt(r.streak_position, 2, "legacy: required field streak_position roundtrips");
   Assert(r.partial_done == false, "legacy: missing partial_done stays false");
   AssertEqInt((long)r.be_move_time, 0, "legacy: missing be_move_time stays 0");

   mgr.Delete(fname);
}

//+------------------------------------------------------------------+
//| Script entry                                                     |
//+------------------------------------------------------------------+
void OnStart()
{
   Print("===== StateManager test suite =====");
   Test_InitDefault();
   Test_Roundtrip();
   Test_LoadMissing();
   Test_LoadCorrupt();
   Test_AtomicWriteCleanup();
   Test_SaveOverwrite();
   Test_LoadLegacyMissingFields();
   PrintFormat("===== Done.  passed=%d  failed=%d =====", g_passed, g_failed);
}
//+------------------------------------------------------------------+
