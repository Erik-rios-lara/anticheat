// anticheat_variance.sp - Statistical Consistency / Variance Profiling
//
// Every other detector in this project compares a player's behavior
// against a FIXED global threshold (e.g. "snap >= 2.0 deg", "jump ratio
// >= 85%"). This module does something different: it builds a per-PLAYER
// profile across multiple independent encounters and asks whether that
// player's own variance collapses in a way no single encounter could
// reveal - the goal is explicitly NOT "detect a good player" but "detect
// artificially repetitive behavior across enough samples that natural
// human variability could not produce it by chance".
//
// AIM: tracks angular velocity during sustained tracking (not just the
// snap-at-shot moment other Aim sub-detectors look at) in per-ENCOUNTER
// blocks - one block per continuous stretch of tracking the same nearest
// Special Infected. Each closed block reduces to its own mean angular
// velocity and internal variance. The score looks at variance BETWEEN
// blocks: different encounters (different target distance, different
// relative movement, different weapon) naturally produce different
// tracking dynamics for a human. A script's control loop tends to
// produce near-identical dynamics across encounters that have nothing
// else in common.
//
// BHOP: tracks the exact TIMING (not just perfect/imperfect) of the
// landing-to-jump-input gap, in milliseconds, across long jump
// sequences. Groups them into sequences (like the existing Bhop module's
// streak concept) and compares timing variance ACROSS sequences rather
// than within one - a human's reaction timing drifts with fatigue,
// distraction, and how each specific jump felt; a script's timing
// distribution stays put across an entire play session regardless of
// context.
//
// Neither profile duplicates existing detectors' math - anticheat_aim.sp
// only looks at the single tick immediately before/at a shot, and
// anticheat_bhop.sp only classifies each jump as perfect/not. This module
// is the only one that measures continuous angular velocity through a
// full tracking encounter, and the only one that measures actual
// landing-to-jump millisecond timing rather than a binary outcome.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

// ==================================================================
// AIM VARIANCE PROFILE
// ==================================================================

#define AVAR_MIN_BLOCK_TICKS     8     // an encounter block must last at least this many ticks to count
#define AVAR_BLOCK_TIMEOUT       1.5   // seconds - target lost/changed for this long closes the block
#define AVAR_BLOCK_HISTORY       20    // encounter blocks remembered per player
#define AVAR_MIN_BLOCKS_FOR_SCORE 6    // need this many closed blocks before judging between-block variance
#define AVAR_BLOCK_EXPIRE_SECONDS 900.0

// Per-block accumulation (Welford's online algorithm for mean/variance -
// avoids storing every raw sample, just 3 running numbers per block).
bool  g_AVar_BlockOpen[MAXPLAYERS+1];
int   g_AVar_BlockTarget[MAXPLAYERS+1];
float g_AVar_BlockLastSeenTime[MAXPLAYERS+1];
int   g_AVar_BlockTicks[MAXPLAYERS+1];
float g_AVar_BlockMean[MAXPLAYERS+1];      // running mean angular velocity (deg/tick) this block
float g_AVar_BlockM2[MAXPLAYERS+1];        // running sum of squared deviations (Welford)
float g_AVar_PrevYaw[MAXPLAYERS+1];
float g_AVar_PrevPitch[MAXPLAYERS+1];
bool  g_AVar_HasPrevAngle[MAXPLAYERS+1];

// Closed-block history: each block's own internal mean and stddev.
float g_AVar_History_Mean[MAXPLAYERS+1][AVAR_BLOCK_HISTORY];
float g_AVar_History_Stddev[MAXPLAYERS+1][AVAR_BLOCK_HISTORY];
float g_AVar_History_ClosedAt[MAXPLAYERS+1][AVAR_BLOCK_HISTORY];
int   g_AVar_HistoryHead[MAXPLAYERS+1];
int   g_AVar_HistoryCount[MAXPLAYERS+1];

// ==================================================================
// BHOP TIMING VARIANCE PROFILE
// ==================================================================

