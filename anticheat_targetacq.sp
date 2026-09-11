// anticheat_targetacq.sp - Target Acquisition Analysis
//
// Aimlock (in anticheat_aim.sp) looks at a single tick-to-tick transition:
// "did the leftover angle to the nearest target collapse a lot, right
// after a big jump". That catches an isolated hard lock, but it doesn't
// see the SESSION as a whole - how long the whole approach to a target
// took, how smoothly the error shrank across it, or how it compares to
// this same player's other encounters. This module fills that gap: it
// tracks a full "acquisition session" per Special Infected encounter,
// from the moment that target becomes the relevant one to track until the
// player fires at it (or gives up on it), and analyzes the WHOLE
// trajectory rather than one transition.
//
// A session records, every tick while it's open:
//   - the angular error to that specific target at that tick
//   - the timestamp
//
// When a session closes (shot fired, target lost, or timeout), it is
// reduced to a small set of session-level metrics:
//   - AcquisitionTimeMs: from session start to the tick error first
//     dropped under an "on target" threshold (or to the shot, if it fired
//     before that)
//   - InitialErrorDeg: how far off the target was when the session opened
//   - MonotonicRatio: fraction of ticks where the error strictly
//     decreased from the previous tick (vs held steady or increased) -
//     high monotonicity across the ENTIRE approach, not just the final
//     snap, is what a scripted convergence produces; human tracking is
//     naturally noisy tick-to-tick even while trending toward the target
//   - EndedInShot: whether this session ended with a shot at the target
//
// Sessions are cheap to keep (a handful of floats), so ALL of them are
// logged into a per-player rolling history rather than converted straight
// to a score - the scoring function then looks at the DISTRIBUTION across
// many sessions (mean/variance of acquisition time, mean monotonicity),
// which is what lets this distinguish:
//   - an expert / high-sensitivity player: fast acquisition, but time and
//     monotonicity still vary session to session, because a fast human
//     flick still isn't a mathematically smooth function
//   - sustained automation: acquisition time clusters tightly AND
//     monotonicity stays consistently high across many independent
//     encounters, not just one

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

// ------------------------------------------------------------------
#define TA_ONTARGET_DEG        5.0    // error at/below this counts as "acquired"
#define TA_SESSION_MIN_INITIAL_DEG 8.0 // must start meaningfully off-target to count as an acquisition at all
#define TA_SESSION_TIMEOUT      2.0    // seconds - give up tracking a session this old
#define TA_SESSION_MAX_TICKS    128    // hard cap on samples kept per open session (safety, ~2s at 66 tick/s)

#define TA_SESSION_HISTORY 24          // closed sessions remembered per player
#define TA_MIN_SESSIONS_FOR_SCORE 6    // need this many closed, on-target sessions before judging the distribution
#define TA_SESSION_EXPIRE_SECONDS 900.0

// A session only counts toward scoring if it actually reached on-target
// (acquisition happened) - abandoned/lost-target sessions are tracked for
// bookkeeping but excluded from the timing/monotonicity distribution.
enum struct TA_Session
{
    float AcquisitionTimeMs;
    float InitialErrorDeg;
    float MonotonicRatio;
    bool EndedInShot;
    bool Reached;
    float ClosedAt;
    int Target; // client index this session was tracking, for Shot Decision Analysis to match against
}

// ------------------------------------------------------------------
// Open-session state per player (only one tracked target at a time - the
// single nearest relevant Special, matching how Aimlock already scopes
// its own per-tick check).
bool  g_TA_SessionOpen[MAXPLAYERS+1];
int   g_TA_SessionTarget[MAXPLAYERS+1];       // client index of the target this session is about
float g_TA_SessionStartTime[MAXPLAYERS+1];
float g_TA_SessionInitialErr[MAXPLAYERS+1];
float g_TA_SessionPrevErr[MAXPLAYERS+1];
int   g_TA_SessionTicks[MAXPLAYERS+1];
int   g_TA_SessionDecreasingTicks[MAXPLAYERS+1];
bool  g_TA_SessionReachedOnTarget[MAXPLAYERS+1];
float g_TA_SessionReachedAtTime[MAXPLAYERS+1];

