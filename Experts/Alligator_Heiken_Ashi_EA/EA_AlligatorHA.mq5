//+------------------------------------------------------------------+
//|  EA_AlligatorHA.mq5                                              |
//|  Bill Williams Alligator + Heiken Ashi multi-symbol EA           |
//|  Target: FTMO Swing 2-Step Challenge ($100k default), 3-5%/mo    |
//|                                                                  |
//|  Phase 8 — test & validate (tester hardening + README).          |
//|  See EA_Action_Plan.md for the full specification.               |
//+------------------------------------------------------------------+
#property copyright "Phase 8 — test & validate"
#property version   "1.00"
#property strict

#include "Include\\Logger.mqh"
#include "Include\\StateManager.mqh"
#include "Include\\SymbolResolver.mqh"
#include "Include\\IndicatorHub.mqh"
#include "Include\\HeikenAshi.mqh"
#include "Include\\SRDetector.mqh"
#include "Include\\MarketFilters.mqh"
#include "Include\\SignalEngine.mqh"
#include "Include\\SymbolPrioritizer.mqh"
#include "Include\\PositionManager.mqh"
#include "Include\\TradeManager.mqh"
#include "Include\\SessionTime.mqh"
#include "Include\\SessionManager.mqh"
#include "Include\\StreakManager.mqh"
#include "Include\\DailyLossManager.mqh"
#include "Include\\NewsFilter.mqh"

//+------------------------------------------------------------------+
//| Inputs — verbatim from EA_Action_Plan.md §9                      |
//+------------------------------------------------------------------+
//--- ACCOUNT & RISK
input double  AccountSize_Reference  = 100000.0;  // For documentation only; live uses real equity
input double  Risk_Position1         = 0.30;      // % per first trade
input double  Risk_Position2         = 0.50;      // % per second trade
input double  Risk_Position3         = 0.70;      // % per third trade
input double  Max_Daily_Loss         = 1.50;      // % — hard stop for the day
input int     Max_Streak_Length      = 3;         // SLs before streak reset
input double  Max_Total_DD_Buffer    = 7.00;      // % below initial — emergency block
input double  Max_Lot                = 50.0;      // Path A: hard ceiling on any single lot (belt-and-braces vs sizing blow-ups)

//--- SESSION TIMES (NY local)
input int     NY_Start_Hour          = 8;
input int     NY_End_Hour            = 15;        // last 2hr of NY skipped
input int     Tokyo_Skip_First_Min   = 30;
input int     Friday_Close_Hour_NY   = 15;

//--- ALLIGATOR (Standard BW)
input int     Jaw_Period             = 13;
input int     Jaw_Shift              = 8;
input int     Teeth_Period           = 8;
input int     Teeth_Shift            = 5;
input int     Lips_Period            = 5;
input int     Lips_Shift             = 3;

//--- ATR-BASED FILTERS
input int     ATR_Period             = 14;
input double  ATR_Mouth_Open_Mult    = 0.4;       // Lips-Jaw separation
input double  ATR_SL_Buffer          = 0.2;       // beyond Jaw/swing
input double  Min_SL_ATR_Mult        = 0.3;       // Path A Stage 1.1: dialled back from 1.0 (rejected ~110 legit Type-A signals at ~0.6×ATR); reject only the truly tangled cases
input double  ATR_Tangle_Tolerance   = 0.3;       // for "mouth closed" detection
input double  Min_ATR_Ratio          = 0.5;       // dead market filter
input double  Trail_ATR_Buffer       = 0.3;
input double  BE_Trigger_R           = 1.0;
input double  BE_Buffer_Pips         = 2.0;
//--- Lips-break exit softening (Phase 8 — defaults reproduce spec §3.4 exactly)
input double  LipsBreak_ATR_Buffer   = 0.0;       // 0 = spec; break needs close past Lips by >= mult*ATR
input int     LipsBreak_Confirm_Bars = 1;         // 1 = spec; 2..3 = require last N M15 closes all beyond Lips
input int     LipsBreak_Min_Hold_Bars= 0;         // 0 = spec; no Lips-break exit in the first N M15 bars after entry

//--- TREND/STRENGTH FILTERS
input int     ADX_Period             = 14;
input double  Min_ADX_1H             = 20.0;

//--- SUPPORT/RESISTANCE
input int     SR_Lookback_Bars_1H    = 100;
input int     SR_Lookback_Bars_4H    = 50;
input int     SR_Block_Distance_Pips = 10;
input int     SR_Swing_Bars_Each_Side = 3;        // for swing detection

//--- HEIKEN ASHI
input double  HA_Wick_Tolerance_Pips = 1.0;       // max opposing wick

//--- SPREAD LIMITS (per symbol)
input double  Spread_EURUSD          = 1.5;
input double  Spread_GBPUSD          = 1.5;
input double  Spread_USDJPY          = 2.0;
input double  Spread_USDCHF          = 2.0;
input double  Spread_AUDUSD          = 2.0;
input double  Spread_USDCAD          = 2.0;
input double  Spread_NZDUSD          = 2.0;
input double  Spread_XAUUSD          = 50.0;      // Path A: was 30 (too tight on IC Markets gold); per-broker tunable
input double  Spread_NAS100          = 200.0;     // Path A: was 2 (USTEC quotes ~90 pts on IC Markets); per-broker tunable

//--- SLIPPAGE
input int     Slippage_FX_Pips       = 3;
input int     Slippage_Gold_Cents    = 50;
input int     Slippage_NAS_Points    = 5;

//--- NEWS FILTER
input bool    News_Filter_Enabled    = true;
input int     News_Block_Min_Before  = 15;
input int     News_Block_Min_After   = 15;
input string  News_Impact_Filter     = "High";    // High, Medium+, All

//--- SYMBOLS (CSV list) — Path A Stage 1: dropped USDCAD & AUDUSD (consistent losers in the 12-mo backtest).
//--- Stage 1.1: dropped NAS100 — every signal rejected (spread=NO) on IC Markets even with Spread_NAS100=200.
input string  Trade_Symbols          = "EURUSD,GBPUSD,USDJPY,USDCHF,NZDUSD,XAUUSD";

//--- SYSTEM
input long    Magic_Number           = 20260503;
input bool    Verbose_Logging        = true;
input string  State_File_Name        = "EA_State.json";
input bool    Phase2_Diagnostic_Dump = false;     // Phase-2 per-bar indicator dump

//--- PHASE 6: 0 = auto-derive from broker GMT offset + US DST (recommended).
//--- Non-zero = override (e.g. -7 to force CEST→EDT). Useful for tester.
input int     Server_To_NY_Offset_Hours = 0;     // 0 = auto, non-zero = override

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CLogger         Log;
CStateManager   State;
CSymbolResolver Resolver;
CIndicatorHub   Hub;

string         g_symbols[];          // resolved broker symbol names
string         g_canonical[];        // original CSV input names (parallel to g_symbols)
datetime       g_last_m15_bar[];     // last seen M15 close time per symbol
EAState        g_state;
string         g_state_file;         // per-magic state filename
SpreadLimits   g_spread_limits;
double        g_day_start_equity     = 0;   // captured on each new CET date (Phase 6)

//+------------------------------------------------------------------+
//| Forward declarations                                             |
//+------------------------------------------------------------------+
bool ValidateInputs();
bool ResolveSymbols();
void PopulateSpreadLimits();
void OnNewM15Bar(const string sym, const datetime bar_time);
void DumpDiagnostics(const int idx, const datetime bar_time);
string MakeStateFilename();
int    CanonicalIndex(const string broker_sym);
void   LogADXSnapshot();
bool   SRRoomToTP(const string sym, const ESignalKind kind,
                  const double entry, const double atr, const int block_pips);
