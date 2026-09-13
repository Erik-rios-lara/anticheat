// anticheat_tracking.sp - Tracking Kinematics Analysis for L4D2 Anti-Cheat
// (technique adapted from human motor-control research on mouse dynamics
// - "minimum-jerk" trajectory theory and its use in bot-vs-human mouse
// classification, plus FACEIT's public description of judging HOW a
// player aims rather than fixed thresholds)
//
// Every other aim-side module in this project asks "how far off, how
// fast, how often" - none of them ask "what SHAPE does the actual
// tracking path take". Human reaching movements are not random: decades
// of motor-control research show a real arm follows a characteristic
// kinematic signature - it doesn't take the shortest path, it doesn't
// accelerate and decelerate symmetrically, and it doesn't converge onto
// a target in one clean arc. Simple synthetic tracking (a script that
// smoothly steers the crosshair onto a moving target) doesn't reproduce
// that signature even when it's slow, jittered, or humanized in other
// ways, because it isn't derived from the same underlying process.
//
// This tracks a "tracking session" (same session concept as
// anticheat_targetacq.sp, kept independent so this module can be
// disabled/tuned on its own) and reduces the WHOLE trajectory of angular
// error-to-target to three shape metrics once the session closes:
//
//   1. Straightness - direct angular distance vs. total path length
//      travelled getting there. A human's hand wanders and re-corrects;
//      straightness stays well below 1.0. A script's shortest-path
//      tracking pushes it toward 1.0.
//   2. Critical Points - how many times the angular velocity changes
//      sign (peaks/valleys in the error-closing rate) across the
//      session. Real reaches decompose into a primary movement plus
//      1-3 corrective sub-movements (2-4 critical points total); a
//      script that computes one clean convergence produces exactly 1.
//   3. Velocity Asymmetry - real human reaches accelerate FAST at the
//      start and decelerate more gradually into the target (an
//      asymmetric bell-shaped speed curve); many synthetic trackers
//      converge at a more symmetric rate.
//
// Sessions are logged into a rolling per-player history and scored on
// the DISTRIBUTION across many sessions, same reasoning as TargetAcq: an
// expert human is fast, but the shape still varies session to session; a
// script's shape stays consistent across many independent encounters.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

// ------------------------------------------------------------------
#define TRK_ONTARGET_DEG            5.0   // error at/below this counts as "converged"
#define TRK_MIN_INITIAL_DEG        10.0   // must start meaningfully off-target to be worth judging
#define TRK_SESSION_TIMEOUT         2.0   // seconds - give up tracking a session this old
#define TRK_SESSION_MAX_TICKS      128    // safety cap on samples kept per open session
#define TRK_MIN_STEP_DEG            0.15  // per-tick error change below this is noise, not a real step

#define TRK_SESSION_HISTORY 24
#define TRK_MIN_SESSIONS_FOR_SCORE 6
#define TRK_SESSION_EXPIRE_SECONDS 900.0

// Metric 1: Straightness. A session only contributes if it actually
// converged (reached on-target) - an abandoned session's path length
// isn't meaningful.
#define TRK_STRAIGHTNESS_SUSPECT   0.92  // sustained average at/above this is the tell

// Metric 2: Critical Points. A script's clean single-arc convergence
// lands at exactly 1; humans cluster at 2-4 for a real corrective reach.
#define TRK_CRITICALPOINTS_SUSPECT 1     // sessions averaging at/below this count are suspicious

// Metric 3: Velocity Asymmetry, expressed as the fraction of total
// session ticks spent in the (first) acceleration-dominant phase before
// the error-closing rate peaks. A human's peak comes early and the tail
// is long (asymmetric); a symmetric convergence puts the peak near the
// middle.
#define TRK_ASYMMETRY_SUSPECT_LOW  0.42  // peak fraction between these two counts as "too symmetric"
#define TRK_ASYMMETRY_SUSPECT_HIGH 0.58

enum struct TRK_Session
{
    float Straightness;   // -1.0 if not reached (unusable)
    int   CriticalPoints; // -1 if not reached
    float PeakFraction;   // -1.0 if not reached
    bool  Reached;
}