// Closed-session ring buffer.
TA_Session g_TA_History[MAXPLAYERS+1][TA_SESSION_HISTORY];
int        g_TA_HistoryHead[MAXPLAYERS+1];
int        g_TA_HistoryCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
void TargetAcq_Init(int client)
{
    g_TA_SessionOpen[client] = false;
    g_TA_HistoryHead[client] = 0;
    g_TA_HistoryCount[client] = 0;
}

static float TA_FAbs(float v) { return v < 0.0 ? -v : v; }
static float TA_FMin(float a, float b) { return a < b ? a : b; }

static bool TA_IsSpecialInfected(int ent)
{
    if (ent < 1 || ent > MaxClients || !IsClientInGame(ent)) return false;
    if (GetClientTeam(ent) != 3) return false;
    int zclass = GetEntProp(ent, Prop_Send, "m_zombieClass");
    return (zclass >= 1 && zclass <= 8);
}

static float TA_NormalizeDeg(float d)
{
    if (d > 180.0) return 360.0 - d;
    return d;
}

// Angular error (deg) from a client's current view to a target's body.
static float TA_ErrorToTarget(int client, int target, const float viewAngles[3])
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

    float dYaw = TA_FAbs(TA_NormalizeDeg(TA_FAbs(viewAngles[1] - wanted[1])));
    float dPitch = TA_FAbs(viewAngles[0] - wanted[0]);
    return SquareRoot(dYaw*dYaw + dPitch*dPitch);
}

// ------------------------------------------------------------------
static void TA_CloseSession(int client, bool endedInShot)
{
    if (!g_TA_SessionOpen[client]) return;
    g_TA_SessionOpen[client] = false;

    // Sessions that never reached on-target (target walked away, player
    // looked elsewhere, timed out short) aren't meaningful acquisitions -
    // don't pollute the distribution with them, but do record enough to
    // know they happened (Reached = false).
    TA_Session sess;
    sess.InitialErrorDeg = g_TA_SessionInitialErr[client];
    sess.EndedInShot = endedInShot;
    sess.ClosedAt = GetGameTime();
    sess.Reached = g_TA_SessionReachedOnTarget[client];
    sess.Target = g_TA_SessionTarget[client];

    if (sess.Reached)
    {
        sess.AcquisitionTimeMs = (g_TA_SessionReachedAtTime[client] - g_TA_SessionStartTime[client]) * 1000.0;
        int ticks = g_TA_SessionTicks[client];
        sess.MonotonicRatio = (ticks > 0) ? (float(g_TA_SessionDecreasingTicks[client]) / float(ticks)) : 0.0;
    }
    else
    {
        sess.AcquisitionTimeMs = -1.0;
        sess.MonotonicRatio = -1.0;
    }

    int idx = g_TA_HistoryHead[client];
    g_TA_History[client][idx] = sess;
    g_TA_HistoryHead[client] = (idx + 1) % TA_SESSION_HISTORY;
    if (g_TA_HistoryCount[client] < TA_SESSION_HISTORY) g_TA_HistoryCount[client]++;
}