string CycleIdNow();
void   AdoptOpenPosition();
bool   EvaluateOpenPosition(const string sym, const datetime bar_time);
bool   ResolveClosedPosition(const ulong ticket);
int    CurrentBrokerGMTOffsetHr(const datetime now);
int    CurrentNYOffset(const datetime now);
void   MaybeRolloverCycle(const datetime now);
void   MaybeResetDailyLoss(const datetime now);

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   Log.Init(Verbose_Logging, "AlligatorHA");
   Log.Info("===== EA Phase 8 startup =====");
   Log.Info(StringFormat("Magic=%I64d  Verbose=%s",
                         Magic_Number, Verbose_Logging ? "true" : "false"));

   //--- Phase 8: broker GMT offset is recomputed per call now (CurrentBrokerGMTOffsetHr),
   //--- so a mid-run DST flip — broker's or NY's — is picked up without restarting, and
   //--- 12-month backtests stay correct across the whole period. Log the boot value only.
   Log.Info(StringFormat("Broker GMT offset (boot): %+dh -> NY offset %+dh (server=%s GMT=%s)",
                          CurrentBrokerGMTOffsetHr(TimeCurrent()),
                          CurrentNYOffset(TimeCurrent()),
                          TimeToString(TimeTradeServer(), TIME_DATE|TIME_MINUTES),
                          TimeToString(TimeGMT(),         TIME_DATE|TIME_MINUTES)));

   if(!ValidateInputs())
     {
      Log.Error("Input validation failed. EA will not start.");
      return INIT_PARAMETERS_INCORRECT;
     }
   Log.Info("Inputs validated OK.");

   if(!ResolveSymbols())
     {
      Log.Error("Symbol resolution failed. EA will not start.");
      return INIT_FAILED;
     }

   //--- Phase 2: indicator handles for every resolved symbol
   PopulateSpreadLimits();
   Hub.SetLogger(GetPointer(Log));
   if(!Hub.Init(g_symbols,
                Jaw_Period, Jaw_Shift, Teeth_Period, Teeth_Shift, Lips_Period, Lips_Shift,
                ATR_Period, ADX_Period))
     {
      Log.Error("IndicatorHub initialization failed. EA will not start.");
      return INIT_FAILED;
     }

   //--- One-shot ADX snapshot for sanity. Phase 6 will move this to NY-open.
   LogADXSnapshot();

   //--- State file path is per-magic so multiple EA instances don't collide.
   g_state_file = MakeStateFilename();
   if(MQLInfoInteger(MQL_TESTER))
     {
      //--- Phase 8: in the Strategy Tester always start from a clean slate — a
      //--- previous run's state file lives in the same agent dir and would
      //--- otherwise leak streak/daily-loss/ticket across runs.
      State.InitDefault(g_state);
      Log.Info("State: Strategy Tester -> fresh state (streak=1), persisted file ignored.");
     }
   else if(State.Load(g_state, g_state_file))
      Log.Info(StringFormat("State file loaded: streak=%d, cycle=%s, daily_loss=%.2f%%, open_ticket=%I64u",
                            g_state.streak_position, g_state.current_cycle_id,
                            g_state.daily_loss_pct, g_state.open_trade_ticket));
   else
      Log.Warn(StringFormat("No valid state at '%s' — starting with fresh state (streak=1)", g_state_file));

   //--- Phase 7 §7: persist the FTMO max-loss baseline once. FTMO measures the
   //--- 10% rule from the *initial* balance, so snapshot it on first run and never touch it again.
   if(g_state.initial_balance <= 0.0)
     {
      g_state.initial_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      Log.Info(StringFormat("Initial balance snapshot: %.2f (FTMO max-loss baseline; emergency entry-block below %.2f)",
                            g_state.initial_balance, g_state.initial_balance * (1.0 - Max_Total_DD_Buffer/100.0)));
      if(!State.Save(g_state, g_state_file)) Log.Warn("OnInit: state save failed after initial-balance snapshot");
     }
   else
      Log.Info(StringFormat("FTMO max-loss baseline (from state): initial=%.2f, emergency entry-block below %.2f",
                            g_state.initial_balance, g_state.initial_balance * (1.0 - Max_Total_DD_Buffer/100.0)));

   //--- Spec §8.4 + CLAUDE.md Phase 5 Task 1: reconcile state vs live positions
   AdoptOpenPosition();

   //--- 15-minute heartbeat for state save (spec §8.2). Pointless in the tester
   //--- (no crash-recovery need; OnDeinit flushes) and adds ~35k file writes to a
   //--- 12-month every-tick run — skip it there.
   if(!MQLInfoInteger(MQL_TESTER))
      EventSetTimer(900);

   Log.Info(StringFormat("Phase 8 — test & validate build. Magic=%I64d will be stamped on every position.",
                         Magic_Number));
   Log.Info("===== Init complete =====");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   //--- Free indicator handles before state save so they're released even
   //--- if the file write fails for some reason.
   Hub.Release();
   g_state.last_save_time = TimeGMT();
   if(State.Save(g_state, g_state_file))
      Log.Info(StringFormat("State flushed on shutdown (reason=%d)", reason));
   else
      Log.Error("State flush failed on shutdown");
   Log.Info("===== EA shutdown =====");
  }

//+------------------------------------------------------------------+
//| OnTick — closed-bar gate per symbol. No per-tick logic (§7.1).   |
//+------------------------------------------------------------------+
void OnTick()
  {
   const int n = ArraySize(g_symbols);
   for(int i = 0; i < n; i++)
     {
      const datetime t = iTime(g_symbols[i], PERIOD_M15, 0);
      if(t == 0) continue;                 // data not yet available
      if(t == g_last_m15_bar[i]) continue; // same bar, ignore
      g_last_m15_bar[i] = t;
      OnNewM15Bar(g_symbols[i], t);
      if(Phase2_Diagnostic_Dump) DumpDiagnostics(i, t);
     }
  }

//+------------------------------------------------------------------+
//| OnTimer — 15-min heartbeat: flush state file                     |
//+------------------------------------------------------------------+
void OnTimer()
  {
   g_state.last_save_time = TimeGMT();
   if(!State.Save(g_state, g_state_file))
      Log.Warn("Heartbeat state save failed");
  }

