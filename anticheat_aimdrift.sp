// anticheat_aimdrift.sp - Aim Drift detector for L4D2 Anti-Cheat
// (technique credited to Pintuzoft/OSAntiCheat's AimDriftDetector, CS2)
//
// Every other aim-side detector in this project judges a player against a
// FIXED threshold or their OWN history. This one is different: it judges
// each player against the REST OF THE LOBBY, live, using a real
// statistical test - a two-proportion z-test, the same kind used to ask
// "is this coin actually fairer than that one" from two samples of flips.
//
// The underlying measurement: while a player's crosshair is "engaged"
// (within MAXENGAGE_DEG of the nearest Special Infected), every tick is
// either a STEP that reduced the remaining angular error (a correction
// that helped) or one that didn't. A human's tracking is noisy - even a
// very good player's corrections overshoot, undershoot, or aim at the
// wrong sub-part of the target some fraction of the time. An aimbot's
// (or aim-assist's) corrections are, on average, MORE likely to reduce
// error than a human's, because they're computed rather than felt - and
// that shows up as a higher "successful step rate" than everyone else in
// the SAME server, SAME map, SAME moment (which cancels out map
// geometry, monster spawn patterns, and connection quality as
// confounders, since the baseline is drawn from the same conditions).
//
// This deliberately does NOT compare against a fixed number - a fixed
// threshold would need separate tuning per map/mode and still not
// account for "this particular horde is just easy to track". Comparing
// against the lobby's own live rate sidesteps all of that.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

// ------------------------------------------------------------------
#define AIMDRIFT_MAX_ENGAGE_DEG   15.0   // nearest target must be within this angle to count as "engaged"
#define AIMDRIFT_MIN_STEP_DEG      0.1   // minimum view movement per tick to register as a real step
#define AIMDRIFT_MIN_DIST_UNITS   64.0   // degenerate-range guard, same convention as the other aim modules
#define AIMDRIFT_EYE_HEIGHT       64.0

// A player needs this many of their OWN engaged steps before their rate
// is judged at all - otherwise a handful of lucky corrections in a short
// encounter would swing the estimate wildly.
#define AIMDRIFT_MIN_PLAYER_STEPS  500

// The lobby-wide baseline (everyone else's pooled steps) needs at least
// this many samples before it's trustworthy enough to test against -
// below this the detector abstains entirely rather than compare against
// a noisy reference.
#define AIMDRIFT_MIN_POP_STEPS    3000

// Z-score threshold to flag at all. The honest-population ceiling
// measured by the reference implementation was 2.79 - 3.0 stays just
// above that, so it flags only distributions the honest corpus never
// actually produced.
#define AIMDRIFT_MIN_Z             3.0

#define AIMDRIFT_EVENT_HISTORY 8

// ------------------------------------------------------------------
// Per-player running tallies for this map/session.
int   g_AD_PlayerSteps[MAXPLAYERS+1];       // N: engaged steps this player has taken
int   g_AD_PlayerReductions[MAXPLAYERS+1];  // B: of those, how many reduced the error

// Per-player previous-tick sample, to measure the step between it and now.
float g_AD_PrevErrDeg[MAXPLAYERS+1];
int   g_AD_PrevTargetId[MAXPLAYERS+1];      // which target the previous sample was engaged with
bool  g_AD_HasPrevSample[MAXPLAYERS+1];

// Map/session-wide pooled totals across ALL players (persists across a
// player disconnecting/reconnecting within the same map, same as the
// reference implementation's map-wide baseline).
int g_AD_TotalSteps;
int g_AD_TotalReductions;

int   g_AD_LastBand[MAXPLAYERS+1];  // floor(z) already emitted, to only report on a new integer band (avoid spam)
float g_AD_EventTime[MAXPLAYERS+1][AIMDRIFT_EVENT_HISTORY];
int   g_AD_EventZBand[MAXPLAYERS+1][AIMDRIFT_EVENT_HISTORY];
int   g_AD_EventHead[MAXPLAYERS+1];
int   g_AD_EventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
void AimDrift_Init(int client)
{
    g_AD_PlayerSteps[client] = 0;
    g_AD_PlayerReductions[client] = 0;
    g_AD_HasPrevSample[client] = false;
    g_AD_LastBand[client] = 0;
    g_AD_EventHead[client] = 0;
    g_AD_EventCount[client] = 0;
}

// Called once per map start (see anticheat_core.sp) - the pooled baseline
// is intentionally map-scoped, same as the reference implementation:
// mixing samples across maps with different sightlines/geometry would
// itself skew the "honest" rate.
void AimDrift_OnMapStart()
{
    g_AD_TotalSteps = 0;
    g_AD_TotalReductions = 0;
}

// ------------------------------------------------------------------
static float AimDrift_FAbs(float v) { return v < 0.0 ? -v : v; }