// ------------------------------------------------------------------
// Called every tick from OnPlayerRunCmd (survivor only). Uses the shared
// per-frame Special Infected cache (g_SpecialCache) already built by
// anticheat_core.sp for Aimlock/TriggerBot - no extra scan added.
void TargetAcq_RecordTick(int client, const float angles[3], bool firing)
{
    if (g_SpecialCacheCount == 0)
    {
        if (g_TA_SessionOpen[client]) TA_CloseSession(client, false);
        return;
    }

    // Nearest relevant Special (mirrors Aim_GetAngleToNearestTarget's own
    // distance-gated nearest-target search, kept separate here so this
    // module doesn't reach into anticheat_aim.sp's internals).
    float eye[3];
    GetClientEyePosition(client, eye);
    int nearest = -1;
    float nearestDist = 999999.0;
    for (int c = 0; c < g_SpecialCacheCount; c++)
    {
        int i = g_SpecialCache[c];
        if (!IsClientInGame(i) || !TA_IsSpecialInfected(i)) continue;
        float pos[3];
        GetClientAbsOrigin(i, pos);
        float dist = GetVectorDistance(eye, pos);
        if (dist < AIM_MIN_DISTANCE) continue; // same close-quarters exemption as the rest of Aim
        if (dist < nearestDist) { nearestDist = dist; nearest = i; }
    }

    if (nearest == -1)
    {
        if (g_TA_SessionOpen[client]) TA_CloseSession(client, false);
        return;
    }

    float err = TA_ErrorToTarget(client, nearest, angles);

    // Timeout / target changed: close whatever was open and possibly
    // start a fresh session against the (possibly new) nearest target.
    if (g_TA_SessionOpen[client])
    {
        bool targetChanged = (g_TA_SessionTarget[client] != nearest);
        bool timedOut = (GetGameTime() - g_TA_SessionStartTime[client]) > TA_SESSION_TIMEOUT;
        bool tooLong = g_TA_SessionTicks[client] >= TA_SESSION_MAX_TICKS;

        if (targetChanged || timedOut || tooLong)
        {
            TA_CloseSession(client, false);
        }
    }

    if (!g_TA_SessionOpen[client])
    {
        // Only worth opening a session if there's meaningful ground to
        // cover - already being on/near target isn't an "acquisition".
        if (err < TA_SESSION_MIN_INITIAL_DEG) return;

        g_TA_SessionOpen[client] = true;
        g_TA_SessionTarget[client] = nearest;
        g_TA_SessionStartTime[client] = GetGameTime();
        g_TA_SessionInitialErr[client] = err;
        g_TA_SessionPrevErr[client] = err;
        g_TA_SessionTicks[client] = 0;
        g_TA_SessionDecreasingTicks[client] = 0;
        g_TA_SessionReachedOnTarget[client] = false;
        return; // first sample of the session - nothing to compare yet
    }

    // Session already open against `nearest` - accumulate this tick.
    g_TA_SessionTicks[client]++;
    if (err < g_TA_SessionPrevErr[client] - 0.01) // strictly decreasing, with a tiny epsilon for float noise
    {
        g_TA_SessionDecreasingTicks[client]++;
    }
    g_TA_SessionPrevErr[client] = err;

    if (!g_TA_SessionReachedOnTarget[client] && err <= TA_ONTARGET_DEG)
    {
        g_TA_SessionReachedOnTarget[client] = true;
        g_TA_SessionReachedAtTime[client] = GetGameTime();
    }

    // A shot while a session is open and on-target closes it as a
    // successful, "resolved" acquisition - the moment the whole session
    // was building toward.
    if (firing && g_TA_SessionReachedOnTarget[client])
    {
        TA_CloseSession(client, true);

        // Report to the correlation engine only once the module's own
        // distribution-based score is already meaningful (not on every
        // single resolved session - a single fast, smooth acquisition is
        // unremarkable and would just add noise to every good player's
        // correlation buffer). Severity mirrors the module's own score.
        int taScore = TargetAcq_GetScore(client);
        if (taScore > 0)
        {
            Correlation_ReportEvent(client, CORR_DET_TARGETACQ, taScore);
        }
    }
}

