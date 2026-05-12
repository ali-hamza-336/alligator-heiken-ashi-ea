//+------------------------------------------------------------------+
//|  IndicatorHub.mqh                                                |
//|  Owns all per-symbol indicator handles. Init creates, Release    |
//|  frees. Accessors return closed-candle values (shift >= 1).      |
//|                                                                  |
//|  Spec: EA_Action_Plan.md §1.4.                                   |
//|                                                                  |
//|  Per-symbol handles:                                             |
//|    - alligator_m15  : iAlligator M15 (entry signal)              |
//|    - alligator_h1   : iAlligator H1  (1H soft trend filter)      |
//|    - atr_m15        : iATR(14) M15   (separation, SL buffer,     |
//|                                       dead-market, S/R dedupe)   |
//|    - adx_h1         : iADX(14) H1    (symbol prioritization)     |
//|                                                                  |
//|  Phase 2 decision: S/R dedupe on H1 and H4 reuses the M15 ATR    |
//|  as tolerance source. Same atr is passed everywhere; per-TF      |
//|  ATR can be added in Phase 3 if backtests show it matters.       |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_INDICATOR_HUB_MQH
#define ALLIGATOR_HA_INDICATOR_HUB_MQH

#include "Logger.mqh"

class CIndicatorHub
  {
private:
   CLogger          *m_log;
   string            m_symbols[];
   int               m_alligator_m15[];
   int               m_alligator_h1[];
   int               m_atr_m15[];
   int               m_adx_h1[];
   bool              m_initialized;

   int               IndexOf(const string sym) const;
   bool              CreateForSymbol(const int i,
                                     const int jaw, const int jaw_shift,
                                     const int teeth, const int teeth_shift,
                                     const int lips, const int lips_shift,
                                     const int atr_period, const int adx_period);

public:
                     CIndicatorHub() : m_log(NULL), m_initialized(false) {}

   void              SetLogger(CLogger *log) { m_log = log; }

   bool              Init(const string &symbols[],
                          const int jaw, const int jaw_shift,
                          const int teeth, const int teeth_shift,
                          const int lips, const int lips_shift,
                          const int atr_period, const int adx_period);
   void              Release();

   bool              GetAlligator(const string sym, const ENUM_TIMEFRAMES tf, const int shift,
                                  double &jaw, double &teeth, double &lips);
   bool              GetATR      (const string sym, const int shift, double &atr);
   bool              GetATRSeries(const string sym, const int from_shift, const int count,
                                  double &out[]);
   bool              GetADX1H    (const string sym, const int shift, double &adx);
  };

//+------------------------------------------------------------------+
//| Init: create 4 handles per symbol. On any failure, release       |
//| anything already created and return false.                       |
//+------------------------------------------------------------------+
bool CIndicatorHub::Init(const string &symbols[],
                         const int jaw, const int jaw_shift,
                         const int teeth, const int teeth_shift,
                         const int lips, const int lips_shift,
                         const int atr_period, const int adx_period)
  {
   if(m_initialized)
     {
      if(m_log != NULL) m_log.Warn("IndicatorHub.Init called twice; releasing previous handles first");
      Release();
     }

   const int n = ArraySize(symbols);
   if(n == 0)
     {
      if(m_log != NULL) m_log.Error("IndicatorHub.Init: empty symbols array");
      return false;
     }

   ArrayResize(m_symbols,        n);
   ArrayResize(m_alligator_m15,  n);
   ArrayResize(m_alligator_h1,   n);
   ArrayResize(m_atr_m15,        n);
   ArrayResize(m_adx_h1,         n);
   for(int i = 0; i < n; i++)
     {
      m_symbols[i]       = symbols[i];
      m_alligator_m15[i] = INVALID_HANDLE;
      m_alligator_h1[i]  = INVALID_HANDLE;
      m_atr_m15[i]       = INVALID_HANDLE;
      m_adx_h1[i]        = INVALID_HANDLE;
     }

   for(int i = 0; i < n; i++)
     {
      if(!CreateForSymbol(i, jaw, jaw_shift, teeth, teeth_shift, lips, lips_shift,
                          atr_period, adx_period))
        {
         Release();
         return false;
        }
     }

   m_initialized = true;
   if(m_log != NULL)
      m_log.Info(StringFormat("IndicatorHub initialized: %d symbol(s) × 4 handles = %d OK",
                              n, n * 4));
   return true;
  }

//+------------------------------------------------------------------+
bool CIndicatorHub::CreateForSymbol(const int i,
                                    const int jaw, const int jaw_shift,
                                    const int teeth, const int teeth_shift,
                                    const int lips, const int lips_shift,
                                    const int atr_period, const int adx_period)
  {
   const string s = m_symbols[i];

   m_alligator_m15[i] = iAlligator(s, PERIOD_M15,
                                   jaw, jaw_shift, teeth, teeth_shift, lips, lips_shift,
                                   MODE_SMMA, PRICE_MEDIAN);
   if(m_alligator_m15[i] == INVALID_HANDLE)
     { if(m_log != NULL) m_log.Error("iAlligator M15 INVALID_HANDLE", s); return false; }

   m_alligator_h1[i]  = iAlligator(s, PERIOD_H1,
                                   jaw, jaw_shift, teeth, teeth_shift, lips, lips_shift,
                                   MODE_SMMA, PRICE_MEDIAN);
   if(m_alligator_h1[i] == INVALID_HANDLE)
     { if(m_log != NULL) m_log.Error("iAlligator H1 INVALID_HANDLE", s); return false; }

   m_atr_m15[i] = iATR(s, PERIOD_M15, atr_period);
   if(m_atr_m15[i] == INVALID_HANDLE)
     { if(m_log != NULL) m_log.Error("iATR M15 INVALID_HANDLE", s); return false; }

   m_adx_h1[i] = iADX(s, PERIOD_H1, adx_period);
   if(m_adx_h1[i] == INVALID_HANDLE)
     { if(m_log != NULL) m_log.Error("iADX H1 INVALID_HANDLE", s); return false; }

   return true;
  }