#define BVAR_SEQUENCE_MAX_GAP_TICKS 5     // gap above this breaks a jump sequence (mirrors anticheat_bhop.sp's own gap rule)
#define BVAR_SEQUENCE_MIN_JUMPS     5      // a sequence must have at least this many jumps to be judged
#define BVAR_SEQUENCE_HISTORY       16     // closed sequences remembered per player
#define BVAR_MIN_SEQUENCES_FOR_SCORE 5
#define BVAR_SEQUENCE_EXPIRE_SECONDS 900.0

bool  g_BVar_WasOnGround[MAXPLAYERS+1];
bool  g_BVar_JumpedLastTick[MAXPLAYERS+1];
int   g_BVar_TicksSinceLand[MAXPLAYERS+1];
bool  g_BVar_AwaitingJump[MAXPLAYERS+1];   // landed, haven't seen the jump input for THIS landing yet
int   g_BVar_TicksSinceThisLanding[MAXPLAYERS+1]; // for timing the pending jump input, once it arrives
int   g_BVar_SeqJumpCount[MAXPLAYERS+1];
float g_BVar_SeqMean[MAXPLAYERS+1];    // running mean landing-to-jump gap (ms) this sequence (Welford)
float g_BVar_SeqM2[MAXPLAYERS+1];

float g_BVar_History_Mean[MAXPLAYERS+1][BVAR_SEQUENCE_HISTORY];
float g_BVar_History_Stddev[MAXPLAYERS+1][BVAR_SEQUENCE_HISTORY];
float g_BVar_History_ClosedAt[MAXPLAYERS+1][BVAR_SEQUENCE_HISTORY];
int   g_BVar_HistoryHead[MAXPLAYERS+1];
int   g_BVar_HistoryCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
void Variance_Init(int client)
{
    g_AVar_BlockOpen[client] = false;
    g_AVar_HasPrevAngle[client] = false;
    g_AVar_HistoryHead[client] = 0;
    g_AVar_HistoryCount[client] = 0;

    g_BVar_WasOnGround[client] = false;
    g_BVar_JumpedLastTick[client] = false;
    g_BVar_TicksSinceLand[client] = 0;
    g_BVar_AwaitingJump[client] = false;
    g_BVar_TicksSinceThisLanding[client] = 0;
    g_BVar_SeqJumpCount[client] = 0;
    g_BVar_HistoryHead[client] = 0;
    g_BVar_HistoryCount[client] = 0;
}

static float VAR_FMin(float a, float b) { return a < b ? a : b; }

static bool VAR_IsSpecialInfected(int ent)
{
    if (ent < 1 || ent > MaxClients || !IsClientInGame(ent)) return false;
    if (GetClientTeam(ent) != 3) return false;
    int zclass = GetEntProp(ent, Prop_Send, "m_zombieClass");
    return (zclass >= 1 && zclass <= 8);
}

// ------------------------------------------------------------------
// Welford's online algorithm: feed one sample at a time, get running
// mean/variance without storing the raw sample list.
static void VAR_WelfordAdd(float &mean, float &m2, int n, float sample)
{
    float delta = sample - mean;
    mean += delta / float(n);
    float delta2 = sample - mean;
    m2 += delta * delta2;
}