// ------------------------------------------------------------------
// Scoring: look at the DISTRIBUTION of closed, on-target sessions rather
// than any single one. Two independent statistical tells:
//
//   1. Acquisition time consistency - real humans (even skilled, even
//      high-sensitivity ones) show real session-to-session variance in
//      how long it takes to land on a target, because reaction + mouse
//      control isn't a fixed-latency function. A script converges in a
//      tight, repeatable time band regardless of target distance/angle.
//
//   2. Sustained high monotonicity - one session with a smooth,
//      monotonic error decrease is unremarkable (a good tracking human
//      does this sometimes). Many independent sessions ALL showing high
//      monotonicity is what a scripted PID-style aim-assist produces and
//      overshoot/correction-driven human tracking essentially never does
//      by chance across a large sample.
//
// Neither metric alone is treated as proof - IMPORTANT per design intent:
// "absence of human error is not proof by itself". Both need to hold
// AND the sample needs to be large enough (TA_MIN_SESSIONS_FOR_SCORE) for
// this to score at all.
int TargetAcq_GetScore(int client)
{
    int total = g_TA_HistoryCount[client];
    if (total < TA_MIN_SESSIONS_FOR_SCORE) return 0;

    float now = GetGameTime();
    float timeSum = 0.0, timeSumSq = 0.0, monoSum = 0.0;
    int n = 0;

    for (int i = 0; i < total; i++)
    {
        if (!g_TA_History[client][i].Reached) continue; // only judge sessions that actually acquired the target
        if (now - g_TA_History[client][i].ClosedAt > TA_SESSION_EXPIRE_SECONDS) continue;

        float acqTime = g_TA_History[client][i].AcquisitionTimeMs;
        timeSum += acqTime;
        timeSumSq += acqTime * acqTime;
        monoSum += g_TA_History[client][i].MonotonicRatio;
        n++;
    }

    if (n < TA_MIN_SESSIONS_FOR_SCORE) return 0;

    float meanTime = timeSum / float(n);
    float varTime = (timeSumSq / float(n)) - (meanTime * meanTime);
    if (varTime < 0.0) varTime = 0.0; // guard float rounding
    float stddevTime = SquareRoot(varTime);
    float meanMono = monoSum / float(n);

    // Coefficient of variation - stddev relative to the mean - is the
    // right measure here rather than raw stddev, because it stays
    // meaningful whether acquisitions average 80ms or 400ms. Humans
    // (including fast ones) typically show CoV well above 0.35 across a
    // real sample of distinct encounters; a fixed-latency or
    // narrow-random-jitter script clusters much tighter.
    float cov = (meanTime > 1.0) ? (stddevTime / meanTime) : 1.0;

    float timingScore = 0.0;
    if (cov < 0.35)
    {
        // Scale 0-100 as cov goes from 0.35 down to 0.05 (near-zero
        // variance = a script hitting the same latency every time).
        timingScore = TA_FMin((0.35 - cov) / 0.30 * 100.0, 100.0);
    }

    float monoScore = 0.0;
    if (meanMono >= 0.70)
    {
        // Humans tracking into a headshot rarely sustain >70% strictly-
        // decreasing ticks averaged across many independent sessions -
        // some overshoot/correction shows up eventually. Scale 70-100%
        // mean monotonicity to 0-100 score.
        monoScore = TA_FMin((meanMono - 0.70) / 0.30 * 100.0, 100.0);
    }

    // Per design intent: neither signal alone is proof. Require BOTH to
    // show something before scoring meaningfully - take the geometric
    // mean so a strong reading on only one axis pulls the score down
    // rather than a simple average letting one axis carry the other.
    if (timingScore <= 0.0 || monoScore <= 0.0) return 0;

    float combined = SquareRoot(timingScore * monoScore);
    return RoundFloat(combined);
}

// ------------------------------------------------------------------
// Public: for Shot Decision Analysis. By the time Hook_TraceAttack fires
// for a shot, OnPlayerRunCmd for that same tick has already run and
// closed the acquisition session (if the shot ended one) into the
// history - so this looks at the MOST RECENTLY CLOSED session against
// `victim`, and only accepts it if it closed within the last 100ms (the
// same tick or the very next one - anything older isn't this shot's
// acquisition). Returns -1.0 if no matching recent session is found.
float TargetAcq_GetRecentDecisionTimeMs(int client, int victim)
{
    int total = g_TA_HistoryCount[client];
    if (total == 0) return -1.0;

    float now = GetGameTime();
    int head = g_TA_HistoryHead[client];

    // Walk backward from the most recently written slot.
    int checks = total < TA_SESSION_HISTORY ? total : TA_SESSION_HISTORY;
    for (int k = 1; k <= checks; k++)
    {
        int idx = (head - k + TA_SESSION_HISTORY) % TA_SESSION_HISTORY;
        if (g_TA_History[client][idx].Target != victim) continue;
        if (!g_TA_History[client][idx].Reached) continue;
        if (now - g_TA_History[client][idx].ClosedAt > 0.1) break; // too old - stop, history is time-ordered

        return g_TA_History[client][idx].AcquisitionTimeMs;
    }

    return -1.0;
}
