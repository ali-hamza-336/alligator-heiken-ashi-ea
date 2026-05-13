# Path A — Stages 3-5 Roadmap (post-Stage-2)

**Date:** 2026-05-13  **Status:** sketch — each stage gets its own brainstorm at its gate, not now
**Context:** Captures the broader Path-A thinking surfaced during the Stage-2 brainstorm. Stage 2 (exits) is the immediate ship — see [docs/2026-05-13-path-a-stage2.md](2026-05-13-path-a-stage2.md). The point of this file is to record the full menu of improvement levers so we don't lose them, NOT to lock in the next-stage scope (we decide that after Stage 2 re-baselines).

## Where we are (updated 2026-05-14)

- **Stage 1: ✅ shipped** (commit `76cd8f6` — spread defaults, SL-distance floor, symbol cull → −5.24% to −4.40%)
- **Stage 1.1: ✅ shipped** (commit `7fff5ae` — SL-side guard, drop NAS100, `Min_SL_ATR_Mult 1.0→0.3` → **+2.47%, first profitable config**)
- **Stage 2 Tasks A, B, C: ✅ shipped** (commits `9a5d183`, `5140924`, `72a7032`, `dd87453` — state schema, `PartialLot` helper, `TightenLipsPrice` + Decide rewrite)
- **Stage 2 Tasks D, E: ⏳ pending** (EA wiring + re-baseline backtest — next session)

Post-Stage-2 the working success bar from [CLAUDE.md](../CLAUDE.md) is "consistently profitable on the 12-mo sample with margin." Stage 1.1 already crosses breakeven (+2.47%, PF 1.046) but is well short of spec §11.2's PF > 1.5 target — Stage 2 (the exit rework) is intended to lift PF meaningfully. If Stage 2 hits the bar, we stop and forward-test. If marginal/underwater, Stage 3.

### Important shift from Stage 1.1: swap drag essentially disappeared

Stage 1's −4.40% included ~$1k/yr swap (multi-day Type-B swing trades accruing overnight financing). Stage 1.1 inadvertently shifted the trade mix from Type-B-dominant to Type-A-dominant (`Min_SL_ATR_Mult 1.0→0.3` unblocked ~93 net new Type-A "mouth opens" entries that close intraday). Result: total swap dropped from ~$1k to **−$3.73 for the entire 12 months**. Avg hold time collapsed from multi-day to 1h 30min; 96.8% of trades close on the same calendar day. This re-prioritizes the roadmap — see Stage 5 update below.

## Stage 3 — Entry quality

**Goal:** trade fewer setups, with higher conviction. Current entry logic admits too many low-confidence trades that bleed out before reaching +1R; tighter filters reduce the base rate of losing trades.

**Audit-identified weaknesses in current entries:**
- Type A (mouth-opens) fires on Alligator alone — does NOT check whether Heiken Ashi candles agree (Type B does)
- `Min_ADX_1H` is a *soft* per-symbol gate (any symbol with ADX ≥ 20 passes) — does not enforce trading only top-N symbols
- 1H Alligator filter is *soft* (only rejects clean opposite-trend); H4 trend is not checked at all
- `SR_Block_Distance_Pips = 10` is in fixed pips — wrong unit on XAUUSD (ATR 250+) and indices

**Candidate sub-changes (brainstorm at the gate):**
1. **HA-confirm Type A** — require last 1-2 HA candles to agree with direction. Cheap, mechanical.
2. **Hard ADX filter** — either raise threshold (20 → 25 or 30) OR restrict to top-N symbols by ADX rank at session open.
3. **H4 trend confirmation** — H4 Alligator or H4 EMA-50 must agree with trade direction. Catches counter-trend M15 fakeouts.
4. **ATR-scale the S/R block** — `Distance ≥ N×ATR` (default 0.5×ATR) instead of fixed pips. Makes the rule mean the same thing across all symbols.

**Expected effect:** roughly 20-30% fewer trades per month, higher win rate on what fires. Net P/L could go either way depending on which trades the filters cull.

**Brainstorm before implementing:** which sub-changes to bundle. Filters interact — adding all four at once removes too many setups; cherry-picking risks over-fitting.

## Stage 4 — Symbols, sessions, risk progression

**Goal:** tune the macro knobs after Stages 2 + 3 have settled. Three independent sub-levers; each gets its own decision.

### 4a — Symbol set finalization
Stage 1 already culled USDCAD + AUDUSD; Stage 1.1 drops NAS100. Remaining 6: EURUSD, GBPUSD, USDJPY, USDCHF, NZDUSD, XAUUSD. After Stages 2 + 3 re-baseline:
- Re-evaluate XAUUSD (high spread + high swap; weird R:R math because pip values are different from FX)
- Consider re-adding a previously culled symbol if Stage-2 exit logic makes it viable
- Or restrict to top 3-4 by PF/win-rate on the new backtest