// ------------------------------------------------------------------
// AIM VARIANCE - called every tick from OnPlayerRunCmd while the player
// is in tier >= 1 (same gating as Aimlock/TriggerBot/TargetAcq - this
// needs the same per-frame Special Infected cache and is not meaningful
// to run for a clean player).
void Variance_RecordAimTick(int client, const float angles[3])
{
    if (g_SpecialCacheCount == 0)
    {
        if (g_AVar_BlockOpen[client]) Variance_CloseAimBlock(client);
        g_AVar_HasPrevAngle[client] = false;
        return;
    }

    // Nearest relevant Special (same distance-gated search pattern used
    // by TargetAcq and Aimlock - kept local so this module doesn't reach
    // into their internals).
    float eye[3];
    GetClientEyePosition(client, eye);
    int nearest = -1;
    float nearestDist = 999999.0;
    for (int c = 0; c < g_SpecialCacheCount; c++)
    {
        int i = g_SpecialCache[c];
        if (!IsClientInGame(i) || !VAR_IsSpecialInfected(i)) continue;
        float pos[3];
        GetClientAbsOrigin(i, pos);
        float dist = GetVectorDistance(eye, pos);
        if (dist < AIM_MIN_DISTANCE) continue;
        if (dist < nearestDist) { nearestDist = dist; nearest = i; }
    }

    if (nearest == -1)
    {
        if (g_AVar_BlockOpen[client]) Variance_CloseAimBlock(client);
        g_AVar_HasPrevAngle[client] = false;
        return;
    }

    float now = GetGameTime();

    if (g_AVar_BlockOpen[client] && g_AVar_BlockTarget[client] != nearest)
    {
        Variance_CloseAimBlock(client);
    }
    else if (g_AVar_BlockOpen[client] && (now - g_AVar_BlockLastSeenTime[client]) > AVAR_BLOCK_TIMEOUT)
    {
        Variance_CloseAimBlock(client);
    }

    if (!g_AVar_BlockOpen[client])
    {
        g_AVar_BlockOpen[client] = true;
        g_AVar_BlockTarget[client] = nearest;
        g_AVar_BlockTicks[client] = 0;
        g_AVar_BlockMean[client] = 0.0;
        g_AVar_BlockM2[client] = 0.0;
        g_AVar_HasPrevAngle[client] = false; // don't carry a velocity sample across a block boundary
    }
    g_AVar_BlockLastSeenTime[client] = now;

    if (g_AVar_HasPrevAngle[client])
    {
        float dYaw = angles[1] - g_AVar_PrevYaw[client];
        while (dYaw > 180.0) dYaw -= 360.0;
        while (dYaw <= -180.0) dYaw += 360.0;
        float dPitch = angles[0] - g_AVar_PrevPitch[client];

        float angularSpeed = SquareRoot(dYaw*dYaw + dPitch*dPitch); // deg/tick

        g_AVar_BlockTicks[client]++;
        VAR_WelfordAdd(g_AVar_BlockMean[client], g_AVar_BlockM2[client], g_AVar_BlockTicks[client], angularSpeed);
    }

    g_AVar_PrevYaw[client] = angles[1];
    g_AVar_PrevPitch[client] = angles[0];
    g_AVar_HasPrevAngle[client] = true;
}

static void Variance_CloseAimBlock(int client)
{
    g_AVar_BlockOpen[client] = false;
    int ticks = g_AVar_BlockTicks[client];
    if (ticks < AVAR_MIN_BLOCK_TICKS) return; // too short to characterize, discard

    float variance = g_AVar_BlockM2[client] / float(ticks);
    if (variance < 0.0) variance = 0.0;
    float stddev = SquareRoot(variance);

    int idx = g_AVar_HistoryHead[client];
    g_AVar_History_Mean[client][idx] = g_AVar_BlockMean[client];
    g_AVar_History_Stddev[client][idx] = stddev;
    g_AVar_History_ClosedAt[client][idx] = GetGameTime();
    g_AVar_HistoryHead[client] = (idx + 1) % AVAR_BLOCK_HISTORY;
    if (g_AVar_HistoryCount[client] < AVAR_BLOCK_HISTORY) g_AVar_HistoryCount[client]++;

    // Only report once the module's own distribution-based score is
    // already nonzero - a single closed block is unremarkable on its
    // own, only a demonstrated pattern across the profile is evidence.
    int score = Variance_GetAimScore(client);
    if (score > 0) Correlation_ReportEvent(client, CORR_DET_AIMVARIANCE, score);
}