//+------------------------------------------------------------------+
//| Phase 3: build context, detect Type A / B, run per-bar filters,  |
//| log SIG block + WOULD ENTER (no order placed).                   |
//+------------------------------------------------------------------+
void OnNewM15Bar(const string sym, const datetime bar_time)
  {
   //--- Phase 5: manage open position first. If consumed, skip entry logic.
   if(EvaluateOpenPosition(sym, bar_time))
      return;

   //--- Phase 6: cycle rollover + full session/mode gate. Order matters:
   //---   1. EvaluateOpenPosition already ran (above) and may have closed
   //---      a carryover ticket via MA_CLOSE_NYOPEN.
   //---   2. MaybeRolloverCycle resets streak/cycle if NY date changed.
   //---   3. IsTradingAllowed gates entry by mode + window + Friday close.
   const datetime now    = TimeCurrent();
   MaybeRolloverCycle(now);
   MaybeResetDailyLoss(now);

   const int    off        = CurrentNYOffset(now);
   const int    ny_dow     = CSessionTime::NYWeekday(now, off);
   const int    ny_hour    = CSessionTime::NYHour   (now, off);
   const ETradingMode mode = CStreakManager::DeriveMode(g_state, Max_Streak_Length);
   const TradeAllowResult gate = CSessionManager::IsTradingAllowed(
      mode, ny_dow, ny_hour, NY_Start_Hour, NY_End_Hour, Friday_Close_Hour_NY);
   if(!gate.allowed)
     {
      Log.Debug(StringFormat("entry-block: %s (mode=%d dow=%d hr=%02d)",
                              gate.reason, (int)mode, ny_dow, ny_hour), sym);
      return;
     }

   //--- Phase 7 §7: total-DD emergency stop — block ALL new entries once equity
   //--- has fallen Max_Total_DD_Buffer% below the persisted initial balance.
   //--- Open positions are left alone (spec §7 says only "blocks all entries").
   {
      const double eq_now = AccountInfoDouble(ACCOUNT_EQUITY);
      if(CDailyLossManager::IsTotalDDBreached(eq_now, g_state.initial_balance, Max_Total_DD_Buffer))
        {
         Log.Warn(StringFormat("entry-block: EMERGENCY total-DD — equity %.2f < %.2f (initial %.2f − %.2f%%)",
                               eq_now, g_state.initial_balance * (1.0 - Max_Total_DD_Buffer/100.0),
                               g_state.initial_balance, Max_Total_DD_Buffer), sym);
         return;
        }
   }

   //--- Build context (returns false if any indicator/HA/series read fails)
   SignalContext ctx;
   if(!CSignalEngine::BuildContext(GetPointer(Hub), sym,
                                   ATR_Mouth_Open_Mult, ATR_SL_Buffer,
                                   ATR_Tangle_Tolerance, HA_Wick_Tolerance_Pips, ctx))
     { Log.Debug("BuildContext: data not ready", sym); return; }

   //--- Detect signals (Type A wins ties — only one event per bar)
   SignalResult ra, rb;
   const bool got_a = CSignalEngine::DetectTypeA(ctx, ra);
   const bool got_b = !got_a && CSignalEngine::DetectTypeB(ctx, rb);
   if(!got_a && !got_b) { Log.Debug("no signal", sym); return; }
   const SignalResult r = got_a ? ra : rb;

   //--- Per-bar gates (ADX, dead market, spread, hedge)
   double adx_now = 0;
   const bool ok_adx = Hub.GetADX1H(sym, 1, adx_now);
   const bool adx_pass = ok_adx && adx_now >= Min_ADX_1H;

   double atr_series[]; bool dead = true;
   if(Hub.GetATRSeries(sym, 1, 21, atr_series) && ArraySize(atr_series) == 21)
     {
      double flip[]; ArrayResize(flip, 21);
      for(int k = 0; k < 21; k++) flip[k] = atr_series[20 - k];
      dead = CMarketFilters::IsDeadMarket(flip, 21, Min_ATR_Ratio);
     }

   const int    ci    = CanonicalIndex(sym);
   const string canon = (ci >= 0) ? g_canonical[ci] : "";
   double cur_pips = 0, lim_pips = 0;
   const bool ok_lim    = CMarketFilters::LookupSpreadLimit(canon, g_spread_limits, lim_pips);
   const bool ok_cur    = CMarketFilters::CurrentSpreadPips(sym, cur_pips);
   const bool spread_pass = ok_cur && ok_lim && cur_pips <= lim_pips;

   const bool hedge_clear = !CSignalEngine::HasOpenPositionForSymbol(sym, Magic_Number);

   //--- Phase 7 §4.5: high-impact news blackout for this symbol's currencies.
   string news_reason = "";
   const bool news_clear = !CNewsFilter::IsBlocked(canon, TimeCurrent(),
                                                   News_Filter_Enabled, News_Impact_Filter,
                                                   News_Block_Min_Before, News_Block_Min_After, news_reason);

   //--- Entry price = close of trigger bar (shift 1)
   const double entry_close = iClose(sym, PERIOD_M15, 1);

   //--- S/R block: skip if nearest opposing level is within SR_Block_Distance_Pips
   const bool sr_room = SRRoomToTP(sym, r.kind, entry_close, ctx.atr, SR_Block_Distance_Pips);

   const string kind_str =
      (r.kind == SIGNAL_TYPE_A_BUY ) ? "A_BUY"  :
      (r.kind == SIGNAL_TYPE_A_SELL) ? "A_SELL" :
      (r.kind == SIGNAL_TYPE_B_BUY ) ? "B_BUY"  : "B_SELL";

   Log.Info(StringFormat("SIG %s @ %s  kind=%s  entry=%.5f  SL=%.5f",
                         sym, TimeToString(bar_time, TIME_DATE|TIME_MINUTES),
                         kind_str, entry_close, r.sl_price), sym);
   Log.Info(StringFormat("    filters: ADX=%s(%.1f) dead=%s spread=%s hedge=%s sr=%s news=%s",
                         adx_pass ? "OK" : "NO", adx_now,
                         dead ? "YES" : "no",
                         spread_pass ? "OK" : "NO",
                         hedge_clear ? "OK" : "BLOCKED",
                         sr_room ? "OK" : "BLOCKED",
                         news_clear ? "OK" : "BLOCKED"), sym);
   if(!news_clear) Log.Info(StringFormat("    %s", news_reason), sym);

   const bool all_pass = adx_pass && !dead && spread_pass && hedge_clear && sr_room && news_clear;
   if(!all_pass) { Log.Info("    >>> SKIPPED by filters", sym); return; }

   //--- Build order plan
   OrderPlan plan;
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const bool built = CPositionManager::BuildPlan(
                         sym, canon, r, entry_close, ctx.atr, equity,
                         g_state.streak_position,
                         Risk_Position1, Risk_Position2, Risk_Position3,
                         Magic_Number,
                         Slippage_FX_Pips, Slippage_Gold_Cents, Slippage_NAS_Points,
                         SR_Lookback_Bars_1H, SR_Lookback_Bars_4H, SR_Swing_Bars_Each_Side,
                         Min_SL_ATR_Mult, Max_Lot,
                         plan);
   if(!built)
     {
      Log.Warn(StringFormat("    >>> SKIPPED: %s", plan.invalid_reason), sym);
      return;
     }

   //--- Phase 6 §5.6: budget check using the next position's risk pct.
   if(CDailyLossManager::WouldBreachLimit(g_state.daily_loss_pct, plan.risk_pct,
                                           Max_Daily_Loss))
     {
      Log.Info(StringFormat("    >>> SKIPPED: daily-loss budget (%.2f%% + %.2f%% > %.2f%%)",
                             g_state.daily_loss_pct, plan.risk_pct, Max_Daily_Loss), sym);
      return;
     }

   Log.Info(StringFormat("    PLAN streak=%d risk=%.2f%% lots=%.2f (raw=%.4f) SL=%.5f TP=%.5f slip=%dpts",
                         plan.streak_position, plan.risk_pct, plan.lots, plan.lot_raw,
                         plan.sl, plan.tp, plan.slippage_pts), sym);

   //--- Place
   PlaceResult res;
   const bool placed = CPositionManager::Place(plan, res);
   if(!placed || !res.filled)
     {
      Log.Error(StringFormat("    >>> PLACE FAILED retcode=%u comment=%s retries=%d",
                              res.retcode, res.comment, res.retries), sym);
      return;
     }

   Log.Info(StringFormat("    >>> ENTERED ticket=%I64u fill=%.5f retries=%d",
                         res.ticket, res.fill_price, res.retries), sym);

   //--- Persist immediately. StateManager.Save is atomic (spec §14 #5).
   g_state.open_trade_ticket   = res.ticket;
   g_state.open_trade_cycle_id = CycleIdNow();
   if(StringLen(g_state.current_cycle_id) == 0)
      g_state.current_cycle_id = g_state.open_trade_cycle_id;
   g_state.trades_taken_today += 1;
   g_state.last_save_time      = TimeGMT();
   if(!State.Save(g_state, g_state_file))
      Log.Error("    state save after fill FAILED", sym);
  }

