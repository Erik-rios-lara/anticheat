// anticheat_correlation.sp - Cross-Detector Correlation Engine
//
// Every detector module in this project computes its own 0-100 score in
// isolation. anticheat_core.sp then combines those scores with FIXED
// WEIGHTS (a plain weighted sum). That is a reasonable baseline, but it
// treats "one detector mildly suspicious" and "three independent
// detectors all firing in the same half-second" as differing only by
// magnitude - never by the fact that independent evidence lining up in
// time is qualitatively stronger than the same total score spread thin.
//
// This module adds a correlation LAYER on top, without changing how any
// individual detector computes its own score:
//
//   1. Detectors call Correlation_ReportEvent() at the moment they record
//      a RAW candidate event (a snap, a spike, a confirmed lock, a bad
//      landing, etc.) - the same moment they already write into their own
//      ring buffer. This is one extra line per call site; no detector's
//      internal scoring logic is touched.
//
//   2. Each report carries a small evidence record: which detector fired,
//      when, and how severe that single event was (0-100, on the same
//      scale detectors already use for their sub-events).
//
//   3. Correlation_GetMultiplier() looks at a short recent window and
//      counts how many DISTINCT detectors fired inside tight temporal
//      clusters, versus how many were fired by the same single detector
//      repeating itself. A repeat from one detector is still just that
//      detector being sure of itself (already reflected in its own
//      score); several independent detectors agreeing that something
//      happened AT THE SAME MOMENT is new information the current
//      weighted-sum design cannot see at all.
//
// The output is a multiplier (1.0..CORRELATION_MAX_MULTIPLIER) applied to
// the already-computed totalRisk in Timer_Score - it amplifies confirmed
// multi-source evidence, it never invents risk on its own (a multiplier
// on top of a risk of 0 is still 0).

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>

// ------------------------------------------------------------------
// Detector identity - one bit per known detector so a "distinct detector"
// count is a popcount over a bitmask, not a linear scan with string
// comparisons. Add new bits here if a new detector starts reporting.
enum CorrelationDetector
{
    CORR_DET_AIM_SNAP = 0,       // Headshot Snap+Consistency (anticheat_aim.sp)
    CORR_DET_AIM_REPEAT,         // Angle Repeat (anticheat_aim.sp)
    CORR_DET_AIM_CMDSPIKE,       // Cmdnum Spike (anticheat_aim.sp)
    CORR_DET_AIM_AIMLOCK,        // Aimlock (anticheat_aim.sp)
    CORR_DET_AIM_NORECOIL,       // No-Recoil / suppressed vertical punch (anticheat_aim.sp)
    CORR_DET_AIM_HSRATIO,        // Headshot Ratio - near-100% headshots sustained (anticheat_aim.sp)
    CORR_DET_AIM_PSILENT,        // Psilent - 1-tick snap-to-target then snap-back (anticheat_aim.sp)
    CORR_DET_AIM_AUTOSHOOT,      // Autoshoot - shot fired without IN_ATTACK held long enough (anticheat_aim.sp)
    CORR_DET_AIM_FOVLOCK,        // FOV Lock - snap reacts at a fixed entry radius regardless of direction (anticheat_aim.sp)
    CORR_DET_BHOP_RATIO,         // Perfect-jump ratio / streak / honeypot / no-strafe (anticheat_bhop.sp)
    CORR_DET_BHOP2,              // Hyperscroll / hack-composite (anticheat_bhop2.sp)
    CORR_DET_INTEGRITY,          // Fake Angles / Invalid Usercmd (anticheat_integrity.sp)
    CORR_DET_NOLERP,             // NoLerp (anticheat_nolerp.sp)
    CORR_DET_OSAC_BONELOCK,      // BoneLock (anticheat_osac.sp)
    CORR_DET_OSAC_SILENTAIM,     // SilentAim (anticheat_osac.sp)
    CORR_DET_OSAC_TRIGGER,       // TriggerBot (anticheat_osac.sp)
    CORR_DET_OSAC_KILLBURST,     // KillBurst (anticheat_osac.sp)
    CORR_DET_OSAC_SPINBOT,       // SpinBot (anticheat_osac.sp)
    CORR_DET_TARGETACQ,          // Target Acquisition Analysis (anticheat_targetacq.sp)
    CORR_DET_AIMVARIANCE,        // Aim angular-velocity variance profile (anticheat_variance.sp)
    CORR_DET_BHOPVARIANCE,       // Bhop jump-timing variance profile (anticheat_variance.sp)
    CORR_DET_SHOTDECISION,       // Shot Decision Analysis (anticheat_shotdecision.sp)
    CORR_DET_BHOP_TURNRATE,      // Static optimized-angle air-strafe (anticheat_bhop.sp)
    CORR_DET_BHOP_SYNC,          // Strafe-key-to-yaw tick correlation / "BASH" (anticheat_bhop.sp)
    CORR_DET_AIM_NOSPREAD,       // No-Spread - impact ignores the seed-derived weapon spread (anticheat_aim.sp)
    CORR_DET_COUNT               // sentinel - keep last
};