// ------------------------------------------------------------------
// Score: look at the variance of the internal stddevs ACROSS blocks, and
// separately the variance of the mean angular speeds across blocks. Real
// human tracking dynamics differ meaningfully between encounters
// (different target, different range, different relative motion); a
// script's control loop tends to reproduce near-identical dynamics
// regardless of what's actually happening in each encounter.
int Variance_GetAimScore(int client)
{
    int total = g_AVar_HistoryCount[client];
    if (total < AVAR_MIN_BLOCKS_FOR_SCORE) return 0;

    float now = GetGameTime();
    float meanSum = 0.0, meanSumSq = 0.0;
    float stddevSum = 0.0, stddevSumSq = 0.0;
    int n = 0;

    for (int i = 0; i < total; i++)
    {
        if (now - g_AVar_History_ClosedAt[client][i] > AVAR_BLOCK_EXPIRE_SECONDS) continue;
        float m = g_AVar_History_Mean[client][i];
        float s = g_AVar_History_Stddev[client][i];
        meanSum += m; meanSumSq += m * m;
        stddevSum += s; stddevSumSq += s * s;
        n++;
    }
    if (n < AVAR_MIN_BLOCKS_FOR_SCORE) return 0;

    float meanOfMeans = meanSum / float(n);
    float varOfMeans = (meanSumSq / float(n)) - (meanOfMeans * meanOfMeans);
    if (varOfMeans < 0.0) varOfMeans = 0.0;

    float meanOfStddevs = stddevSum / float(n);
    float varOfStddevs = (stddevSumSq / float(n)) - (meanOfStddevs * meanOfStddevs);
    if (varOfStddevs < 0.0) varOfStddevs = 0.0;

    // Coefficient of variation of each, so this stays scale-independent
    // (a player with generally fast or slow tracking isn't judged
    // differently than one with generally slow tracking - only how
    // CONSISTENT their own dynamics are across distinct encounters).
    float covOfMeans = (meanOfMeans > 0.5) ? (SquareRoot(varOfMeans) / meanOfMeans) : 1.0;
    float covOfStddevs = (meanOfStddevs > 0.1) ? (SquareRoot(varOfStddevs) / meanOfStddevs) : 1.0;

    // Both need to be unusually tight - a script's control loop produces
    // both a consistent average tracking speed AND a consistent internal
    // smoothness across unrelated encounters.
    float scoreMeans = 0.0;
    if (covOfMeans < 0.25) scoreMeans = VAR_FMin((0.25 - covOfMeans) / 0.20 * 100.0, 100.0);

    float scoreStddevs = 0.0;
    if (covOfStddevs < 0.30) scoreStddevs = VAR_FMin((0.30 - covOfStddevs) / 0.25 * 100.0, 100.0);

    if (scoreMeans <= 0.0 || scoreStddevs <= 0.0) return 0;

    return RoundFloat(SquareRoot(scoreMeans * scoreStddevs));
}

// ------------------------------------------------------------------
// BHOP VARIANCE - called every tick from OnPlayerRunCmd (all players,
// like the existing Bhop module - this is cheap, no per-frame scan).
void Variance_RecordBhopTick(int client, int buttons)
{
    bool onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0;
    bool pressingJump = (buttons & IN_JUMP) != 0;
    float tickMs = GetTickInterval() * 1000.0;

    if (!onGround)
    {
        // Airborne again - if we were waiting on a jump-input timing for
        // the landing that just ended, the player left the ground before
        // ever pressing jump again on this landing (e.g. walked off an
        // edge) - that's not a bhop attempt, discard without penalty.
        g_BVar_WasOnGround[client] = false;
        g_BVar_AwaitingJump[client] = false;
        g_BVar_JumpedLastTick[client] = pressingJump;
        return;
    }

    bool justLanded = !g_BVar_WasOnGround[client] && onGround;
    if (justLanded)
    {
        if (pressingJump || g_BVar_JumpedLastTick[client])
        {
            // Resolved within the 1-tick "perfect" window - 0ms sample.
            g_BVar_SeqJumpCount[client]++;
            VAR_WelfordAdd(g_BVar_SeqMean[client], g_BVar_SeqM2[client], g_BVar_SeqJumpCount[client], 0.0);
            g_BVar_AwaitingJump[client] = false;
        }
        else
        {
            // Not resolved yet - start timing how long this landing
            // takes to get a jump input, counted from THIS tick.
            g_BVar_AwaitingJump[client] = true;
            g_BVar_TicksSinceThisLanding[client] = 0;
        }
        g_BVar_TicksSinceLand[client] = 0;
    }
    else
    {
        g_BVar_TicksSinceLand[client]++;

        if (g_BVar_AwaitingJump[client])
        {
            g_BVar_TicksSinceThisLanding[client]++;
            if (pressingJump)
            {
                // The delayed jump input finally arrived - record its
                // actual timing as a real sample (still part of the same
                // sequence; a late-but-consistent human input isn't a
                // sequence break by itself).
                float gapMs = float(g_BVar_TicksSinceThisLanding[client]) * tickMs;
                g_BVar_SeqJumpCount[client]++;
                VAR_WelfordAdd(g_BVar_SeqMean[client], g_BVar_SeqM2[client], g_BVar_SeqJumpCount[client], gapMs);
                g_BVar_AwaitingJump[client] = false;
            }
        }

        if (g_BVar_TicksSinceLand[client] > BVAR_SEQUENCE_MAX_GAP_TICKS)
        {
            // Genuinely stood still too long without jumping at all -
            // the chain is over.
            g_BVar_AwaitingJump[client] = false;
            Variance_CloseBhopSequence(client);
        }
    }

    g_BVar_WasOnGround[client] = onGround;
    g_BVar_JumpedLastTick[client] = pressingJump;
}

