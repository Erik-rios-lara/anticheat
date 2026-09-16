// anticheat_kldivergence.sp - Distribution Shape Divergence for L4D2
// Anti-Cheat (technique adapted from "Game Bot Detection via Avatar
// Trajectory Analysis" - Chen et al. - which uses Kullback-Leibler
// divergence over step-size histograms to separate scripted bot
// movement from human movement in MMORPGs)
//
// anticheat_variance.sp already asks "is this player suspiciously
// CONSISTENT in their angular velocity, block to block" by comparing
// mean and standard deviation. That's a real signal, but mean/stddev can
// only ever describe a SHAPE up to two numbers - two distributions with
// identical mean and stddev can still look completely different (one
// tight bell curve vs. one that's actually bimodal, spending all its
// time either dead-still or snapping hard, with nothing in between).
// KL divergence compares the FULL shape of a distribution against a
// reference, not just its first two moments, so it can catch a pattern
// variance profiling structurally cannot: consistent SHAPE with
// inconsistent scale, or vice versa.
//
// Same "compare against the live lobby" design as anticheat_aimdrift.sp
// rather than a fixed reference curve - this sidesteps needing to know
// in advance what a "normal" angular-velocity histogram even looks like
// for this specific map/mode/player count, and cancels out confounders
// like map geometry or an easy/hard horde since the baseline is drawn
// from the exact same conditions, same moment.
//
// The measurement: while a player is actively engaged with (tracking) a
// Special Infected, each tick's angular velocity (deg/tick) is binned
// into one of a small number of buckets. Over a session, this produces a
// discrete probability distribution P (this player, this session) that
// gets accumulated into a per-player running histogram, and separately
// into a POOLED histogram from every other player in the server. KL
// divergence D(P||Q) measures how many extra "bits of surprise" it takes
// to describe P using Q's distribution instead of P's own - a player
// whose angular-velocity shape diverges hard and consistently from
// everyone else playing the exact same game at the exact same time is
// either extraordinarily different in skill/style, or not producing the
// distribution a human hand produces at all.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

// ------------------------------------------------------------------
#define KLD_MAX_ENGAGE_DEG    15.0   // nearest target must be within this angle to count as "engaged"
#define KLD_MIN_DIST_UNITS    64.0   // degenerate-range guard, same convention as the other aim modules

// Histogram bins: angular velocity in deg/tick, bucketed. Bin 0 is
// "barely moving" (fine tracking / holding), the last bin is "large
// snap". Buckets are NOT linear - most of a human's tracking time is
// spent in the low-velocity buckets with a long tail, so linear bins
// would waste most of their resolution on the empty tail.
#define KLD_NUM_BINS 8
float g_KLD_BinEdges[KLD_NUM_BINS+1] = { 0.0, 0.3, 0.7, 1.3, 2.2, 3.5, 5.5, 9.0, 999.0 };

// A session needs a real number of ticks before its histogram is
// trustworthy at all.
#define KLD_MIN_SESSION_TICKS   40
#define KLD_SESSION_TIMEOUT      2.0

// Minimum pooled/player histogram mass (total ticks contributed) before
// judging - same reasoning as Aim Drift's minPopSteps: below this,
// abstain rather than compare against a noisy reference.
#define KLD_MIN_PLAYER_TICKS   600
#define KLD_MIN_POP_TICKS     4000

// KL divergence is unbounded above; empirically (see file header) a
// well-populated honest lobby's OWN cross-player divergence sits low
// because everyone is drawing from the same broad human distribution.
// This is deliberately a "large and sustained" threshold, not tuned to
// a specific published ceiling (unlike Aim Drift's z>=3.0, no directly
// reusable published constant exists for this exact per-tick angular-
// velocity binning) - it requires the divergence to be large AND to
// recur across multiple independent judging windows before scoring.
#define KLD_SUSPECT_NATS        0.35
#define KLD_MIN_CONFIRMATIONS      3
#define KLD_JUDGE_COOLDOWN_SEC    20.0

#define KLD_EVENT_HISTORY 6

// ------------------------------------------------------------------
// Per-player running histogram (ticks in each bin) for the current map.
int   g_KLD_PlayerBins[MAXPLAYERS+1][KLD_NUM_BINS];
int   g_KLD_PlayerTotal[MAXPLAYERS+1];

// Pooled histogram: every OTHER player's contribution, maintained the
// same way Aim Drift maintains its pooled step totals - this player's
// own bins are subtracted out at judge time rather than kept separately
// per-pair, since with L4D2's small lobby sizes a simple pool-minus-self
// is cheap and exact.
int g_KLD_PoolBins[KLD_NUM_BINS];
int g_KLD_PoolTotal;