// ------------------------------------------------------------------
// Tuning
#define CORR_HISTORY 32              // recent raw events remembered per player
#define CORR_CLUSTER_WINDOW 1.5      // seconds - events inside this of each other are "the same moment"
#define CORR_LOOKBACK_SECONDS 20.0   // ignore events older than this when computing the multiplier
#define CORR_MAX_MULTIPLIER 1.6      // hard cap - correlation AMPLIFIES existing risk, never explodes it
#define CORR_MIN_DISTINCT_FOR_BONUS 2  // need at least 2 different detectors clustered to earn anything

// ------------------------------------------------------------------
// Per-player raw event ring buffer.
float g_Corr_EventTime[MAXPLAYERS+1][CORR_HISTORY];
int   g_Corr_EventDetector[MAXPLAYERS+1][CORR_HISTORY]; // CorrelationDetector value
int   g_Corr_EventSeverity[MAXPLAYERS+1][CORR_HISTORY]; // 0-100, caller-supplied
int   g_Corr_EventHead[MAXPLAYERS+1];
int   g_Corr_EventCount[MAXPLAYERS+1];

// Human-readable names for logging (index-aligned with CorrelationDetector).
static char g_Corr_DetectorNames[CORR_DET_COUNT][24] = {
    "AimSnap", "AngleRepeat", "CmdnumSpike", "Aimlock", "NoRecoil", "HeadshotRatio", "Psilent", "Autoshoot", "FovLock",
    "BhopRatio", "Bhop2", "Integrity", "NoLerp",
    "BoneLock", "SilentAim", "TriggerBot", "KillBurst", "SpinBot",
    "TargetAcq", "AimVariance", "BhopVariance", "ShotDecision",
    "BhopTurnRate", "BhopSync", "NoSpread"
};

void Correlation_Init(int client)
{
    g_Corr_EventHead[client] = 0;
    g_Corr_EventCount[client] = 0;
}

// ------------------------------------------------------------------
// Detectors call this at the moment they record a raw candidate event -
// the same place they already push into their own ring buffer. `severity`
// is that single event's own strength on a 0-100 scale (callers already
// have a natural notion of this - e.g. how far past a threshold the
// sample was); when a detector has no natural per-event severity, pass 70
// as a reasonable default for "this fired at all".
void Correlation_ReportEvent(int client, CorrelationDetector detector, int severity)
{
    if (client < 1 || client > MaxClients) return;
    if (severity < 0) severity = 0;
    if (severity > 100) severity = 100;

    int idx = g_Corr_EventHead[client];
    g_Corr_EventTime[client][idx] = GetGameTime();
    g_Corr_EventDetector[client][idx] = view_as<int>(detector);
    g_Corr_EventSeverity[client][idx] = severity;
    g_Corr_EventHead[client] = (idx + 1) % CORR_HISTORY;
    if (g_Corr_EventCount[client] < CORR_HISTORY) g_Corr_EventCount[client]++;
}

// ------------------------------------------------------------------
// Internal: walk the recent event list and find the best temporal cluster
// - the window of CORR_CLUSTER_WINDOW seconds containing the most DISTINCT
// detectors. Returns via out-params: distinct detector count in the best
// cluster, and the average severity of the events inside it.
static void Correlation_FindBestCluster(int client, int &outDistinct, float &outAvgSeverity)
{
    outDistinct = 0;
    outAvgSeverity = 0.0;

    int total = g_Corr_EventCount[client];
    if (total == 0) return;

    float now = GetGameTime();

    // Candidate cluster anchors: try centering a window on each recent
    // event's timestamp (cheap - CORR_HISTORY is small, this is O(n^2)
    // worst case over at most 32 events, once per risk evaluation).
    for (int a = 0; a < total; a++)
    {
        float anchorTime = g_Corr_EventTime[client][a];
        if (now - anchorTime > CORR_LOOKBACK_SECONDS) continue;

        bool seenDetector[CORR_DET_COUNT];
        int distinctHere = 0;
        int severitySum = 0;
        int severityCount = 0;

        for (int b = 0; b < total; b++)
        {
            float dt = g_Corr_EventTime[client][b] - anchorTime;
            if (dt < 0.0) dt = -dt;
            if (dt > CORR_CLUSTER_WINDOW) continue;

            int det = g_Corr_EventDetector[client][b];
            if (!seenDetector[det])
            {
                seenDetector[det] = true;
                distinctHere++;
            }
            severitySum += g_Corr_EventSeverity[client][b];
            severityCount++;
        }

        if (distinctHere > outDistinct)
        {
            outDistinct = distinctHere;
            outAvgSeverity = (severityCount > 0) ? (float(severitySum) / float(severityCount)) : 0.0;
        }
    }
}