//+------------------------------------------------------------------+
//| Spec §8.4 + CLAUDE.md Phase 5 Task 1: reconcile state.open_trade |
//| with live positions filtered by Magic Number.                    |
//|   - 0 live, state has ticket -> stale; clear and warn.           |
//|   - 1 live, state matches    -> adopt as-is.                     |
//|   - 1 live, state mismatch   -> reconcile state to live ticket.  |
//|   - >1 live                  -> log error (hedge block should    |
//|                                  prevent this; do not auto-pick).|
//+------------------------------------------------------------------+
void AdoptOpenPosition()
  {
   const int total = PositionsTotal();
   ulong   live_tickets[];
   string  live_syms[];
   int     n_live = 0;
   for(int i = 0; i < total; i++)
     {
      const ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;
      ArrayResize(live_tickets, n_live + 1);
      ArrayResize(live_syms,    n_live + 1);
      live_tickets[n_live] = t;
      live_syms[n_live]    = PositionGetString(POSITION_SYMBOL);
      n_live++;
     }

   if(n_live == 0)
     {
      if(g_state.open_trade_ticket != 0)
        {
         Log.Warn(StringFormat("Adopt: state references ticket=%I64u but no live position with magic=%I64d -> clearing stale reference",
                                g_state.open_trade_ticket, Magic_Number));
         g_state.open_trade_ticket   = 0;
         g_state.open_trade_cycle_id = "";
         g_state.last_save_time      = TimeGMT();
         State.Save(g_state, g_state_file);
        }
      else
         Log.Info("Adopt: no live position, no state reference -> idle.");
      return;
     }

   if(n_live > 1)
     {
      string list = "";
      for(int i = 0; i < n_live; i++)
         list += StringFormat("%s%I64u(%s)", i > 0 ? ", " : "", live_tickets[i], live_syms[i]);
      Log.Error(StringFormat("Adopt: %d live positions with magic=%I64d (hedge block expected <=1): [%s]. State NOT auto-modified.",
                              n_live, Magic_Number, list));
      return;
     }

   //--- exactly one live position
   const ulong  t   = live_tickets[0];
   const string sym = live_syms[0];
   if(g_state.open_trade_ticket == t)
     {
      Log.Info(StringFormat("Adopt: state matches live ticket=%I64u (%s) cycle=%s",
                             t, sym, g_state.open_trade_cycle_id));
      return;
     }
   const ulong prev = g_state.open_trade_ticket;
   g_state.open_trade_ticket = t;
   if(StringLen(g_state.open_trade_cycle_id) == 0)
      g_state.open_trade_cycle_id = CycleIdNow();
   g_state.last_save_time = TimeGMT();
   State.Save(g_state, g_state_file);
   Log.Warn(StringFormat("Adopt: state.open_trade_ticket reconciled %I64u -> %I64u (%s) cycle=%s",
                          prev, t, sym, g_state.open_trade_cycle_id));
  }

//+------------------------------------------------------------------+
//| Spec §5.4: at the first closed-bar event past NY_Start_Hour on a |
//| new NY date, reset streak/cycle state and (per §5.5) force-close |
//| any open position from the previous cycle. The actual close has  |
//| already been wired in Phase 5's EvaluateOpenPosition via the     |
//| MA_CLOSE_NYOPEN branch — this helper only resets the counters    |
//| once that branch has had a chance to run.                        |
//+------------------------------------------------------------------+
void MaybeRolloverCycle(const datetime now)
  {
   const int    off       = CurrentNYOffset(now);
   const int    ny_dow    = CSessionTime::NYWeekday(now, off);
   const int    ny_hour   = CSessionTime::NYHour   (now, off);
   const string today_id  = CSessionTime::NYDateString(now, off) + "_NY";

   if(ny_dow < 1 || ny_dow > 5)               return;
   if(ny_hour < NY_Start_Hour)                return;
   if(g_state.current_cycle_id == today_id)   return;
   //  Defer rollover one bar if a position is still open — the
   //  MA_CLOSE_NYOPEN branch in EvaluateOpenPosition closes it on this
   //  bar and clears open_trade_ticket; rollover fires on the next bar.
   if(g_state.open_trade_ticket != 0)         return;

   const string prev = g_state.current_cycle_id;
   CStreakManager::ResetForNewCycle(g_state, today_id);
   //  Note: trades_taken_today is a per-CET-day counter, reset by
   //  CDailyLossManager::ResetForNewDay (wired in Task 7), not here.
   g_state.last_save_time = TimeGMT();
   if(!State.Save(g_state, g_state_file))
      Log.Warn("MaybeRolloverCycle: state save failed");
   Log.Info(StringFormat("Cycle rollover: %s -> %s (streak/SL/TP cleared)",
                          StringLen(prev) > 0 ? prev : "(none)", today_id));
  }

//+------------------------------------------------------------------+
//| Spec §5.6: at the first bar event past 00:00 CET on a new date, |
//| zero the daily-loss counter and snapshot day-start equity.       |
//| Server time == CET on this broker (verified Phase 4-5).          |
//+------------------------------------------------------------------+
void MaybeResetDailyLoss(const datetime now)
  {
   const string today = CDailyLossManager::CETDateString(now);
   if(!CDailyLossManager::IsNewCETDate(g_state.daily_loss_date, today))
     {
      //  Same day — make sure day_start_equity is set (e.g. first bar after
      //  EA start where state already had today's date).
      if(g_day_start_equity <= 0)
         g_day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      return;
     }
   const string prev = g_state.daily_loss_date;
   const double prev_pct = g_state.daily_loss_pct;
   CDailyLossManager::ResetForNewDay(g_state, today);
   g_day_start_equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   g_state.last_save_time = TimeGMT();
   if(!State.Save(g_state, g_state_file))
      Log.Warn("MaybeResetDailyLoss: state save failed");
   Log.Info(StringFormat("Daily-loss reset: %s (was %.2f%%) -> %s start_equity=%.2f",
                          StringLen(prev) > 0 ? prev : "(none)", prev_pct,
                          today, g_day_start_equity));
  }