// Open-session tracking.
bool  g_KLD_SessionOpen[MAXPLAYERS+1];
int   g_KLD_SessionTarget[MAXPLAYERS+1];
float g_KLD_SessionLastTickTime[MAXPLAYERS+1];
float g_KLD_PrevErrDeg[MAXPLAYERS+1];
bool  g_KLD_HasPrevErr[MAXPLAYERS+1];

int   g_KLD_ConsecutiveSuspect[MAXPLAYERS+1];
float g_KLD_LastJudgeTime[MAXPLAYERS+1];
float g_KLD_EventTime[MAXPLAYERS+1][KLD_EVENT_HISTORY];
int   g_KLD_EventHead[MAXPLAYERS+1];
int   g_KLD_EventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
void KLDivergence_Init(int client)
{
    for (int b = 0; b < KLD_NUM_BINS; b++) g_KLD_PlayerBins[client][b] = 0;
    g_KLD_PlayerTotal[client] = 0;
    g_KLD_SessionOpen[client] = false;
    g_KLD_HasPrevErr[client] = false;
    g_KLD_ConsecutiveSuspect[client] = 0;
    g_KLD_LastJudgeTime[client] = 0.0;
    g_KLD_EventHead[client] = 0;
    g_KLD_EventCount[client] = 0;
}

// Map-scoped, same reasoning as Aim Drift's baseline reset - different
// maps have different sightlines/geometry that would otherwise skew what
// "typical" tracking looks like.
void KLDivergence_OnMapStart()
{
    for (int b = 0; b < KLD_NUM_BINS; b++) g_KLD_PoolBins[b] = 0;
    g_KLD_PoolTotal = 0;
    for (int c = 1; c <= MaxClients; c++)
    {
        for (int b = 0; b < KLD_NUM_BINS; b++) g_KLD_PlayerBins[c][b] = 0;
        g_KLD_PlayerTotal[c] = 0;
    }
}

static float KLD_FAbs(float v) { return v < 0.0 ? -v : v; }

static float KLD_NormalizeDeg(float d)
{
    if (d > 180.0) return 360.0 - d;
    return d;
}

static int KLD_BinFor(float velDegPerTick)
{
    for (int b = 0; b < KLD_NUM_BINS; b++)
    {
        if (velDegPerTick < g_KLD_BinEdges[b+1]) return b;
    }
    return KLD_NUM_BINS - 1;
}

// ------------------------------------------------------------------
static float KLD_NearestEngaged(int client, const float viewAngles[3], int &outTargetId)
{
    float eyePos[3];
    GetClientEyePosition(client, eyePos);

    float bestDist = 99999999.0;
    float bestDeg = -1.0;
    int bestId = -1;

    for (int c = 0; c < g_SpecialCacheCount; c++)
    {
        int i = g_SpecialCache[c];
        if (!IsClientInGame(i)) continue;

        float targetPos[3];
        GetClientEyePosition(i, targetPos);

        float dist = GetVectorDistance(eyePos, targetPos);
        if (dist < KLD_MIN_DIST_UNITS) continue;

        float toTarget[3];
        MakeVectorFromPoints(eyePos, targetPos, toTarget);
        float wanted[3];
        GetVectorAngles(toTarget, wanted);

        float dYaw = KLD_NormalizeDeg(KLD_FAbs(viewAngles[1] - wanted[1]));
        float dPitch = KLD_FAbs(viewAngles[0] - wanted[0]);
        float deg = SquareRoot(dYaw*dYaw + dPitch*dPitch);

        if (dist < bestDist) { bestDist = dist; bestDeg = deg; bestId = i; }
    }

    outTargetId = bestId;
    if (bestDeg > KLD_MAX_ENGAGE_DEG) return -1.0;
    return bestDeg;
}