// ------------------------------------------------------------------
// Public: the multiplier to apply to a player's already-computed
// totalRisk. 1.0 when there's no meaningful cross-detector correlation
// (the normal, honest-player case - this function is cheap and safe to
// call every evaluation). Climbs toward CORR_MAX_MULTIPLIER only when
// multiple INDEPENDENT detectors clustered together in a short window,
// which is evidence a single-detector score can never represent: it is
// specifically the "target enters view -> snap -> perfect acquisition ->
// immediate shot -> clean impact" kind of chain the design calls for,
// generalized to whichever detectors actually fired.
float Correlation_GetMultiplier(int client)
{
    int distinct;
    return Correlation_GetMultiplierEx(client, distinct);
}

// Same as above, but also hands back the distinct-detector count behind
// the multiplier (via `outDistinct`) - the Evidence model (Fase 8) needs
// this raw count to classify EvidenceCount separately from the blended
// multiplier itself.
float Correlation_GetMultiplierEx(int client, int &outDistinct)
{
    float avgSeverity = 0.0;
    Correlation_FindBestCluster(client, outDistinct, avgSeverity);

    if (outDistinct < CORR_MIN_DISTINCT_FOR_BONUS) return 1.0;

    // Scale: 2 distinct detectors clustered => modest bump; every
    // additional distinct detector in the same short window pushes
    // further, weighted by how severe those individual events were (a
    // cluster of borderline events is weaker evidence than a cluster of
    // strongly-severe ones even at the same detector count).
    float severityFactor = avgSeverity / 100.0; // 0..1
    float bonus = float(outDistinct - CORR_MIN_DISTINCT_FOR_BONUS + 1) * 0.15 * (0.5 + 0.5 * severityFactor);

    float mult = 1.0 + bonus;
    if (mult > CORR_MAX_MULTIPLIER) mult = CORR_MAX_MULTIPLIER;
    return mult;
}

// ------------------------------------------------------------------
// Public: human-readable summary of the current best cluster, for
// logging - "3 detectors within 1.5s: AimSnap, TriggerBot, BoneLock".
// Returns false (buffer untouched) when there's nothing worth logging.
bool Correlation_DescribeBestCluster(int client, char[] buffer, int maxlen)
{
    int total = g_Corr_EventCount[client];
    if (total == 0) return false;

    float now = GetGameTime();
    int bestDistinct = 0;
    float bestAnchor = 0.0;

    for (int a = 0; a < total; a++)
    {
        float anchorTime = g_Corr_EventTime[client][a];
        if (now - anchorTime > CORR_LOOKBACK_SECONDS) continue;

        bool seenDetector[CORR_DET_COUNT];
        int distinctHere = 0;
        for (int b = 0; b < total; b++)
        {
            float dt = g_Corr_EventTime[client][b] - anchorTime;
            if (dt < 0.0) dt = -dt;
            if (dt > CORR_CLUSTER_WINDOW) continue;
            int det = g_Corr_EventDetector[client][b];
            if (!seenDetector[det]) { seenDetector[det] = true; distinctHere++; }
        }

        if (distinctHere > bestDistinct)
        {
            bestDistinct = distinctHere;
            bestAnchor = anchorTime;
        }
    }

    if (bestDistinct < CORR_MIN_DISTINCT_FOR_BONUS) return false;

    bool seenDetector[CORR_DET_COUNT];
    char names[256];
    names[0] = '\0';
    bool first = true;
    for (int b = 0; b < total; b++)
    {
        float dt = g_Corr_EventTime[client][b] - bestAnchor;
        if (dt < 0.0) dt = -dt;
        if (dt > CORR_CLUSTER_WINDOW) continue;
        int det = g_Corr_EventDetector[client][b];
        if (seenDetector[det]) continue;
        seenDetector[det] = true;

        if (!first) StrCat(names, sizeof(names), ", ");
        StrCat(names, sizeof(names), g_Corr_DetectorNames[det]);
        first = false;
    }

    FormatEx(buffer, maxlen, "%d detectores en %.1fs: %s", bestDistinct, CORR_CLUSTER_WINDOW, names);
    return true;
}