// Angle (deg) from this client's view to a target's eye position, and
// the target's client index - mirrors Aim_GetAngleToNearestTarget's
// convention but also returns WHICH target, since a step is only
// meaningful if it's progress against the SAME target as last tick (a
// target switch resets what "closer" even means).
static float AimDrift_NearestEngaged(int client, const float viewAngles[3], int &outTargetId)
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
        if (dist < AIMDRIFT_MIN_DIST_UNITS) continue;

        float toTarget[3];
        MakeVectorFromPoints(eyePos, targetPos, toTarget);
        float wanted[3];
        GetVectorAngles(toTarget, wanted);

        float dYaw = AimDrift_FAbs(viewAngles[1] - wanted[1]);
        if (dYaw > 180.0) dYaw = 360.0 - dYaw;
        float dPitch = AimDrift_FAbs(viewAngles[0] - wanted[0]);
        float deg = SquareRoot(dYaw*dYaw + dPitch*dPitch);

        if (dist < bestDist) { bestDist = dist; bestDeg = deg; bestId = i; }
    }

    outTargetId = bestId;
    if (bestDeg > AIMDRIFT_MAX_ENGAGE_DEG) return -1.0; // nearest target exists but isn't "engaged" (too far off)
    return bestDeg;
}

// ------------------------------------------------------------------
// Called every tick from OnPlayerRunCmd for players the cheap checks
// already flagged (tier >= 1) - same gating as Aimlock/TriggerBot/
// TargetAcq, since this needs the same per-frame Special Infected scan
// those already pay for.
void AimDrift_RecordTick(int client, const float angles[3])
{
    int targetId;
    float errDeg = AimDrift_NearestEngaged(client, angles, targetId);

    if (errDeg < 0.0)
    {
        g_AD_HasPrevSample[client] = false; // not engaged this tick - no step to measure
        return;
    }

    if (!g_AD_HasPrevSample[client] || g_AD_PrevTargetId[client] != targetId)
    {
        // First sample of a new engagement (or the target switched) -
        // nothing to compare against yet, just seed it.
        g_AD_PrevErrDeg[client] = errDeg;
        g_AD_PrevTargetId[client] = targetId;
        g_AD_HasPrevSample[client] = true;
        return;
    }

    float step = AimDrift_FAbs(g_AD_PrevErrDeg[client] - errDeg);
    bool reduced = errDeg < g_AD_PrevErrDeg[client];
    g_AD_PrevErrDeg[client] = errDeg;

    if (step < AIMDRIFT_MIN_STEP_DEG) return; // view barely moved - not a real step either way

    g_AD_PlayerSteps[client]++;
    g_AD_TotalSteps++;
    if (reduced)
    {
        g_AD_PlayerReductions[client]++;
        g_AD_TotalReductions++;
    }

    AimDrift_JudgePlayer(client);
}

// ------------------------------------------------------------------
// Two-proportion z-test: is this player's own error-reduction rate
// significantly higher than the pooled rate of everyone else currently
// contributing to the baseline?
static void AimDrift_JudgePlayer(int client)
{
    int stN = g_AD_PlayerSteps[client];
    if (stN < AIMDRIFT_MIN_PLAYER_STEPS) return;

    int stB = g_AD_PlayerReductions[client];
    int restN = g_AD_TotalSteps - stN;
    int restB = g_AD_TotalReductions - stB;
    if (restN < AIMDRIFT_MIN_POP_STEPS) return; // baseline not trustworthy yet - abstain

    float p1 = float(stB) / float(stN);
    float p0 = float(restB) / float(restN);
    float pooled = float(stB + restB) / float(stN + restN);
    float se = SquareRoot(pooled * (1.0 - pooled) * (1.0 / float(stN) + 1.0 / float(restN)));
    if (se <= 0.0) return;

    float z = (p1 - p0) / se;
    if (z < AIMDRIFT_MIN_Z) return;

    // Escalation bands: only report when z crosses into a NEW integer
    // band, so a player sitting at z=3.1 doesn't re-fire every tick.
    int band = RoundToFloor(z);
    if (band <= g_AD_LastBand[client]) return;
    g_AD_LastBand[client] = band;

    int idx = g_AD_EventHead[client];
    g_AD_EventTime[client][idx] = GetGameTime();
    g_AD_EventZBand[client][idx] = band;
    g_AD_EventHead[client] = (idx + 1) % AIMDRIFT_EVENT_HISTORY;
    if (g_AD_EventCount[client] < AIMDRIFT_EVENT_HISTORY) g_AD_EventCount[client]++;

    // Severity scales with how far past the flag threshold the z-score
    // climbed - a higher z is a statistically stronger deviation from
    // the rest of this exact lobby, not a bigger raw count.
    float severityF = 55.0 + (z - AIMDRIFT_MIN_Z) * 10.0;
    if (severityF > 100.0) severityF = 100.0;
    Correlation_ReportEvent(client, CORR_DET_AIMDRIFT, RoundFloat(severityF));
}

// ------------------------------------------------------------------
#define AIMDRIFT_MIN_EVENTS 1
int AimDrift_GetScore(int client)
{
    int total = g_AD_EventCount[client];
    if (total < AIMDRIFT_MIN_EVENTS) return 0;

    float now = GetGameTime();
    int bestBand = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_AD_EventTime[client][i] > 900.0) continue; // same expiry convention as the other aim modules
        if (g_AD_EventZBand[client][i] > bestBand) bestBand = g_AD_EventZBand[client][i];
    }
    if (bestBand < RoundToFloor(AIMDRIFT_MIN_Z)) return 0;

    float score = 55.0 + float(bestBand - RoundToFloor(AIMDRIFT_MIN_Z)) * 10.0;
    if (score > 100.0) score = 100.0;
    return RoundFloat(score);
}
