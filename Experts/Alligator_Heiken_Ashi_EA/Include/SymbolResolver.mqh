//+------------------------------------------------------------------+
//|  SymbolResolver.mqh                                              |
//|  CSV parsing + broker-suffix resolution (e.g. EURUSD.m, US100).  |
//|                                                                  |
//|  Spec: EA_Action_Plan.md §14 Critical Reminder #9                |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_SYMBOL_RESOLVER_MQH
#define ALLIGATOR_HA_SYMBOL_RESOLVER_MQH

class CSymbolResolver
  {
public:
   //--- Pure logic (unit-tested) ---
   int               ParseCsv(const string csv, string &out[]) const;

   //--- Broker integration (integration-tested via EA chart attach) ---
   bool              ResolveOne(const string canonical, string &broker_name) const;
   bool              ResolveAll(const string &canonical[], string &resolved[], string &missing[]) const;

private:
   bool              SymbolExistsInCatalog(const string name) const;
   bool              FindByPrefix(const string canonical, string &found) const;
   bool              FindByAlias (const string canonical, string &found) const;
  };

//+------------------------------------------------------------------+
//| Split a comma-separated string. Trims whitespace per token,      |
//| skips empty tokens (so "A,,B," yields {"A","B"}).                |
//+------------------------------------------------------------------+
int CSymbolResolver::ParseCsv(const string csv, string &out[]) const
  {
   ArrayResize(out, 0);
   const int len = StringLen(csv);
   int start = 0;
   for(int i = 0; i <= len; i++)
     {
      const ushort c = (i < len) ? StringGetCharacter(csv, i) : (ushort)',';
      if(c == ',')
        {
         string tok = StringSubstr(csv, start, i - start);
         StringTrimLeft(tok);
         StringTrimRight(tok);
         if(StringLen(tok) > 0)
           {
            const int n = ArraySize(out);
            ArrayResize(out, n + 1);
            out[n] = tok;
           }
         start = i + 1;
        }
     }
   return ArraySize(out);
  }

//+------------------------------------------------------------------+
//| Try exact name → prefix scan → alias map.                        |
//+------------------------------------------------------------------+
bool CSymbolResolver::ResolveOne(const string canonical, string &broker_name) const
  {
   // 1) Exact match in broker's full catalog.
   if(SymbolExistsInCatalog(canonical))
     {
      SymbolSelect(canonical, true);
      broker_name = canonical;
      return true;
     }

   // 2) Prefix scan — handles "EURUSD.m", "EURUSD_i", "EURUSDx" etc.
   string found = "";
   if(FindByPrefix(canonical, found))
     {
      SymbolSelect(found, true);
      broker_name = found;
      return true;
     }

   // 3) Known aliases for indices/metals (NAS100→US100, etc.).
   if(FindByAlias(canonical, found))
     {
      SymbolSelect(found, true);
      broker_name = found;
      return true;
     }

   broker_name = "";
   return false;
  }

//+------------------------------------------------------------------+
bool CSymbolResolver::ResolveAll(const string &canonical[], string &resolved[], string &missing[]) const
  {
   const int n = ArraySize(canonical);
   ArrayResize(resolved, n);
   ArrayResize(missing, 0);
   bool all_ok = true;
   for(int i = 0; i < n; i++)
     {
      string b;
      if(ResolveOne(canonical[i], b))
        {
         resolved[i] = b;
        }
      else
        {
         resolved[i] = "";
         const int m = ArraySize(missing);
         ArrayResize(missing, m + 1);
         missing[m] = canonical[i];
         all_ok = false;
        }
     }
   return all_ok;
  }

//+------------------------------------------------------------------+
bool CSymbolResolver::SymbolExistsInCatalog(const string name) const
  {
   const int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      if(SymbolName(i, false) == name)
         return true;
     }
   return false;
  }

bool CSymbolResolver::FindByPrefix(const string canonical, string &found) const
  {
   const int total = SymbolsTotal(false);
   const int clen = StringLen(canonical);
   for(int i = 0; i < total; i++)
     {
      const string s = SymbolName(i, false);
      if(StringLen(s) >= clen && StringSubstr(s, 0, clen) == canonical)
        {
         found = s;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Small alias table for instruments brokers commonly rename.       |
//| Pure additive — exact and prefix match are tried first.          |
//+------------------------------------------------------------------+
bool CSymbolResolver::FindByAlias(const string canonical, string &found) const
  {
   string candidates[];
   if(canonical == "NAS100")
     {
      ArrayResize(candidates, 6);
      candidates[0] = "US100";
      candidates[1] = "USTEC";
      candidates[2] = "NDX100";
      candidates[3] = "USNDAQ100";
      candidates[4] = "NAS100.cash";
      candidates[5] = "NAS100m";
     }
   else if(canonical == "XAUUSD")
     {
      ArrayResize(candidates, 3);
      candidates[0] = "GOLD";
      candidates[1] = "XAUUSD.m";
      candidates[2] = "XAU/USD";
     }
   else
     {
      return false;
     }

   const int n = ArraySize(candidates);
   for(int i = 0; i < n; i++)
     {
      if(SymbolExistsInCatalog(candidates[i]))
        {
         found = candidates[i];
         return true;
        }
      // Also try prefix on each alias (e.g. US100.cash for US100)
      string prefixed = "";
      const int total = SymbolsTotal(false);
      const int clen = StringLen(candidates[i]);
      for(int j = 0; j < total; j++)
        {
         const string s = SymbolName(j, false);
         if(StringLen(s) >= clen && StringSubstr(s, 0, clen) == candidates[i])
           {
            found = s;
            return true;
           }
        }
     }
   return false;
  }

#endif // ALLIGATOR_HA_SYMBOL_RESOLVER_MQH
//+------------------------------------------------------------------+