//+------------------------------------------------------------------+
//| Phase 5: per-bar trade-management orchestrator. Returns true if  |
//| this bar event was consumed by management — caller skips entry   |
//| evaluation for this symbol when true.                            |
//|                                                                  |
//| Steps (closed-bar event for `sym`):                              |
//|   0. If state.open_trade_ticket == 0 -> not managing, return false|
//|   1. Try PositionSelectByTicket. If gone -> resolve close (Task 6)|
//|      then return true (consumed: state changed; no entry).      |
//|   2. If open position is on a different symbol than `sym`, time- |
//|      based exits still apply; BE/trail/Lips need that symbol's   |
//|      M15 bar — fed as zeros so Decide() ignores them.            |
//|   3. Build ManageContext. Call CTradeManager::Decide.            |
//|   4. Dispatch on action: ModifySL / CloseAtMarket. Save state.   |
//+------------------------------------------------------------------+
bool EvaluateOpenPosition(const string sym, const datetime bar_time)
  {
   if(g_state.open_trade_ticket == 0) return false;

   if(!PositionSelectByTicket(g_state.open_trade_ticket))
     {
      Log.Warn(StringFormat("Manage: ticket=%I64u no longer exists — resolving close",
                             g_state.open_trade_ticket));
      ResolveClosedPosition(g_state.open_trade_ticket);   // Task 6 fills body
      g_state.open_trade_ticket   = 0;
      g_state.open_trade_cycle_id = "";
      g_state.last_save_time      = TimeGMT();
      State.Save(g_state, g_state_file);
      return true;
     }

   const string pos_sym  = PositionGetString(POSITION_SYMBOL);
   const long   pos_mag  = PositionGetInteger(POSITION_MAGIC);
   if(pos_mag != Magic_Number)
     {
      Log.Error(StringFormat("Manage: ticket=%I64u magic mismatch (%I64d != %I64d) — clearing state pointer",
                              g_state.open_trade_ticket, pos_mag, Magic_Number));
      g_state.open_trade_ticket   = 0;
      g_state.open_trade_cycle_id = "";
      State.Save(g_state, g_state_file);
      return true;
     }

   const bool same_sym = (pos_sym == sym);

   //--- Time-based exit signals
   const datetime now      = TimeCurrent();
   const int      off      = CurrentNYOffset(now);
   const int      ny_dow   = CSessionTime::NYWeekday(now, off);
   const int      ny_hour  = CSessionTime::NYHour   (now, off);
   const string   ny_date  = CSessionTime::NYDateString(now, off);
   const bool     friday_close = (ny_dow == 5 && ny_hour >= Friday_Close_Hour_NY);
   const string   open_date    = StringSubstr(g_state.open_trade_cycle_id, 0, 8);
   const bool     ny_carryover = (StringLen(open_date) == 8 && open_date != ny_date && ny_hour >= NY_Start_Hour);

   ManageContext mctx;
   mctx.is_buy            = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   mctx.entry             = PositionGetDouble(POSITION_PRICE_OPEN);
   mctx.current_sl        = PositionGetDouble(POSITION_SL);
   mctx.pip               = CMarketFilters::PipSize(pos_sym);
   mctx.be_trigger_R      = BE_Trigger_R;
   mctx.be_buffer_pips    = BE_Buffer_Pips;
   mctx.trail_atr_buffer  = Trail_ATR_Buffer;
   mctx.is_friday_close_time = friday_close;
   mctx.is_ny_open_carryover = ny_carryover;
   mctx.close_m15_s1      = 0;
   mctx.lips_m15_s1       = 0;
   mctx.atr_m15_s1        = 0;
   //--- Phase 8: Lips-break softening params (spec no-op at the input defaults)
   mctx.lips_break_atr_buffer   = LipsBreak_ATR_Buffer;
   mctx.lips_break_confirm_bars = LipsBreak_Confirm_Bars;
   mctx.lips_break_min_hold_bars= LipsBreak_Min_Hold_Bars;
   mctx.bars_since_entry        = 0;
   mctx.close_m15_s2 = 0; mctx.lips_m15_s2 = 0;
   mctx.close_m15_s3 = 0; mctx.lips_m15_s3 = 0;

   if(same_sym)
     {
      mctx.close_m15_s1 = iClose(pos_sym, PERIOD_M15, 1);
      double jaw, teeth, lips;
      if(!Hub.GetAlligator(pos_sym, PERIOD_M15, 1, jaw, teeth, lips))
         Log.Warn("Manage: GetAlligator M15 not ready", pos_sym);
      else
         mctx.lips_m15_s1 = lips;
      double atr;
      if(!Hub.GetATR(pos_sym, 1, atr))
         Log.Warn("Manage: GetATR M15 not ready", pos_sym);
      else
         mctx.atr_m15_s1 = atr;

      //--- bars (M15) since entry — drives LipsBreak_Min_Hold_Bars
      const long secs_held = (long)bar_time - (long)PositionGetInteger(POSITION_TIME);
      mctx.bars_since_entry = (int)(secs_held > 0 ? secs_held / 900 : 0);

      //--- prior closed bars for LipsBreak_Confirm_Bars >= 2/3. Read close +
      //--- matching Lips together; if the Alligator read fails, zero BOTH so
      //--- Decide's "0/0 -> not beyond" path can't misfire.
      if(LipsBreak_Confirm_Bars >= 2)
        {
         double j2, t2, l2;
         if(Hub.GetAlligator(pos_sym, PERIOD_M15, 2, j2, t2, l2))
           { mctx.close_m15_s2 = iClose(pos_sym, PERIOD_M15, 2); mctx.lips_m15_s2 = l2; }
        }
      if(LipsBreak_Confirm_Bars >= 3)
        {
         double j3, t3, l3;
         if(Hub.GetAlligator(pos_sym, PERIOD_M15, 3, j3, t3, l3))
           { mctx.close_m15_s3 = iClose(pos_sym, PERIOD_M15, 3); mctx.lips_m15_s3 = l3; }
        }
     }

   const ManageDecision d = CTradeManager::Decide(mctx);
   if(d.action == MA_NONE)
     {
      if(same_sym)
         Log.Debug(StringFormat("Manage %s @ %s: no-op (sl=%.5f entry=%.5f close=%.5f lips=%.5f)",
                                 pos_sym, TimeToString(bar_time, TIME_MINUTES),
                                 mctx.current_sl, mctx.entry, mctx.close_m15_s1, mctx.lips_m15_s1), pos_sym);
      return true;   // a position is open — suppress entry on every symbol (spec §7)
     }

   //--- Dispatch
   const double tp = PositionGetDouble(POSITION_TP);
   const int    slip = CPositionManager::SlippagePoints(pos_sym,
                          Slippage_FX_Pips, Slippage_Gold_Cents, Slippage_NAS_Points,
                          SymbolInfoDouble(pos_sym, SYMBOL_POINT),
                          CMarketFilters::PipSize(pos_sym));

   bool action_ok = false;
   if(d.action == MA_MOVE_BE || d.action == MA_TRAIL)
     {
      Log.Info(StringFormat("MANAGE %s ticket=%I64u %s -> SL %.5f (%s)",
                             pos_sym, g_state.open_trade_ticket,
                             d.action == MA_MOVE_BE ? "BE" : "TRAIL",
                             d.new_sl, d.reason), pos_sym);
      action_ok = CTradeManager::ModifySL(g_state.open_trade_ticket, d.new_sl, tp);
      if(!action_ok)
         Log.Error(StringFormat("MANAGE ModifySL failed ticket=%I64u", g_state.open_trade_ticket), pos_sym);
     }
   else
     {
      const string label =
         (d.action == MA_CLOSE_LIPS  ) ? "CLOSE_LIPS"   :
         (d.action == MA_CLOSE_FRIDAY) ? "CLOSE_FRIDAY" : "CLOSE_NYOPEN";
      Log.Info(StringFormat("MANAGE %s ticket=%I64u %s slip=%dpts (%s)",
                             pos_sym, g_state.open_trade_ticket, label, slip, d.reason), pos_sym);
      //  Capture floating P/L before the close — POSITION_PROFIT reflects
      //  current unrealized at this moment, close to realized post-fill.
      const double pre_close_profit = PositionGetDouble(POSITION_PROFIT);
      action_ok = CTradeManager::CloseAtMarket(g_state.open_trade_ticket, slip);
      if(action_ok)
        {
         //  Apply streak semantics for forced closes (spec §5.5 / §5.7 / §3.4).
         const EForcedCloseReason fcr =
            (d.action == MA_CLOSE_LIPS)   ? FCR_LIPS_BREAK :
            (d.action == MA_CLOSE_FRIDAY) ? FCR_FRIDAY_CLOSE :
                                            FCR_NY_CARRYOVER;
         CStreakManager::OnForcedClose(g_state, fcr, Max_Streak_Length);
         CDailyLossManager::ApplyRealizedProfit(g_state, pre_close_profit, g_day_start_equity);
         g_state.open_trade_ticket   = 0;
         g_state.open_trade_cycle_id = "";
         Log.Info(StringFormat("    forced-close streak update: position=%d last_sl=%d (fcr=%d) profit=%.2f daily_loss_pct=%.4f%%",
                                g_state.streak_position, g_state.last_sl_count,
                                (int)fcr, pre_close_profit, g_state.daily_loss_pct));
        }
      else
         Log.Error(StringFormat("MANAGE CloseAtMarket failed ticket=%I64u", g_state.open_trade_ticket), pos_sym);
     }

   if(action_ok)
     {
      g_state.last_save_time = TimeGMT();
      State.Save(g_state, g_state_file);
     }

   return true;   // a position is open (or was just closed by us) — no new entry this bar
  }

