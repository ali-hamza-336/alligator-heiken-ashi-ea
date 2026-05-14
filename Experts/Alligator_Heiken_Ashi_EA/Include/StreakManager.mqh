//+------------------------------------------------------------------+
//|  StreakManager.mqh                                               |
//|  Phase 6 — cycle/streak state machine. Pure mutations on the     |
//|  shared EAState struct. No MT5 API calls.                         |
//|                                                                  |
//|  Spec: §5.2, §5.3, §5.4, §5.5, §5.7.                             |
//+------------------------------------------------------------------+
#ifndef ALLIGATOR_HA_STREAK_MANAGER_MQH
#define ALLIGATOR_HA_STREAK_MANAGER_MQH

#include "StateManager.mqh"

enum ETradingMode
  {
   MODE_DEFAULT  = 0,
   MODE_RECOVERY = 1,
   MODE_LOCKED   = 2,
  };

enum EForcedCloseReason
  {
   FCR_LIPS_BREAK   = 0,   // Restored 2026-05-15: Lips-break market close advances streak as if an SL hit
   FCR_FRIDAY_CLOSE = 1,
   FCR_NY_CARRYOVER = 2,
  };

class CStreakManager
  {
public:
   static bool          IsRecoveryActive(const EAState &state, const int max_streak);
   static bool          IsCycleLocked   (const EAState &state, const int max_streak);
   static ETradingMode  DeriveMode      (const EAState &state, const int max_streak);

   static void          OnSLClose       (EAState &state, const int max_streak);
   static void          OnTPClose       (EAState &state);
   static void          OnForcedClose   (EAState &state, const EForcedCloseReason r,
                                          const int max_streak);
   static void          ResetForNewCycle(EAState &state, const string new_cycle_id);
  };

//+------------------------------------------------------------------+
//| Spec §5.3: recovery active when ≥1 SL this cycle, no TP yet, and |
//| streak hasn't hit the lock threshold yet.                         |
//+------------------------------------------------------------------+
bool CStreakManager::IsRecoveryActive(const EAState &state, const int max_streak)
  {
   if(state.tp_hit_in_cycle)             return false;
   if(state.last_sl_count >= max_streak) return false;
   return state.last_sl_count >= 1;
  }

//+------------------------------------------------------------------+
//| Spec §5.3: cycle locked = TP hit OR max-streak SLs reached.      |
//+------------------------------------------------------------------+
bool CStreakManager::IsCycleLocked(const EAState &state, const int max_streak)
  {
   if(state.tp_hit_in_cycle)             return true;
   if(state.last_sl_count >= max_streak) return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Composed mode. Caller passes Max_Streak_Length from inputs.      |
//+------------------------------------------------------------------+
ETradingMode CStreakManager::DeriveMode(const EAState &state, const int max_streak)
  {
   if(IsCycleLocked   (state, max_streak)) return MODE_LOCKED;
   if(IsRecoveryActive(state, max_streak)) return MODE_RECOVERY;
   return MODE_DEFAULT;
  }

//+------------------------------------------------------------------+
//| Spec §5.3: SL increments last_sl_count. streak_position advances |
//| 1→2→3 (clamped at 3 — risk array has 3 buckets).                  |
//+------------------------------------------------------------------+
void CStreakManager::OnSLClose(EAState &state, const int max_streak)
  {
   state.last_sl_count   += 1;
   state.streak_position += 1;
   if(state.streak_position > 3) state.streak_position = 3;   // risk array has exactly 3 buckets (R1/R2/R3), independent of max_streak
  }

//+------------------------------------------------------------------+
//| Spec §5.3: TP ends the cycle. Streak unchanged (next cycle reset |
//| zeros it). Mode flip to LOCKED is implicit via DeriveMode reading|
//| tp_hit_in_cycle.                                                  |
//+------------------------------------------------------------------+
void CStreakManager::OnTPClose(EAState &state)
  {
   state.tp_hit_in_cycle = true;
  }

//+------------------------------------------------------------------+
//| Forced-close dispatch. Lips break = SL semantics for streak.     |
//| Friday close + NY carryover do NOT touch streak (per §5.7 the    |
//| Monday rollover wipes it; per §5.5 the carryover close is from a |
//| previous cycle and irrelevant).                                   |
//+------------------------------------------------------------------+
void CStreakManager::OnForcedClose(EAState &state, const EForcedCloseReason r,
                                   const int max_streak)
  {
   //  FCR_LIPS_BREAK: streak semantics = SL (Stage 1.1 behavior, restored 2026-05-15).
   //  FCR_FRIDAY_CLOSE / FCR_NY_CARRYOVER: no-op for streak.
   //  (Friday-15:00 NY rollover wipes streak next NY-open; NY carryover close came
   //  from a previous cycle and shouldn't count.)
   if(r == FCR_LIPS_BREAK) OnSLClose(state, max_streak);
  }

//+------------------------------------------------------------------+
//| Spec §5.4: NY-open rollover. Caller computes new_cycle_id via    |
//| CSessionTime::NYDateString + "_NY" and passes here.               |
//+------------------------------------------------------------------+
void CStreakManager::ResetForNewCycle(EAState &state, const string new_cycle_id)
  {
   state.streak_position  = 1;
   state.last_sl_count    = 0;
   state.tp_hit_in_cycle  = false;
   state.current_cycle_id = new_cycle_id;
  }

#endif // ALLIGATOR_HA_STREAK_MANAGER_MQH
//+------------------------------------------------------------------+
