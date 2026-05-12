//+------------------------------------------------------------------+
//|  StateManager.mqh                                                |
//|  Persistent EA state — atomic JSON read/write to MQL5/Files/     |
//|                                                                  |
//|  Spec: EA_Action_Plan.md §8.1 (schema), §8.4 (recovery)          |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_STATE_MANAGER_MQH
#define ALLIGATOR_HA_STATE_MANAGER_MQH

//--- Persistent state schema (matches spec §8.1)
struct EAState
  {
   int      streak_position;         // 1, 2, or 3
   string   current_cycle_id;        // "YYYYMMDD_NY"
   bool     tp_hit_in_cycle;
   double   daily_loss_pct;
   string   daily_loss_date;         // "YYYY-MM-DD" CET
   int      last_sl_count;
   int      trades_taken_today;
   ulong    open_trade_ticket;
   string   open_trade_cycle_id;
   double   initial_balance;
   datetime last_save_time;
  };

//+------------------------------------------------------------------+
class CStateManager
  {
public:
   void              InitDefault(EAState &state);
   bool              Save(const EAState &state, const string filename);
   bool              Load(EAState &state, const string filename);
   bool              FileExists(const string filename) const;
   bool              Delete(const string filename);

private:
   string            Serialize(const EAState &state) const;
   bool              ExtractRaw(const string body, const string key, string &out) const;
   bool              ExtractString(const string body, const string key, string &out) const;
   bool              ExtractInt   (const string body, const string key, long   &out) const;
   bool              ExtractULong (const string body, const string key, ulong  &out) const;
   bool              ExtractDouble(const string body, const string key, double &out) const;
   bool              ExtractBool  (const string body, const string key, bool   &out) const;
   string            FormatIsoUtc(const datetime t) const;
   datetime          ParseIsoUtc(const string s) const;
  };

//+------------------------------------------------------------------+
void CStateManager::InitDefault(EAState &state)
  {
   state.streak_position     = 1;
   state.current_cycle_id    = "";
   state.tp_hit_in_cycle     = false;
   state.daily_loss_pct      = 0.0;
   state.daily_loss_date     = "";
   state.last_sl_count       = 0;
   state.trades_taken_today  = 0;
   state.open_trade_ticket   = 0;
   state.open_trade_cycle_id = "";
   state.initial_balance     = 0.0;
   state.last_save_time      = 0;
  }

