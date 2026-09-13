// anticheat_macro.sp - Generic macro/scripted-input detector for L4D2
// Anti-Cheat.
//
// Every other detector in this project watches a SPECIFIC behavior (aim,
// bhop, shot trajectory). This one is deliberately generic: it watches
// the press/release timing of any of a small set of action buttons that
// have nothing to do with aim or movement - IN_USE (heal/give pills/open
// doors), IN_RELOAD, and IN_ATTACK2 (secondary fire/shove) - and flags
// a player whose hold duration or repeat interval on that button is
// suspiciously IDENTICAL tick after tick. A human finger never presses
// and releases a key for the exact same number of ticks over and over;
// a keyboard macro (AHK, a script, a macro-capable mouse/keyboard) does
// exactly that, because it's timed by code instead of a nerve impulse.
//
// This catches macro users who aren't even trying to aimbot - someone
// automating healing/door-opening/reload-canceling for a reaction-time
// edge, which the aim and bhop modules have no reason to ever see.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>

// ------------------------------------------------------------------
// One ring buffer per tracked button, storing how many ticks each press
// was held for. A human's hold duration on the same button varies
// noticeably press to press (different reaction, different intent); a
// macro replays the exact same hold length script after script.
#define MACRO_HISTORY 20
#define MACRO_MIN_SAMPLES 12
#define MACRO_MIN_HOLD_TICKS 2      // presses shorter than this are noise/mis-clicks, not a judgeable hold
#define MACRO_IDENTICAL_TOLERANCE 0 // hold durations within this many ticks of the mode count as "identical"
#define MACRO_IDENTICAL_RATIO 0.85  // this fraction of holds landing on the same duration is the tell

enum MacroButton
{
    MACROBTN_USE = 0,
    MACROBTN_RELOAD,
    MACROBTN_ATTACK2,
    MACROBTN_COUNT
};

int  g_MacroButtonFlags[MacroButton] = { IN_USE, IN_RELOAD, IN_ATTACK2 };

int   g_MacroHoldTicks[MAXPLAYERS+1][MacroButton][MACRO_HISTORY];
int   g_MacroHead[MAXPLAYERS+1][MacroButton];
int   g_MacroCount[MAXPLAYERS+1][MacroButton];
int   g_MacroCurrentHold[MAXPLAYERS+1][MacroButton];
bool  g_MacroWasHeld[MAXPLAYERS+1][MacroButton];
float g_MacroLastEventTime[MAXPLAYERS+1][MacroButton];

void Macro_Init(int client)
{
    for (int b = 0; b < view_as<int>(MACROBTN_COUNT); b++)
    {
        g_MacroHead[client][b] = 0;
        g_MacroCount[client][b] = 0;
        g_MacroCurrentHold[client][b] = 0;
        g_MacroWasHeld[client][b] = false;
        g_MacroLastEventTime[client][b] = 0.0;
    }
}

// ------------------------------------------------------------------
// Called every tick from OnPlayerRunCmd.
void Macro_RecordTick(int client, int buttons)
{
    for (int b = 0; b < view_as<int>(MACROBTN_COUNT); b++)
    {
        bool held = (buttons & g_MacroButtonFlags[b]) != 0;

        if (held)
        {
            g_MacroCurrentHold[client][b]++;
            g_MacroWasHeld[client][b] = true;
            continue;
        }

        if (!g_MacroWasHeld[client][b]) continue; // wasn't held last tick either - nothing just ended

        int holdTicks = g_MacroCurrentHold[client][b];
        g_MacroCurrentHold[client][b] = 0;
        g_MacroWasHeld[client][b] = false;
        if (holdTicks < MACRO_MIN_HOLD_TICKS) continue;

        int idx = g_MacroHead[client][b];
        g_MacroHoldTicks[client][b][idx] = holdTicks;
        g_MacroHead[client][b] = (idx + 1) % MACRO_HISTORY;
        if (g_MacroCount[client][b] < MACRO_HISTORY) g_MacroCount[client][b]++;

        Macro_JudgeButton(client, b);
    }
}

// ------------------------------------------------------------------
// A human's press-hold duration on a given action key is noisy - it
// varies with reaction time, intent, and hand fatigue. A macro-driven
// key replays the exact same hold length over and over because it's
// timed by a script, not a nerve impulse. This looks for the most common
// hold duration in the recent history and checks how large a share of
// all presses landed on (or within tolerance of) exactly that value.
static void Macro_JudgeButton(int client, int b)
{
    int total = g_MacroCount[client][b];
    if (total < MACRO_MIN_SAMPLES) return;

    // Find the mode (most frequent hold duration) by brute-force counting
    // - MACRO_HISTORY is small (20), so this is cheap.
    int bestValue = -1;
    int bestCount = 0;
    for (int i = 0; i < total; i++)
    {
        int v = g_MacroHoldTicks[client][b][i];
        int c = 0;
        for (int j = 0; j < total; j++)
        {
            int diff = g_MacroHoldTicks[client][b][j] - v;
            if (diff < 0) diff = -diff;
            if (diff <= MACRO_IDENTICAL_TOLERANCE) c++;
        }
        if (c > bestCount) { bestCount = c; bestValue = v; }
    }
    if (bestValue < 0) return;

    float ratio = float(bestCount) / float(total);
    if (ratio < MACRO_IDENTICAL_RATIO) return;

    float now = GetGameTime();
    if (now - g_MacroLastEventTime[client][b] < 5.0) return; // don't re-fire every single qualifying press
    g_MacroLastEventTime[client][b] = now;

    // Severity: tighter clustering and a longer confirmed sample are both
    // stronger evidence.
    int severity = RoundFloat(45.0 + (ratio - MACRO_IDENTICAL_RATIO) / (1.0 - MACRO_IDENTICAL_RATIO) * 40.0 + float(total - MACRO_MIN_SAMPLES));
    Correlation_ReportEvent(client, CORR_DET_MACRO, severity);
}

// ------------------------------------------------------------------
int Macro_GetScore(int client)
{
    int best = 0;
    float now = GetGameTime();
    for (int b = 0; b < view_as<int>(MACROBTN_COUNT); b++)
    {
        int total = g_MacroCount[client][b];
        if (total < MACRO_MIN_SAMPLES) continue;

        int bestValue = -1;
        int bestCount = 0;
        for (int i = 0; i < total; i++)
        {
            int v = g_MacroHoldTicks[client][b][i];
            int c = 0;
            for (int j = 0; j < total; j++)
            {
                int diff = g_MacroHoldTicks[client][b][j] - v;
                if (diff < 0) diff = -diff;
                if (diff <= MACRO_IDENTICAL_TOLERANCE) c++;
            }
            if (c > bestCount) { bestCount = c; bestValue = v; }
        }
        if (bestValue < 0) continue;

        float ratio = float(bestCount) / float(total);
        if (ratio < MACRO_IDENTICAL_RATIO) continue;
        // Only count this button toward the score while a recent
        // confirmed event exists for it - avoids scoring off a stale
        // pattern from long ago that Macro_JudgeButton already reported
        // once and moved past.
        if (now - g_MacroLastEventTime[client][b] > 600.0) continue;

        float score = 45.0 + (ratio - MACRO_IDENTICAL_RATIO) / (1.0 - MACRO_IDENTICAL_RATIO) * 40.0 + float(total - MACRO_MIN_SAMPLES);
        if (score > 100.0) score = 100.0;
        if (RoundFloat(score) > best) best = RoundFloat(score);
    }
    return best;
}