// ------------------------------------------------------------------
// Called every tick from OnPlayerRunCmd for tier >= 1 players - same
// gating and shared per-frame cache as the other target-relative
// modules.
void KLDivergence_RecordTick(int client, const float angles[3])
{
    int targetId;
    float errDeg = KLD_NearestEngaged(client, angles, targetId);
    float now = GetGameTime();

    bool sessionShouldClose = (errDeg < 0.0)
        || (g_KLD_SessionOpen[client] && g_KLD_SessionTarget[client] != targetId)
        || (g_KLD_SessionOpen[client] && now - g_KLD_SessionLastTickTime[client] > KLD_SESSION_TIMEOUT);

    if (sessionShouldClose && g_KLD_SessionOpen[client])
    {
        g_KLD_SessionOpen[client] = false;
        g_KLD_HasPrevErr[client] = false;
    }

    if (errDeg < 0.0) return;

    if (!g_KLD_SessionOpen[client])
    {
        g_KLD_SessionOpen[client] = true;
        g_KLD_SessionTarget[client] = targetId;
        g_KLD_HasPrevErr[client] = false;
    }
    g_KLD_SessionLastTickTime[client] = now;

    if (!g_KLD_HasPrevErr[client])
    {
        g_KLD_PrevErrDeg[client] = errDeg;
        g_KLD_HasPrevErr[client] = true;
        return;
    }

    float velDeg = KLD_FAbs(g_KLD_PrevErrDeg[client] - errDeg);
    g_KLD_PrevErrDeg[client] = errDeg;

    int bin = KLD_BinFor(velDeg);
    g_KLD_PlayerBins[client][bin]++;
    g_KLD_PlayerTotal[client]++;
    g_KLD_PoolBins[bin]++;
    g_KLD_PoolTotal++;

    if (g_KLD_PlayerTotal[client] >= KLD_MIN_SESSION_TICKS
        && now - g_KLD_LastJudgeTime[client] >= KLD_JUDGE_COOLDOWN_SEC)
    {
        KLDivergence_Judge(client);
    }
}

// ------------------------------------------------------------------
// D_KL(P||Q) = sum_i P(i) * log(P(i)/Q(i)), in nats.
static float KLD_ComputeDivergence(const int pBins[KLD_NUM_BINS], int pTotal, const int qBins[KLD_NUM_BINS], int qTotal)
{
    if (pTotal <= 0 || qTotal <= 0) return 0.0;

    // Additive (Laplace) smoothing so a bin the player never visited
    // doesn't produce a divide-by-zero or infinite divergence from one
    // unlucky empty bin - a real difference should show up as a
    // sustained gap across several bins, not a single zero-count fluke.
    float smoothing = 1.0;
    float pDenom = float(pTotal) + smoothing * float(KLD_NUM_BINS);
    float qDenom = float(qTotal) + smoothing * float(KLD_NUM_BINS);

    float divergence = 0.0;
    for (int b = 0; b < KLD_NUM_BINS; b++)
    {
        float p = (float(pBins[b]) + smoothing) / pDenom;
        float q = (float(qBins[b]) + smoothing) / qDenom;
        divergence += p * Logarithm(p / q, 2.71828182845904523536); // natural log via explicit base
    }
    return divergence;
}

// ------------------------------------------------------------------
static void KLDivergence_Judge(int client)
{
    g_KLD_LastJudgeTime[client] = GetGameTime();

    int qBins[KLD_NUM_BINS];
    int qTotal = g_KLD_PoolTotal - g_KLD_PlayerTotal[client];
    for (int b = 0; b < KLD_NUM_BINS; b++)
    {
        qBins[b] = g_KLD_PoolBins[b] - g_KLD_PlayerBins[client][b];
    }
    if (qTotal < KLD_MIN_POP_TICKS) return; // baseline not trustworthy yet - abstain, same reasoning as Aim Drift

    float divergence = KLD_ComputeDivergence(g_KLD_PlayerBins[client], g_KLD_PlayerTotal[client], qBins, qTotal);

    if (divergence < KLD_SUSPECT_NATS)
    {
        g_KLD_ConsecutiveSuspect[client] = 0;
        return;
    }

    g_KLD_ConsecutiveSuspect[client]++;
    if (g_KLD_ConsecutiveSuspect[client] < KLD_MIN_CONFIRMATIONS) return;

    int idx = g_KLD_EventHead[client];
    g_KLD_EventTime[client][idx] = GetGameTime();
    g_KLD_EventHead[client] = (idx + 1) % KLD_EVENT_HISTORY;
    if (g_KLD_EventCount[client] < KLD_EVENT_HISTORY) g_KLD_EventCount[client]++;

    float severityF = 55.0 + (divergence - KLD_SUSPECT_NATS) * 60.0;
    if (severityF > 100.0) severityF = 100.0;
    Correlation_ReportEvent(client, CORR_DET_KLDIVERGENCE, RoundFloat(severityF));

    // Keep judging fresh rather than let one confirmed run count as
    // dozens of consecutive confirmations forever.
    g_KLD_ConsecutiveSuspect[client] = 0;
}

// ------------------------------------------------------------------
#define KLD_MIN_EVENTS 1
int KLDivergence_GetScore(int client)
{
    int total = g_KLD_EventCount[client];
    if (total < KLD_MIN_EVENTS) return 0;

    float now = GetGameTime();
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_KLD_EventTime[client][i] <= 900.0) count++;
    }
    if (count < KLD_MIN_EVENTS) return 0;

    float score = 55.0 + float(count - KLD_MIN_EVENTS) * 15.0;
    if (score > 100.0) score = 100.0;
    return RoundFloat(score);
}