//+------------------------------------------------------------------+
//| Atomic write: serialize → write to .tmp → FileMove to final.     |
//| Power-loss between the two leaves the previous good file intact. |
//+------------------------------------------------------------------+
bool CStateManager::Save(const EAState &state, const string filename)
  {
   const string tmp = filename + ".tmp";

   // Belt-and-braces: clear any stale .tmp from a prior crash.
   if(FileIsExist(tmp))
      FileDelete(tmp);

   const int h = FileOpen(tmp, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("StateManager.Save: FileOpen failed for %s err=%d", tmp, GetLastError());
      return false;
     }
   FileWriteString(h, Serialize(state));
   FileClose(h);

   // Final atomic step. FileMove with overwrite replaces target in one operation.
   if(FileIsExist(filename))
      FileDelete(filename);
   if(!FileMove(tmp, 0, filename, 0))
     {
      PrintFormat("StateManager.Save: FileMove failed err=%d", GetLastError());
      FileDelete(tmp);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool CStateManager::Load(EAState &state, const string filename)
  {
   InitDefault(state);
   if(!FileIsExist(filename))
      return false;

   const int h = FileOpen(filename, FILE_READ|FILE_TXT|FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("StateManager.Load: FileOpen failed for %s err=%d", filename, GetLastError());
      return false;
     }
   string body = "";
   while(!FileIsEnding(h))
      body += FileReadString(h);
   FileClose(h);

   long   l_int;
   ulong  l_ulong;
   double l_dbl;
   bool   l_bool;
   string l_str;

   if(!ExtractInt   (body, "streak_position",     l_int))   { InitDefault(state); return false; } state.streak_position = (int)l_int;
   if(!ExtractString(body, "current_cycle_id",    l_str))   { InitDefault(state); return false; } state.current_cycle_id = l_str;
   if(!ExtractBool  (body, "tp_hit_in_cycle",     l_bool))  { InitDefault(state); return false; } state.tp_hit_in_cycle = l_bool;
   if(!ExtractDouble(body, "daily_loss_pct",      l_dbl))   { InitDefault(state); return false; } state.daily_loss_pct = l_dbl;
   if(!ExtractString(body, "daily_loss_date",     l_str))   { InitDefault(state); return false; } state.daily_loss_date = l_str;
   if(!ExtractInt   (body, "last_sl_count",       l_int))   { InitDefault(state); return false; } state.last_sl_count = (int)l_int;
   if(!ExtractInt   (body, "trades_taken_today",  l_int))   { InitDefault(state); return false; } state.trades_taken_today = (int)l_int;
   if(!ExtractULong (body, "open_trade_ticket",   l_ulong)) { InitDefault(state); return false; } state.open_trade_ticket = l_ulong;
   if(!ExtractString(body, "open_trade_cycle_id", l_str))   { InitDefault(state); return false; } state.open_trade_cycle_id = l_str;
   if(!ExtractString(body, "last_save_time",      l_str))   { InitDefault(state); return false; } state.last_save_time = ParseIsoUtc(l_str);

   if(ExtractDouble(body, "initial_balance", l_dbl)) state.initial_balance = l_dbl;  // legacy files lack it -> stays 0

   return true;
  }

//+------------------------------------------------------------------+
bool CStateManager::FileExists(const string filename) const
  {
   return FileIsExist(filename);
  }

//+------------------------------------------------------------------+
bool CStateManager::Delete(const string filename)
  {
   if(!FileIsExist(filename))
      return true;
   return FileDelete(filename);
  }

//+------------------------------------------------------------------+
//| Serialize to a fixed-schema JSON. Hand-rolled (no general parser |
//| needed because Load handles only this exact shape).              |
//+------------------------------------------------------------------+
string CStateManager::Serialize(const EAState &state) const
  {
   string s = "{\n";
   s += StringFormat("  \"streak_position\": %d,\n",      state.streak_position);
   s += StringFormat("  \"current_cycle_id\": \"%s\",\n", state.current_cycle_id);
   s += StringFormat("  \"tp_hit_in_cycle\": %s,\n",      state.tp_hit_in_cycle ? "true" : "false");
   s += StringFormat("  \"daily_loss_pct\": %.6f,\n",     state.daily_loss_pct);
   s += StringFormat("  \"daily_loss_date\": \"%s\",\n",  state.daily_loss_date);
   s += StringFormat("  \"last_sl_count\": %d,\n",        state.last_sl_count);
   s += StringFormat("  \"trades_taken_today\": %d,\n",   state.trades_taken_today);
   s += StringFormat("  \"open_trade_ticket\": %I64u,\n", state.open_trade_ticket);
   s += StringFormat("  \"open_trade_cycle_id\": \"%s\",\n", state.open_trade_cycle_id);
   s += StringFormat("  \"initial_balance\": %.2f,\n",       state.initial_balance);
   s += StringFormat("  \"last_save_time\": \"%s\"\n",    FormatIsoUtc(state.last_save_time));
   s += "}\n";
   return s;
  }

//+------------------------------------------------------------------+
//| Find substring `"key":` and return everything after it up to the |
//| next comma or closing brace, trimmed. Returns false if missing.  |
//+------------------------------------------------------------------+
bool CStateManager::ExtractRaw(const string body, const string key, string &out) const
  {
   const string needle = "\"" + key + "\":";
   const int p = StringFind(body, needle, 0);
   if(p < 0) return false;
   int start = p + StringLen(needle);
   const int len = StringLen(body);
   // skip whitespace
   while(start < len)
     {
      const ushort c = StringGetCharacter(body, start);
      if(c == ' ' || c == '\t' || c == '\r' || c == '\n') start++;
      else break;
     }
   // collect until terminator (comma or '}'), but respect quoted strings
   bool in_quote = false;
   int  end = start;
   while(end < len)
     {
      const ushort c = StringGetCharacter(body, end);
      if(c == '"') in_quote = !in_quote;
      else if(!in_quote && (c == ',' || c == '}' || c == '\n')) break;
      end++;
     }
   out = StringSubstr(body, start, end - start);
   StringTrimLeft(out);
   StringTrimRight(out);
   return StringLen(out) > 0;
  }

bool CStateManager::ExtractString(const string body, const string key, string &out) const
  {
   string raw;
   if(!ExtractRaw(body, key, raw)) return false;
   const int n = StringLen(raw);
   if(n < 2) return false;
   if(StringGetCharacter(raw, 0) != '"' || StringGetCharacter(raw, n-1) != '"') return false;
   out = StringSubstr(raw, 1, n - 2);
   return true;
  }

bool CStateManager::ExtractInt(const string body, const string key, long &out) const
  {
   string raw;
   if(!ExtractRaw(body, key, raw)) return false;
   // Reject if surrounded by quotes
   if(StringLen(raw) > 0 && StringGetCharacter(raw, 0) == '"') return false;
   out = StringToInteger(raw);
   return true;
  }

bool CStateManager::ExtractULong(const string body, const string key, ulong &out) const
  {
   long v;
   if(!ExtractInt(body, key, v)) return false;
   if(v < 0) return false;
   out = (ulong)v;
   return true;
  }

bool CStateManager::ExtractDouble(const string body, const string key, double &out) const
  {
   string raw;
   if(!ExtractRaw(body, key, raw)) return false;
   if(StringLen(raw) > 0 && StringGetCharacter(raw, 0) == '"') return false;
   out = StringToDouble(raw);
   return true;
  }

bool CStateManager::ExtractBool(const string body, const string key, bool &out) const
  {
   string raw;
   if(!ExtractRaw(body, key, raw)) return false;
   if(raw == "true")  { out = true;  return true; }
   if(raw == "false") { out = false; return true; }
   return false;
  }

//+------------------------------------------------------------------+
//| ISO-8601 UTC formatting/parsing for last_save_time.              |
//| Stored as "YYYY-MM-DDThh:mm:ssZ" against TimeGMT().              |
//+------------------------------------------------------------------+
string CStateManager::FormatIsoUtc(const datetime t) const
  {
   if(t == 0) return "1970-01-01T00:00:00Z";
   MqlDateTime mdt;
   TimeToStruct(t, mdt);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
                       mdt.year, mdt.mon, mdt.day, mdt.hour, mdt.min, mdt.sec);
  }

datetime CStateManager::ParseIsoUtc(const string s) const
  {
   // Expect "YYYY-MM-DDThh:mm:ssZ"; tolerate missing 'Z' or 'T'.
   if(StringLen(s) < 19) return 0;
   MqlDateTime mdt;
   ZeroMemory(mdt);
   mdt.year = (int)StringToInteger(StringSubstr(s, 0, 4));
   mdt.mon  = (int)StringToInteger(StringSubstr(s, 5, 2));
   mdt.day  = (int)StringToInteger(StringSubstr(s, 8, 2));
   mdt.hour = (int)StringToInteger(StringSubstr(s, 11, 2));
   mdt.min  = (int)StringToInteger(StringSubstr(s, 14, 2));
   mdt.sec  = (int)StringToInteger(StringSubstr(s, 17, 2));
   return StructToTime(mdt);
  }

#endif // ALLIGATOR_HA_STATE_MANAGER_MQH
//+------------------------------------------------------------------+