//+------------------------------------------------------------------+
//| When PositionSelectByTicket fails for a ticket we tracked, the   |
//| broker closed it. Pull the closing deal from history, inspect    |
//| DEAL_REASON, set state.tp_hit_in_cycle if TP. Returns true if    |
//| we resolved the closing reason.                                  |
//|                                                                  |
//| Spec §8.1 (tp_hit_in_cycle), §5.3 (TP ends cycle).               |
//+------------------------------------------------------------------+
bool ResolveClosedPosition(const ulong ticket)
  {
   //--- Pull last 7d of history. Cycle is short-lived; this is plenty.
   const datetime to   = TimeCurrent();
   const datetime from = to - 7 * 24 * 60 * 60;
   if(!HistorySelect(from, to))
     {
      Log.Error(StringFormat("ResolveClosedPosition: HistorySelect failed for ticket=%I64u — streak/daily-loss NOT updated for this close", ticket));
      return false;
     }
   const int n = HistoryDealsTotal();
   for(int i = n - 1; i >= 0; i--)
     {
      const ulong did = HistoryDealGetTicket(i);
      if(did == 0) continue;
      if((ulong)HistoryDealGetInteger(did, DEAL_POSITION_ID) != ticket) continue;
      const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(did, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT) continue;        // closing deal only
      const long   reason = HistoryDealGetInteger(did, DEAL_REASON);
      const double profit = HistoryDealGetDouble (did, DEAL_PROFIT);
      const string sym    = HistoryDealGetString (did, DEAL_SYMBOL);
      const string reason_str =
         (reason == DEAL_REASON_TP)     ? "TP" :
         (reason == DEAL_REASON_SL)     ? "SL" :
         (reason == DEAL_REASON_SO)     ? "SO" :
         (reason == DEAL_REASON_CLIENT) ? "CLIENT" :
         (reason == DEAL_REASON_EXPERT) ? "EXPERT" :
                                          StringFormat("OTHER(%I64d)", reason);
      Log.Info(StringFormat("Resolve: ticket=%I64u %s closed by %s P/L=%.2f",
                             ticket, sym, reason_str, profit));
      //  Phase 6: feed realized P/L into daily-loss counter (loss-only).
      //  Skip DEAL_REASON_EXPERT — EvaluateOpenPosition's MA_CLOSE_* branch
      //  already called ApplyRealizedProfit using POSITION_PROFIT before the
      //  close. This guard makes the invariant structural, not just flow-order.
      if(reason != DEAL_REASON_EXPERT)
        {
         CDailyLossManager::ApplyRealizedProfit(g_state, profit, g_day_start_equity);
         if(profit < 0)
            Log.Info(StringFormat("Resolve: daily_loss_pct -> %.4f%% (after %.2f loss)",
                                   g_state.daily_loss_pct, profit));
        }
      if(reason == DEAL_REASON_TP)
        {
         CStreakManager::OnTPClose(g_state);
         Log.Info("Resolve: TP -> cycle locked (mode now LOCKED)");
        }
      else if(reason == DEAL_REASON_SL)
        {
         CStreakManager::OnSLClose(g_state, Max_Streak_Length);
         const ETradingMode m = CStreakManager::DeriveMode(g_state, Max_Streak_Length);
         Log.Info(StringFormat("Resolve: SL -> streak_position=%d last_sl=%d mode=%s",
                                g_state.streak_position, g_state.last_sl_count,
                                m == MODE_LOCKED ? "LOCKED" :
                                (m == MODE_RECOVERY ? "RECOVERY" : "DEFAULT")));
        }
      else if(reason == DEAL_REASON_EXPERT)
        {
         //  Our own forced close — Lips break / Friday flatten / NY carryover.
         //  The forced-close branch in EvaluateOpenPosition already advanced
         //  state via CStreakManager::OnForcedClose; nothing to do here.
         Log.Info("Resolve: EA-side forced close (already accounted)");
        }
      return true;
     }
   Log.Warn(StringFormat("ResolveClosedPosition: no closing deal found for ticket=%I64u in last 7d", ticket));
   return false;
  }

//+------------------------------------------------------------------+
//| Phase 6: NY-aware cycle id "YYYYMMDD_NY" computed from NY date   |
//| of the current instant. The cycle changes when NY date does AND  |
//| we're past NY_Start_Hour — handled by MaybeRolloverCycle.        |
//+------------------------------------------------------------------+
string CycleIdNow()
  {
   const datetime now = TimeCurrent();
   const int      off = CurrentNYOffset(now);
   return CSessionTime::NYDateString(now, off) + "_NY";
  }

//+------------------------------------------------------------------+
//| Spec §4.8: skip entries when the nearest opposing S/R level is   |
//| within block_pips of the entry price. Scans H1 + H4 levels.      |
//| Returns true (= room) when no level closer than block_pips.      |
//+------------------------------------------------------------------+
bool SRRoomToTP(const string sym, const ESignalKind kind,
                const double entry, const double atr, const int block_pips)
  {
   const double pip         = CMarketFilters::PipSize(sym);
   const double block_price = block_pips * pip;
   const bool   is_buy      = (kind == SIGNAL_TYPE_A_BUY || kind == SIGNAL_TYPE_B_BUY);

   ENUM_TIMEFRAMES tfs[2]   = { PERIOD_H1, PERIOD_H4 };
   int             looks[2] = { SR_Lookback_Bars_1H, SR_Lookback_Bars_4H };

   double nearest_dist = DBL_MAX;
   for(int t = 0; t < 2; t++)
     {
      double res[], sup[]; int rs[], ss[];
      if(!CSRDetector::Build(sym, tfs[t], looks[t], SR_Swing_Bars_Each_Side, atr,
                             res, rs, sup, ss))
         continue;
      if(is_buy)
        {
         for(int i = 0; i < ArraySize(res); i++)
           {
            const double d = res[i] - entry;
            if(d > 0 && d < nearest_dist) nearest_dist = d;
           }
        }
      else
        {
         for(int i = 0; i < ArraySize(sup); i++)
           {
            const double d = entry - sup[i];
            if(d > 0 && d < nearest_dist) nearest_dist = d;
           }
        }
     }
   if(nearest_dist == DBL_MAX) return true;     // no level → no block
   return nearest_dist >= block_price;
  }