// ------------------------------------------------------------------
// Open-session state per player.
bool  g_TRK_SessionOpen[MAXPLAYERS+1];
int   g_TRK_SessionTarget[MAXPLAYERS+1];
float g_TRK_SessionStartTime[MAXPLAYERS+1];
float g_TRK_SessionInitialErr[MAXPLAYERS+1];
float g_TRK_SessionPrevErr[MAXPLAYERS+1];
float g_TRK_SessionPathLength[MAXPLAYERS+1];   // sum of |error delta| across all ticks (Metric 1 denominator)
int   g_TRK_SessionTicks[MAXPLAYERS+1];
bool  g_TRK_SessionReached[MAXPLAYERS+1];

// Critical-point tracking: sign of the previous tick's error delta, and
// how many times that sign flipped.
int   g_TRK_SessionPrevSign[MAXPLAYERS+1];     // -1 closing, +1 opening, 0 unknown yet
int   g_TRK_SessionSignFlips[MAXPLAYERS+1];

// Peak-rate tracking: which tick index had the single largest per-tick
// error reduction (the "fastest closing" instant), to compute where in
// the session that peak fell.
float g_TRK_SessionBestStep[MAXPLAYERS+1];
int   g_TRK_SessionBestStepTick[MAXPLAYERS+1];

TRK_Session g_TRK_History[MAXPLAYERS+1][TRK_SESSION_HISTORY];
int         g_TRK_HistoryHead[MAXPLAYERS+1];
int         g_TRK_HistoryCount[MAXPLAYERS+1];
float       g_TRK_LastEventTime[MAXPLAYERS+1];

// ------------------------------------------------------------------
void Tracking_Init(int client)
{
    g_TRK_SessionOpen[client] = false;
    g_TRK_HistoryHead[client] = 0;
    g_TRK_HistoryCount[client] = 0;
    g_TRK_LastEventTime[client] = 0.0;
}

static float TRK_FAbs(float v) { return v < 0.0 ? -v : v; }

static float TRK_NormalizeDeg(float d)
{
    if (d > 180.0) return 360.0 - d;
    return d;
}

static float TRK_ErrorToTarget(int client, int target, const float viewAngles[3])
{
    float eye[3];
    GetClientEyePosition(client, eye);
    float body[3];
    GetClientAbsOrigin(target, body);
    body[2] += 32.0;

    float toTarget[3];
    MakeVectorFromPoints(eye, body, toTarget);
    float wanted[3];
    GetVectorAngles(toTarget, wanted);

    float dYaw = TRK_NormalizeDeg(TRK_FAbs(viewAngles[1] - wanted[1]));
    float dPitch = TRK_FAbs(viewAngles[0] - wanted[0]);
    return SquareRoot(dYaw*dYaw + dPitch*dPitch);
}

// ------------------------------------------------------------------
static void TRK_CloseSession(int client)
{
    if (!g_TRK_SessionOpen[client]) return;
    g_TRK_SessionOpen[client] = false;

    TRK_Session sess;
    sess.Reached = g_TRK_SessionReached[client];

    if (sess.Reached && g_TRK_SessionPathLength[client] > 0.0)
    {
        // Metric 1: Straightness.
        float direct = g_TRK_SessionInitialErr[client];
        float pathLen = g_TRK_SessionPathLength[client];
        sess.Straightness = direct / pathLen;
        if (sess.Straightness > 1.0) sess.Straightness = 1.0; // path can't be shorter than direct distance by construction, but guard float error

        // Metric 2: Critical Points. The primary movement itself counts
        // as one "arc"; each sign flip after that is a corrective
        // sub-movement on top of it.
        sess.CriticalPoints = 1 + g_TRK_SessionSignFlips[client];

        // Metric 3: Velocity Asymmetry - where in the session (as a
        // fraction of total ticks) the single fastest error-closing tick
        // landed.
        int ticks = g_TRK_SessionTicks[client];
        sess.PeakFraction = (ticks > 0) ? (float(g_TRK_SessionBestStepTick[client]) / float(ticks)) : 0.5;
    }
    else
    {
        sess.Straightness = -1.0;
        sess.CriticalPoints = -1;
        sess.PeakFraction = -1.0;
    }

    int idx = g_TRK_HistoryHead[client];
    g_TRK_History[client][idx] = sess;
    g_TRK_HistoryHead[client] = (idx + 1) % TRK_SESSION_HISTORY;
    if (g_TRK_HistoryCount[client] < TRK_SESSION_HISTORY) g_TRK_HistoryCount[client]++;
}