//+------------------------------------------------------------------+
//| Release every non-invalid handle. Idempotent — safe to call from |
//| OnDeinit even if Init failed partway.                            |
//+------------------------------------------------------------------+
void CIndicatorHub::Release()
  {
   const int n = ArraySize(m_symbols);
   int freed = 0;
   for(int i = 0; i < n; i++)
     {
      if(m_alligator_m15[i] != INVALID_HANDLE) { IndicatorRelease(m_alligator_m15[i]); m_alligator_m15[i] = INVALID_HANDLE; freed++; }
      if(m_alligator_h1[i]  != INVALID_HANDLE) { IndicatorRelease(m_alligator_h1[i]);  m_alligator_h1[i]  = INVALID_HANDLE; freed++; }
      if(m_atr_m15[i]       != INVALID_HANDLE) { IndicatorRelease(m_atr_m15[i]);       m_atr_m15[i]       = INVALID_HANDLE; freed++; }
      if(m_adx_h1[i]        != INVALID_HANDLE) { IndicatorRelease(m_adx_h1[i]);        m_adx_h1[i]        = INVALID_HANDLE; freed++; }
     }
   if(m_log != NULL && freed > 0)
      m_log.Info(StringFormat("IndicatorHub released: %d handle(s)", freed));
   m_initialized = false;
  }

//+------------------------------------------------------------------+
int CIndicatorHub::IndexOf(const string sym) const
  {
   const int n = ArraySize(m_symbols);
   for(int i = 0; i < n; i++)
      if(m_symbols[i] == sym)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
//| GetAlligator: shift>=1 enforced (closed-candle invariant #1).    |
//| Buffers per MQL5: 0=Jaw, 1=Teeth, 2=Lips.                        |
//+------------------------------------------------------------------+
bool CIndicatorHub::GetAlligator(const string sym, const ENUM_TIMEFRAMES tf, const int shift,
                                 double &jaw, double &teeth, double &lips)
  {
   if(shift < 1)
     { if(m_log != NULL) m_log.Error("GetAlligator: shift<1 violates invariant #1", sym); return false; }
   const int i = IndexOf(sym);
   if(i < 0) return false;
   int handle = INVALID_HANDLE;
   if(tf == PERIOD_M15)      handle = m_alligator_m15[i];
   else if(tf == PERIOD_H1)  handle = m_alligator_h1[i];
   else
     { if(m_log != NULL) m_log.Error("GetAlligator: unsupported TF", sym); return false; }
   if(handle == INVALID_HANDLE) return false;

   double a[1], b[1], c[1];
   if(CopyBuffer(handle, 0, shift, 1, a) != 1) return false;
   if(CopyBuffer(handle, 1, shift, 1, b) != 1) return false;
   if(CopyBuffer(handle, 2, shift, 1, c) != 1) return false;
   jaw = a[0]; teeth = b[0]; lips = c[0];
   return true;
  }

//+------------------------------------------------------------------+
bool CIndicatorHub::GetATR(const string sym, const int shift, double &atr)
  {
   if(shift < 1) return false;
   const int i = IndexOf(sym);
   if(i < 0 || m_atr_m15[i] == INVALID_HANDLE) return false;
   double v[1];
   if(CopyBuffer(m_atr_m15[i], 0, shift, 1, v) != 1) return false;
   atr = v[0];
   return true;
  }

//+------------------------------------------------------------------+
//| Series order matches CopyBuffer non-series default:              |
//|   out[0] = oldest, out[count-1] = most recent (shift=from_shift) |
//| For ATR-ratio dead-market check the caller flips conventions —   |
//| see EA wiring.                                                   |
//+------------------------------------------------------------------+
bool CIndicatorHub::GetATRSeries(const string sym, const int from_shift, const int count,
                                 double &out[])
  {
   if(from_shift < 1 || count < 1) return false;
   const int i = IndexOf(sym);
   if(i < 0 || m_atr_m15[i] == INVALID_HANDLE) return false;
   if(CopyBuffer(m_atr_m15[i], 0, from_shift, count, out) != count) return false;
   return true;
  }

//+------------------------------------------------------------------+
bool CIndicatorHub::GetADX1H(const string sym, const int shift, double &adx)
  {
   if(shift < 1) return false;
   const int i = IndexOf(sym);
   if(i < 0 || m_adx_h1[i] == INVALID_HANDLE) return false;
   double v[1];
   if(CopyBuffer(m_adx_h1[i], 0, shift, 1, v) != 1) return false;  // 0 = main ADX line
   adx = v[0];
   return true;
  }

#endif // ALLIGATOR_HA_INDICATOR_HUB_MQH
//+------------------------------------------------------------------+