**Coupling caveat:** the global single-trade rule (invariant #9) means per-symbol P/L isn't independent — re-shuffling the basket reshuffles every other symbol's trade sequence. Pick the symbol set *holistically* on the re-baseline data, not by per-symbol P/L in isolation.

### 4b — Session windows
Currently NY 08:00-15:00 (Default mode); Recovery mode opens Tokyo + London + NY. Options:
- Restrict to NY 08:00-12:00 only (first 4 hours, peak liquidity)
- Expand Default mode to London 03:00-08:00 NY + NY (more setups, more spread cost)
- Keep current

Decision driven by whatever the Stage-2/3 backtest shows about win-rate-by-hour.

### 4c — Risk progression
Currently `{0.30%, 0.50%, 0.70%}` on consecutive losing trades (light martingale, spec §2.3). On a losing streak this AMPLIFIES the drawdown. Options:
- Flatten to `{0.30%, 0.30%, 0.30%}` (no progression — kills the amplification)
- Taper to `{0.30%, 0.20%, 0.10%}` (anti-martingale — reduces risk on consecutive losses)
- Keep current

Decision driven by the Stage-2/3 max-DD and losing-streak distribution.

## Stage 5 — Swap mitigation (conditional — likely unnecessary after Stage 1.1)

**Status update (2026-05-14):** Stage 1.1 inadvertently collapsed total swap from ~$1k/yr to **−$3.73/yr** by shifting the trade mix to Type-A intraday entries (96.8% same-day exits, avg hold 1h 30min). Stage 5 is now **most likely unnecessary** — the originally-targeted problem is essentially gone. Re-evaluate only if Stage 2's no-TP runners reintroduce multi-day holds and swap climbs back over ~$1k/yr in the re-baseline.

**Goal:** add a hard time cap on positions if Stage 2's no-TP runners are accumulating significant swap. Only deployed if the data says it's needed.

**Trigger:** Stage 2 backtest shows swap > ~$1k/year on $100k (i.e. >1% of equity, materially worse than Stage 1.1's ~$0/yr).

**Change:** new input `Max_Hold_Bars` (default off — `0` = no cap; tuned value e.g. `384` = 4 days of M15 bars). When `bars_since_entry ≥ Max_Hold_Bars`, force-close at market in `EvaluateOpenPosition`'s existing forced-close branch (new action `MA_CLOSE_MAX_HOLD`, priority below Friday but above partial/tighten/trail).

**Risk:** loses some big-runner upside (a trade that would have made +5R over 5 days closes early at whatever the trail had locked in). Acceptable if swap is otherwise eating the profits — but with Stage 1.1's intraday profile, this is no longer the lever it was when Path A started.

## Sequencing logic

Stages are ordered so each one informs the next:

1. **Stage 2 (exits) first** — biggest known bleed; fixes the architectural R:R asymmetry. Fixing exits without changing entries lets us measure the exit impact cleanly.
2. **Stage 3 (entries) second** — better entries become more valuable once exits don't bleed. (The reverse order would mean tightening entries but still losing to Lips chop.)
3. **Stage 4 (macro tuning) third** — symbol / session / risk-progression tuning depends on the new entry+exit behaviour; premature tuning gets undone by Stages 2 + 3.
4. **Stage 5 (swap) last and conditional** — defensive lever; only deployed if Stage 2's no-TP design introduces a swap problem.

Each stage = re-baseline first, decide whether to proceed, then own brainstorm → design doc → execution plan → ship → re-baseline. Don't bundle Stages 2 + 3 + 4 into one sprint — attribution gets impossible.

## Honest expected outcome (updated 2026-05-14)

Path-A progress so far:
- Spec §9 verbatim: −5.24% (9-symbol)
- + Lips-break softening (3 knobs, optimized): −5.24% basket / −0.28% EURUSD
- + Stage 1 (cheap fixes): −4.40% (7-symbol effective; NAS100 never traded)
- + Stage 1.1 (drop NAS100, SL-side guard, `Min_SL_ATR_Mult 0.3`): **+2.47%** (6-symbol, 12-mo). First profitable config — but PF 1.046, well short of spec §11.2's PF > 1.5 target. Driver: `Min_SL_ATR_Mult 0.3` unblocked ~93 net Type-A trades, mostly intraday, collapsing swap drag to zero.
- + Stage 2 Tasks A/B/C (code shipped, no Decide-behavior change yet at runtime): Tests green. Awaiting Task D + E to actually exercise the new behavior in a backtest.

Stage 2 is the first deep edge-work (vs. the prior tunes + cleanups), so it's reasonable to hope for a step-change in PF. But the strategy may still be marginal on this 12-month sample even after the rework. If Task E re-baselines flat-to-marginal (similar PF, similar bottom-line), Stage 3 (entry tightening — HA-confirm Type A is the cheapest first move) is the next lever. If after Stage 3 we're still under PF > 1.5, the right call is to **stop tuning, not keep going**.

The user's bar: "consistently profitable on the 12-mo sample with margin" — ideally meeting spec §11.2 (PF > 1.5, max DD < 8%, ~3-7 wins/month, no FTMO breach). Stage 1.1 cleared "profitable" but not "with margin"; Stage 2 must lift PF materially (probably to 1.25+) for the result to be defensible. One year is a small sample.

## Pointers

- Execution plan for Stage 2: `~/.claude/plans/continue-path-a-lets-radiant-muffin.md`
- Stage 2 design: [docs/2026-05-13-path-a-stage2.md](2026-05-13-path-a-stage2.md)
- Stage 1 design: [docs/2026-05-12-path-a-stage1.md](2026-05-12-path-a-stage1.md)
- Lips-break softening (Phase-8): [docs/2026-05-12-lips-break-exit-softening.md](2026-05-12-lips-break-exit-softening.md)
- Project canonical status: [CLAUDE.md](../CLAUDE.md)
- Original spec: [EA_Action_Plan.md](../EA_Action_Plan.md) (architecture / FTMO / state / edges hold; params + strategy details advisory under Path A)