// ------------------------------------------------------------------
// Called every tick from OnPlayerRunCmd (tier >= 1 players only, same
// gating as TargetAcq/Variance/AimDrift - shares the per-frame Special
// Infected cache those already pay for).
void Tracking_RecordTick(int client, const float angles[3])
{
    if (g_SpecialCacheCount == 0)
    {
        if (g_TRK_SessionOpen[client]) TRK_CloseSession(client);
        return;
    }

    // Nearest Special Infected right now (same convention as the other
    // target-relative modules - iterate the shared cache).
    float eye[3];
    GetClientEyePosition(client, eye);
    int nearest = -1;
    float nearestDist = 99999999.0;
    for (int c = 0; c < g_SpecialCacheCount; c++)
    {
        int i = g_SpecialCache[c];
        if (!IsClientInGame(i)) continue;
        float pos[3];
        GetClientAbsOrigin(i, pos);
        float dist = GetVectorDistance(eye, pos);
        if (dist < nearestDist) { nearestDist = dist; nearest = i; }
    }

    if (nearest == -1)
    {
        if (g_TRK_SessionOpen[client]) TRK_CloseSession(client);
        return;
    }

    float errDeg = TRK_ErrorToTarget(client, nearest, angles);

    if (!g_TRK_SessionOpen[client])
    {
        // Only worth opening a session if meaningfully off-target - a
        // player already on-target isn't tracking anything.
        if (errDeg < TRK_MIN_INITIAL_DEG) return;

        g_TRK_SessionOpen[client] = true;
        g_TRK_SessionTarget[client] = nearest;
        g_TRK_SessionStartTime[client] = GetGameTime();
        g_TRK_SessionInitialErr[client] = errDeg;
        g_TRK_SessionPrevErr[client] = errDeg;
        g_TRK_SessionPathLength[client] = 0.0;
        g_TRK_SessionTicks[client] = 0;
        g_TRK_SessionReached[client] = false;
        g_TRK_SessionPrevSign[client] = 0;
        g_TRK_SessionSignFlips[client] = 0;
        g_TRK_SessionBestStep[client] = 0.0;
        g_TRK_SessionBestStepTick[client] = 0;
        return;
    }

    // Session already open - is this still the same target?
    if (g_TRK_SessionTarget[client] != nearest)
    {
        TRK_CloseSession(client);
        return;
    }

    // Timeout / sample cap.
    if (GetGameTime() - g_TRK_SessionStartTime[client] > TRK_SESSION_TIMEOUT
        || g_TRK_SessionTicks[client] >= TRK_SESSION_MAX_TICKS)
    {
        TRK_CloseSession(client);
        return;
    }

    float delta = g_TRK_SessionPrevErr[client] - errDeg; // positive = error closing (converging)
    float absDelta = TRK_FAbs(delta);

    if (absDelta >= TRK_MIN_STEP_DEG)
    {
        g_TRK_SessionPathLength[client] += absDelta;
        g_TRK_SessionTicks[client]++;

        int sign = delta > 0.0 ? -1 : 1; // -1 = closing, +1 = opening (matches TA's error-direction convention loosely, sign is internal-only)
        if (g_TRK_SessionPrevSign[client] != 0 && sign != g_TRK_SessionPrevSign[client])
        {
            g_TRK_SessionSignFlips[client]++;
        }
        g_TRK_SessionPrevSign[client] = sign;

        if (delta > g_TRK_SessionBestStep[client])
        {
            g_TRK_SessionBestStep[client] = delta;
            g_TRK_SessionBestStepTick[client] = g_TRK_SessionTicks[client];
        }
    }

    g_TRK_SessionPrevErr[client] = errDeg;

    if (!g_TRK_SessionReached[client] && errDeg <= TRK_ONTARGET_DEG)
    {
        g_TRK_SessionReached[client] = true;
        TRK_CloseSession(client);
    }
}