//+------------------------------------------------------------------+
//| Maps a resolved broker symbol back to its canonical input name,  |
//| for spread-limit lookup. g_canonical and g_symbols are parallel. |
//+------------------------------------------------------------------+
int CanonicalIndex(const string broker_sym)
  {
   for(int i = 0; i < ArraySize(g_symbols); i++)
      if(g_symbols[i] == broker_sym) return i;
   return -1;
  }

//+------------------------------------------------------------------+
//| One-shot ADX snapshot, logged at OnInit.                         |
//+------------------------------------------------------------------+
void LogADXSnapshot()
  {
   ADXSnapshot snap[]; ADXSnapshot ranked[];
   CSymbolPrioritizer::Snapshot(GetPointer(Hub), g_symbols, snap);
   const int total = ArraySize(snap);
   const int above = CSymbolPrioritizer::RankByADX(snap, total, Min_ADX_1H, ranked);
   Log.Info(StringFormat("ADX snapshot: %d/%d symbol(s) >= %.1f", above, total, Min_ADX_1H));
   for(int i = 0; i < ArraySize(ranked); i++)
      Log.Info(StringFormat("  %2d. %-10s ADX=%6.2f %s",
                            i + 1, ranked[i].sym, ranked[i].adx,
                            ranked[i].valid ? "" : "(no data)"));
  }

