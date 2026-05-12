//+------------------------------------------------------------------+
//|  DailyLossManager.mqh                                            |
//|  FTMO loss-limit layer. Covers:                                  |
//|    (1) Daily realized-loss % since 00:00 CET (spec §5.6).       |
//|    (2) Total equity drawdown vs the persisted initial balance    |
//|        (spec §7 "Max Loss 10%") — IsTotalDDBreached.            |
//|  Server time = CET on this broker (verified Phase 4-5) so       |
//|  server date is the rollover key. Pure — no MT5 API except       |
//|  the date-format helper which uses TimeToStruct on its arg.      |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_DAILY_LOSS_MANAGER_MQH
#define ALLIGATOR_HA_DAILY_LOSS_MANAGER_MQH

#include "StateManager.mqh"

class CDailyLossManager
  {
public:
   static string  CETDateString    (const datetime server_now);
   static bool    IsNewCETDate     (const string state_date, const string current_date);
   static void    ResetForNewDay   (EAState &state, const string current_date);
   static bool    WouldBreachLimit (const double current_pct,
                                     const double position_risk_pct,
                                     const double max_daily_loss);
   static bool    IsTotalDDBreached(const double equity, const double initial_balance,
                                     const double buffer_pct);
   static void    ApplyRealizedProfit(EAState &state, const double profit,
                                       const double day_start_equity);
  };

//+------------------------------------------------------------------+
//| "YYYY-MM-DD" against server time.                                |
//+------------------------------------------------------------------+
string CDailyLossManager::CETDateString(const datetime server_now)
  {
   MqlDateTime mdt; TimeToStruct(server_now, mdt);
   return StringFormat("%04d-%02d-%02d", mdt.year, mdt.mon, mdt.day);
  }

//+------------------------------------------------------------------+
//| True when state has no date yet (first run) OR date differs.     |
//+------------------------------------------------------------------+
bool CDailyLossManager::IsNewCETDate(const string state_date, const string current_date)
  {
   if(StringLen(state_date) == 0) return true;
   return state_date != current_date;
  }

//+------------------------------------------------------------------+
//| Spec §5.6: at 00:00 CET, zero counter and advance the date.     |
//| `trades_taken_today` is also a per-day counter (per spec §8.1)  |
//| so reset it here too.                                            |
//+------------------------------------------------------------------+
void CDailyLossManager::ResetForNewDay(EAState &state, const string current_date)
  {
   state.daily_loss_pct     = 0.0;
   state.daily_loss_date    = current_date;
   state.trades_taken_today = 0;
  }

//+------------------------------------------------------------------+
//| Spec §5.6: pre-entry check — block if (current + risk) > max.   |
//+------------------------------------------------------------------+
bool CDailyLossManager::WouldBreachLimit(const double current_pct,
                                         const double position_risk_pct,
                                         const double max_daily_loss)
  {
   return (current_pct + position_risk_pct) > max_daily_loss;
  }

//+------------------------------------------------------------------+
//| Spec §5 / §7 "Max Loss 10%": block all entries once equity has   |
//| fallen `buffer_pct`% below the persisted initial balance         |
//| (default 7%, i.e. a 3% cushion under FTMO's 10%). Strict < so    |
//| exactly-on-line is not yet a breach. initial_balance <= 0 =>     |
//| not snapshotted yet => fail-open (EA always snapshots first run).|
//+------------------------------------------------------------------+
bool CDailyLossManager::IsTotalDDBreached(const double equity, const double initial_balance,
                                          const double buffer_pct)
  {
   if(initial_balance <= 0.0) return false;
   const double line = initial_balance * (1.0 - buffer_pct / 100.0);
   return equity < line;
  }

//+------------------------------------------------------------------+
//| Add |profit|/day_start_equity*100 to daily_loss_pct when profit |
//| is negative. Wins are ignored (spec tracks loss %, not net P/L).|
//| day_start_equity == 0 is a no-op (caller hasn't snapshot yet).  |
//+------------------------------------------------------------------+
void CDailyLossManager::ApplyRealizedProfit(EAState &state, const double profit,
                                            const double day_start_equity)
  {
   if(profit >= 0)              return;
   if(day_start_equity <= 0)    return;
   const double loss_pct = (-profit / day_start_equity) * 100.0;
   state.daily_loss_pct += loss_pct;
  }

#endif // ALLIGATOR_HA_DAILY_LOSS_MANAGER_MQH
//+------------------------------------------------------------------+