// ------------------------------------------------------------------
static float TRK_FMin(float a, float b) { return a < b ? a : b; }

int Tracking_GetScore(int client)
{
    int total = g_TRK_HistoryCount[client];
    if (total < TRK_MIN_SESSIONS_FOR_SCORE) return 0;

    float now = GetGameTime();
    int reached = 0;
    float sumStraightness = 0.0;
    float sumCriticalPoints = 0.0;
    float sumPeakFraction = 0.0;

    for (int i = 0; i < total; i++)
    {
        if (!g_TRK_History[client][i].Reached) continue;
        // No per-session timestamp is kept (TargetAcq's pattern uses
        // ClosedAt; this module's history is small and short-lived
        // enough that the ring buffer itself provides the recency
        // bound), so all currently-held sessions are counted.
        reached++;
        sumStraightness += g_TRK_History[client][i].Straightness;
        sumCriticalPoints += float(g_TRK_History[client][i].CriticalPoints);
        sumPeakFraction += g_TRK_History[client][i].PeakFraction;
    }
    if (reached < TRK_MIN_SESSIONS_FOR_SCORE) return 0;

    float avgStraightness = sumStraightness / float(reached);
    float avgCriticalPoints = sumCriticalPoints / float(reached);
    float avgPeakFraction = sumPeakFraction / float(reached);

    float score = 0.0;

    // Metric 1: Straightness.
    if (avgStraightness >= TRK_STRAIGHTNESS_SUSPECT)
    {
        float m1 = TRK_FMin((avgStraightness - TRK_STRAIGHTNESS_SUSPECT) / (1.0 - TRK_STRAIGHTNESS_SUSPECT) * 100.0, 100.0);
        if (m1 > score) score = m1;
    }

    // Metric 2: Critical Points - fewer than a real corrective reach
    // produces, sustained across many independent sessions.
    if (avgCriticalPoints <= float(TRK_CRITICALPOINTS_SUSPECT))
    {
        float m2 = TRK_FMin(85.0 - (avgCriticalPoints - 1.0) * 30.0, 100.0);
        if (m2 < 0.0) m2 = 0.0;
        if (m2 > score) score = m2;
    }

    // Metric 3: Velocity Asymmetry - peak arriving too close to the
    // session's midpoint (too symmetric) rather than early (human).
    if (avgPeakFraction >= TRK_ASYMMETRY_SUSPECT_LOW && avgPeakFraction <= TRK_ASYMMETRY_SUSPECT_HIGH)
    {
        // Distance from the exact midpoint (0.5) determines how deep
        // into the suspect band this sits.
        float distFromMid = TRK_FAbs(avgPeakFraction - 0.5);
        float halfBand = (TRK_ASYMMETRY_SUSPECT_HIGH - TRK_ASYMMETRY_SUSPECT_LOW) / 2.0;
        float m3 = 55.0 + (1.0 - distFromMid / halfBand) * 30.0;
        if (m3 > score) score = m3;
    }

    // Require at least two of the three metrics to agree before trusting
    // a high score from this module alone - each metric on its own has a
    // real (if small) legitimate-population false-positive rate, but
    // seeing two independent shape metrics land in the suspect band at
    // once is a much stronger claim than any one of them individually.
    int metricsSuspect = 0;
    if (avgStraightness >= TRK_STRAIGHTNESS_SUSPECT) metricsSuspect++;
    if (avgCriticalPoints <= float(TRK_CRITICALPOINTS_SUSPECT)) metricsSuspect++;
    if (avgPeakFraction >= TRK_ASYMMETRY_SUSPECT_LOW && avgPeakFraction <= TRK_ASYMMETRY_SUSPECT_HIGH) metricsSuspect++;

    if (metricsSuspect < 2) score *= 0.5; // single-metric agreement: halve the confidence instead of discarding it

    if (score > 100.0) score = 100.0;
    int finalScore = RoundFloat(score);

    if (finalScore >= 55 && now - g_TRK_LastEventTime[client] >= 5.0)
    {
        g_TRK_LastEventTime[client] = now;
        Correlation_ReportEvent(client, CORR_DET_TRACKING, finalScore);
    }

    return finalScore;
}