//+------------------------------------------------------------------+
//| Input sanity checks (spec §14 reminder #10)                      |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   if(Risk_Position1 <= 0 || Risk_Position1 >= 100) { Log.Error("Risk_Position1 must be in (0,100)"); return false; }
   if(Risk_Position2 <= 0 || Risk_Position2 >= 100) { Log.Error("Risk_Position2 must be in (0,100)"); return false; }
   if(Risk_Position3 <= 0 || Risk_Position3 >= 100) { Log.Error("Risk_Position3 must be in (0,100)"); return false; }
   if(Max_Daily_Loss <= 0)                          { Log.Error("Max_Daily_Loss must be > 0");        return false; }
   if(Max_Streak_Length < 1)                        { Log.Error("Max_Streak_Length must be >= 1");    return false; }
   if(Max_Total_DD_Buffer <= 0)                     { Log.Error("Max_Total_DD_Buffer must be > 0");   return false; }
   if(ATR_Period < 2)                               { Log.Error("ATR_Period must be >= 2");           return false; }
   if(ADX_Period < 2)                               { Log.Error("ADX_Period must be >= 2");           return false; }
   if(Jaw_Period < 1 || Teeth_Period < 1 || Lips_Period < 1)
                                                    { Log.Error("Alligator periods must be >= 1");    return false; }
   if(NY_Start_Hour < 0 || NY_Start_Hour > 23 ||
      NY_End_Hour   < 0 || NY_End_Hour   > 23 ||
      NY_End_Hour <= NY_Start_Hour)
                                                    { Log.Error("NY hours invalid");                  return false; }
   if(SR_Lookback_Bars_1H < 10 || SR_Lookback_Bars_4H < 5)
                                                    { Log.Error("SR lookback too small");             return false; }
   if(SR_Swing_Bars_Each_Side < 1)                  { Log.Error("SR_Swing_Bars_Each_Side must be >= 1"); return false; }
   if(HA_Wick_Tolerance_Pips < 0)                   { Log.Error("HA_Wick_Tolerance_Pips must be >= 0"); return false; }
   if(Min_ATR_Ratio <= 0 || Min_ATR_Ratio >= 1)     { Log.Error("Min_ATR_Ratio must be in (0,1)");    return false; }
   if(StringLen(Trade_Symbols) == 0)                { Log.Error("Trade_Symbols is empty");            return false; }
   if(StringLen(State_File_Name) == 0)              { Log.Error("State_File_Name is empty");          return false; }
   if(LipsBreak_ATR_Buffer < 0)                     { Log.Error("LipsBreak_ATR_Buffer must be >= 0"); return false; }
   if(LipsBreak_Confirm_Bars < 1 || LipsBreak_Confirm_Bars > 3) { Log.Error("LipsBreak_Confirm_Bars must be 1..3"); return false; }
   if(LipsBreak_Min_Hold_Bars < 0)                  { Log.Error("LipsBreak_Min_Hold_Bars must be >= 0"); return false; }
   if(Min_SL_ATR_Mult < 0)                          { Log.Error("Min_SL_ATR_Mult must be >= 0");      return false; }
   if(Max_Lot <= 0)                                 { Log.Error("Max_Lot must be > 0");               return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| Parse CSV → resolve broker names → populate g_symbols.           |
//+------------------------------------------------------------------+
bool ResolveSymbols()
  {
   string canonical[];
   const int n = Resolver.ParseCsv(Trade_Symbols, canonical);
   if(n == 0)
     {
      Log.Error("Trade_Symbols parsed to zero entries");
      return false;
     }
   Log.Info(StringFormat("Parsed %d symbol(s) from input", n));

   string resolved[], missing[];
   const bool all_ok = Resolver.ResolveAll(canonical, resolved, missing);

   for(int i = 0; i < n; i++)
     {
      if(resolved[i] != "")
        {
         if(resolved[i] == canonical[i])
            Log.Info(StringFormat("  %-10s → (exact match)", canonical[i]));
         else
            Log.Info(StringFormat("  %-10s → %s", canonical[i], resolved[i]));
        }
     }

   if(!all_ok)
     {
      string list = "";
      for(int i = 0; i < ArraySize(missing); i++)
         list += (i > 0 ? ", " : "") + missing[i];
      Log.Error("Unresolved symbols: " + list);
      Log.Error("Either remove them from Trade_Symbols input or check the broker's catalog (right-click MarketWatch → Symbols).");
      return false;
     }

   ArrayResize(g_symbols, n);
   ArrayResize(g_canonical, n);
   ArrayResize(g_last_m15_bar, n);
   for(int i = 0; i < n; i++)
     {
      g_symbols[i] = resolved[i];
      g_canonical[i] = canonical[i];
      g_last_m15_bar[i] = 0;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Pull spread limits out of inputs into the struct used by         |
//| MarketFilters lookup (so the inputs stay file-scoped to main).   |
//+------------------------------------------------------------------+
void PopulateSpreadLimits()
  {
   g_spread_limits.EURUSD = Spread_EURUSD;
   g_spread_limits.GBPUSD = Spread_GBPUSD;
   g_spread_limits.USDJPY = Spread_USDJPY;
   g_spread_limits.USDCHF = Spread_USDCHF;
   g_spread_limits.AUDUSD = Spread_AUDUSD;
   g_spread_limits.USDCAD = Spread_USDCAD;
   g_spread_limits.NZDUSD = Spread_NZDUSD;
   g_spread_limits.XAUUSD = Spread_XAUUSD;
   g_spread_limits.NAS100 = Spread_NAS100;
  }

//+------------------------------------------------------------------+
//| Phase 2 diagnostic block. Prints once per new M15 bar, per       |
//| symbol. Phase 3 will replace this with the signal evaluator.     |
//+------------------------------------------------------------------+
void DumpDiagnostics(const int idx, const datetime bar_time)
  {
   if(!Verbose_Logging) return;

   const string sym  = g_symbols[idx];
   const string canon = g_canonical[idx];

   //--- Alligator M15 (closed candle = shift 1)
   double jaw_m, teeth_m, lips_m;
   const bool ok_alm = Hub.GetAlligator(sym, PERIOD_M15, 1, jaw_m, teeth_m, lips_m);

   //--- Alligator H1
   double jaw_h, teeth_h, lips_h;
   const bool ok_alh = Hub.GetAlligator(sym, PERIOD_H1, 1, jaw_h, teeth_h, lips_h);

   //--- ATR M15 + ratio (current vs avg of previous 20)
   double atr_now = 0;
   const bool ok_atr = Hub.GetATR(sym, 1, atr_now);
   double atr_series[];
   const bool ok_atr_s = Hub.GetATRSeries(sym, 1, 21, atr_series);
   //  CopyBuffer (non-series) returns oldest at [0], newest at [count-1].
   //  IsDeadMarket convention: [0]=current, [1..n-1]=history. Flip the array.
   double atr_flip[];
   double atr_ratio = 0;
   bool   is_dead = false;
   if(ok_atr_s && ArraySize(atr_series) == 21)
     {
      ArrayResize(atr_flip, 21);
      for(int k = 0; k < 21; k++) atr_flip[k] = atr_series[20 - k];
      double sum = 0;
      for(int k = 1; k < 21; k++) sum += atr_flip[k];
      const double mean = sum / 20.0;
      atr_ratio = (mean > 0) ? atr_flip[0] / mean : 0;
      is_dead   = CMarketFilters::IsDeadMarket(atr_flip, 21, Min_ATR_Ratio);
     }

   //--- ADX 1H
   double adx = 0;
   const bool ok_adx = Hub.GetADX1H(sym, 1, adx);

   //--- HA last 2 closed candles (shift 2 oldest, shift 1 newest)
   double ha_o[], ha_h[], ha_l[], ha_c[];
   const bool ok_ha = CHeikenAshi::GetClosed(sym, PERIOD_M15, 1, 2, ha_o, ha_h, ha_l, ha_c);
   //  After GetClosed: index 0 = older (shift 2), index 1 = newer (shift 1).
   string ha_summary = "n/a";
   if(ok_ha && ArraySize(ha_c) == 2)
     {
      const string c1 = (ha_c[0] >= ha_o[0]) ? "G" : "R";
      const string c2 = (ha_c[1] >= ha_o[1]) ? "G" : "R";
      ha_summary = StringFormat("[%s,%s] body2=%.5f", c1, c2, MathAbs(ha_c[1] - ha_o[1]));
     }

   //--- Spread vs limit
   double limit_pips = 0;
   const bool ok_lim = CMarketFilters::LookupSpreadLimit(canon, g_spread_limits, limit_pips);
   double cur_pips = 0;
   const bool ok_cur = CMarketFilters::CurrentSpreadPips(sym, cur_pips);
   const bool spread_ok = (ok_lim && ok_cur) ? (cur_pips <= limit_pips) : false;

   //--- S/R levels: only rebuild on hour boundaries to keep log readable.
   //--- bar_time is server time; "%3600==0" matches H1 boundaries on M15 closes.
   bool sr_run = ((long)bar_time % 3600 == 0);
   int n_res_h1 = 0, n_sup_h1 = 0, n_res_h4 = 0, n_sup_h4 = 0;
   if(sr_run && ok_atr && atr_now > 0)
     {
      double res[], sup[]; int rs[], ss[];
      if(CSRDetector::Build(sym, PERIOD_H1, SR_Lookback_Bars_1H, SR_Swing_Bars_Each_Side, atr_now, res, rs, sup, ss))
        { n_res_h1 = ArraySize(res); n_sup_h1 = ArraySize(sup); }
      if(CSRDetector::Build(sym, PERIOD_H4, SR_Lookback_Bars_4H, SR_Swing_Bars_Each_Side, atr_now, res, rs, sup, ss))
        { n_res_h4 = ArraySize(res); n_sup_h4 = ArraySize(sup); }
     }

   //--- Print one compact block per symbol per new M15 bar.
   Log.Info(StringFormat("──── %s @ %s ────", sym, TimeToString(bar_time, TIME_DATE|TIME_MINUTES)));
   if(ok_alm) Log.Info(StringFormat("  AllM15 J=%.5f T=%.5f L=%.5f", jaw_m, teeth_m, lips_m), sym);
   else       Log.Warn ("  AllM15: data not ready", sym);
   if(ok_alh) Log.Info(StringFormat("  AllH1  J=%.5f T=%.5f L=%.5f", jaw_h, teeth_h, lips_h), sym);
   else       Log.Warn ("  AllH1: data not ready",  sym);
   if(ok_atr_s) Log.Info(StringFormat("  ATR    now=%.5f ratio=%.2f dead=%s",
                                       atr_now, atr_ratio, is_dead ? "YES" : "no"), sym);
   else         Log.Warn ("  ATR series: data not ready", sym);
   if(ok_adx) Log.Info(StringFormat("  ADX1H  %.2f (min=%.1f)", adx, Min_ADX_1H), sym);
   else       Log.Warn ("  ADX1H: data not ready", sym);
   Log.Info(StringFormat("  HA     %s", ha_summary), sym);
   if(ok_cur && ok_lim)
      Log.Info(StringFormat("  Spread %.2f / %.2f pips %s", cur_pips, limit_pips,
                            spread_ok ? "OK" : "WIDE"), sym);
   else
      Log.Warn ("  Spread: lookup failed", sym);
   if(sr_run)
      Log.Info(StringFormat("  S/R    H1: %d res / %d sup, H4: %d res / %d sup",
                            n_res_h1, n_sup_h1, n_res_h4, n_sup_h4), sym);
  }

//+------------------------------------------------------------------+
//| Per-magic state filename so multiple EA instances don't collide. |
//+------------------------------------------------------------------+
string MakeStateFilename()
  {
   const int dot = StringFind(State_File_Name, ".", 0);
   if(dot < 0)
      return StringFormat("%s_%I64d", State_File_Name, Magic_Number);
   const string base = StringSubstr(State_File_Name, 0, dot);
   const string ext  = StringSubstr(State_File_Name, dot, -1);
   return StringFormat("%s_%I64d%s", base, Magic_Number, ext);
  }

//+------------------------------------------------------------------+
//| Broker's *current* GMT offset, recomputed each call. In the MT5   |
//| Strategy Tester some builds return TimeGMT()==TimeTradeServer()   |
//| (offset 0); IC Markets is an EU server (GMT+2 winter / +3 summer),|
//| so derive from the EU-DST calendar in that case. Live always uses |
//| the real TimeGMT(). (invariant #6/#14)                            |
//+------------------------------------------------------------------+
int CurrentBrokerGMTOffsetHr(const datetime now)
  {
   //--- (long) cast first so a broker behind GMT (a < b on unsigned datetime)
   //--- doesn't wrap to a garbage value before the divide.
   int off = (int)MathRound((double)((long)(TimeTradeServer() - TimeGMT())) / 3600.0);
   if(off == 0 && MQLInfoInteger(MQL_TESTER))
     {
      MqlDateTime s; TimeToStruct(now, s);
      off = CSessionTime::IsBrokerInDST(s.year, s.mon, s.day) ? 3 : 2;
     }
   return off;
  }

//+------------------------------------------------------------------+
//| Returns the server→NY offset for `now`. If Server_To_NY_Offset_  |
//| Hours is non-zero, that input wins (manual override). Otherwise  |
//| auto-derived via DST helpers; broker GMT offset recomputed live. |
//+------------------------------------------------------------------+
int CurrentNYOffset(const datetime now)
  {
   if(Server_To_NY_Offset_Hours != 0) return Server_To_NY_Offset_Hours;
   return CSessionTime::DeriveOffsetHours(now, CurrentBrokerGMTOffsetHr(now));
  }
//+------------------------------------------------------------------+