static void Variance_CloseBhopSequence(int client)
{
    int jumps = g_BVar_SeqJumpCount[client];
    float mean = g_BVar_SeqMean[client];
    float m2 = g_BVar_SeqM2[client];

    // Reset for the next sequence regardless of whether this one was long
    // enough to record.
    g_BVar_SeqJumpCount[client] = 0;
    g_BVar_SeqMean[client] = 0.0;
    g_BVar_SeqM2[client] = 0.0;

    if (jumps < BVAR_SEQUENCE_MIN_JUMPS) return; // too short to characterize, discard

    float variance = m2 / float(jumps);
    if (variance < 0.0) variance = 0.0;
    float stddev = SquareRoot(variance);

    int idx = g_BVar_HistoryHead[client];
    g_BVar_History_Mean[client][idx] = mean;
    g_BVar_History_Stddev[client][idx] = stddev;
    g_BVar_History_ClosedAt[client][idx] = GetGameTime();
    g_BVar_HistoryHead[client] = (idx + 1) % BVAR_SEQUENCE_HISTORY;
    if (g_BVar_HistoryCount[client] < BVAR_SEQUENCE_HISTORY) g_BVar_HistoryCount[client]++;

    int score = Variance_GetBhopScore(client);
    if (score > 0) Correlation_ReportEvent(client, CORR_DET_BHOPVARIANCE, score);
}

// ------------------------------------------------------------------
int Variance_GetBhopScore(int client)
{
    int total = g_BVar_HistoryCount[client];
    if (total < BVAR_MIN_SEQUENCES_FOR_SCORE) return 0;

    float now = GetGameTime();
    float stddevSum = 0.0, stddevSumSq = 0.0;
    int n = 0;

    for (int i = 0; i < total; i++)
    {
        if (now - g_BVar_History_ClosedAt[client][i] > BVAR_SEQUENCE_EXPIRE_SECONDS) continue;
        float s = g_BVar_History_Stddev[client][i];
        stddevSum += s; stddevSumSq += s * s;
        n++;
    }
    if (n < BVAR_MIN_SEQUENCES_FOR_SCORE) return 0;

    // Here we judge the ABSOLUTE stddev-of-stddevs (not coefficient of
    // variation) because the "perfect window" gapMs values are already a
    // narrow 0-~15ms range by construction (that's what qualifies as
    // "perfect" at all) - a human hitting that window repeatedly still
    // has jitter of a few ms sequence to sequence; a script's internal
    // timer produces near-zero jitter across totally different jump
    // sequences (different terrain, different point in the map).
    float meanOfStddevs = stddevSum / float(n);
    float varOfStddevs = (stddevSumSq / float(n)) - (meanOfStddevs * meanOfStddevs);
    if (varOfStddevs < 0.0) varOfStddevs = 0.0;
    float stddevOfStddevs = SquareRoot(varOfStddevs);

    if (stddevOfStddevs >= 3.0) return 0; // human range - sequence-to-sequence jitter present

    return RoundFloat(VAR_FMin((3.0 - stddevOfStddevs) / 3.0 * 100.0, 100.0));
}
