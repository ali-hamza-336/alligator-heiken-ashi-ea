//+------------------------------------------------------------------+
//|  Logger.mqh                                                      |
//|  Severity-tagged wrapper around Print(). MT5 journal already     |
//|  prepends server time, so we add level + optional symbol only.   |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_LOGGER_MQH
#define ALLIGATOR_HA_LOGGER_MQH

class CLogger
  {
private:
   bool              m_verbose;
   string            m_tag;
public:
                     CLogger(): m_verbose(true), m_tag("EA") {}
   void              Init(const bool verbose, const string tag = "EA")
                       { m_verbose = verbose; m_tag = tag; }

   void              Debug(const string msg, const string sym = "") const
                       {
                        if(!m_verbose) return;
                        if(StringLen(sym) > 0) PrintFormat("[%s] DEBUG [%s] %s", m_tag, sym, msg);
                        else                   PrintFormat("[%s] DEBUG %s",       m_tag, msg);
                       }
   void              Info (const string msg, const string sym = "") const
                       {
                        if(StringLen(sym) > 0) PrintFormat("[%s] INFO  [%s] %s", m_tag, sym, msg);
                        else                   PrintFormat("[%s] INFO  %s",       m_tag, msg);
                       }
   void              Warn (const string msg, const string sym = "") const
                       {
                        if(StringLen(sym) > 0) PrintFormat("[%s] WARN  [%s] %s", m_tag, sym, msg);
                        else                   PrintFormat("[%s] WARN  %s",       m_tag, msg);
                       }
   void              Error(const string msg, const string sym = "") const
                       {
                        if(StringLen(sym) > 0) PrintFormat("[%s] ERROR [%s] %s", m_tag, sym, msg);
                        else                   PrintFormat("[%s] ERROR %s",       m_tag, msg);
                       }
  };

#endif // ALLIGATOR_HA_LOGGER_MQH
//+------------------------------------------------------------------+
