// anticheat_bhop2.sp - second, independent bhop detector
// (algorithm ported from srcdslab/sm-plugin-AntiBhopCheat)
// https://github.com/srcdslab/sm-plugin-AntiBhopCheat
//
// The existing Bhop module (anticheat_bhop.sp) scores the RATIO of
// tick-perfect landings plus a gravity honeypot. This one attacks the
// problem from a different angle: it looks at HOW the jump input was
// produced, not just whether it landed on the perfect tick.
//
//   Hyperscroll: a real +jump bind fires the button roughly once per
//   press; a scroll-wheel script or macro spams many +jump events per
//   tick. presses-per-tick >= 0.85 is not something a human thumb does.
//
//   Composite hack jump: a scripted auto-hop chains jumps with a
//   <=1-tick gap, few button presses, AND keeps high outgoing speed -
//   three conditions a human bhopper does not hit simultaneously and
//   repeatedly.
//
// Both are measured over a streak of consecutive jumps; when a long
// enough streak is almost entirely made of flagged jumps, the module
// scores. Kept fully separate from anticheat_bhop.sp so the two act as
// independent corroborating signals.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

// --- streak/jump validity (from AntiBhopCheat) ---
#define B2_VALID_MIN_JUMPS      3      // min jumps to treat a run as a "streak"
#define B2_VALID_MAX_TICKS      5      // gap (ticks) above which the streak breaks
#define B2_VALID_MIN_VELOCITY   250.0  // speed below which the streak breaks
#define B2_VELOCITY_CAP         700.0  // above this, skip analysis (map boost/teleport etc.)

// --- flagging thresholds ---
#define B2_HYPERSCROLL_PPT      0.85   // presses-per-tick at/above this = scroll spam
#define B2_HACK_MAX_GAP_TICKS   1      // scripted next-jump gap
#define B2_HACK_LOOSE_GAP       5      // "gap > this OR few presses" branch
#define B2_HACK_MAX_PRESSES     2
#define B2_HACK_MIN_VELOCITY    285.0

#define B2_CURRENT_MIN_JUMPS    10     // streak length before the "current" ratio is judged
#define B2_GLOBAL_MIN_JUMPS     50     // lifetime jump count before the "global" ratio is judged
#define B2_CURRENT_HYPER_RATIO  0.95
#define B2_CURRENT_HACK_RATIO   0.90
#define B2_GLOBAL_HYPER_RATIO   0.80
#define B2_GLOBAL_HACK_RATIO    0.75

// ------------------------------------------------------------------
// Per-player rolling state
bool  g_B2_WasOnGround[MAXPLAYERS+1];
int   g_B2_TicksSinceLand[MAXPLAYERS+1];   // ticks the player has been on the ground since landing
int   g_B2_PressesThisJump[MAXPLAYERS+1];  // +jump presses seen during the current airborne/landing cycle
bool  g_B2_JumpHeldLastTick[MAXPLAYERS+1];
int   g_B2_TicksAirborne[MAXPLAYERS+1];

// current streak
int   g_B2_StreakLen[MAXPLAYERS+1];
int   g_B2_StreakHyper[MAXPLAYERS+1];
int   g_B2_StreakHack[MAXPLAYERS+1];

// lifetime totals
int   g_B2_TotalJumps[MAXPLAYERS+1];
int   g_B2_TotalHyper[MAXPLAYERS+1];
int   g_B2_TotalHack[MAXPLAYERS+1];

// worst confirmed result so far (0-100), decays only on Init
int   g_B2_Score[MAXPLAYERS+1];

// ------------------------------------------------------------------
void Bhop2_Init(int client)
{
    g_B2_WasOnGround[client] = false;
    g_B2_TicksSinceLand[client] = 0;
    g_B2_PressesThisJump[client] = 0;
    g_B2_JumpHeldLastTick[client] = false;
    g_B2_TicksAirborne[client] = 0;
    g_B2_StreakLen[client] = 0;
    g_B2_StreakHyper[client] = 0;
    g_B2_StreakHack[client] = 0;
    g_B2_TotalJumps[client] = 0;
    g_B2_TotalHyper[client] = 0;
    g_B2_TotalHack[client] = 0;
    g_B2_Score[client] = 0;
}

// ------------------------------------------------------------------
static void Bhop2_ResetStreak(int client)
{
    g_B2_StreakLen[client] = 0;
    g_B2_StreakHyper[client] = 0;
    g_B2_StreakHack[client] = 0;
}

static float Bhop2_HorizontalSpeed(int client)
{
    float vel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
    return SquareRoot(vel[0]*vel[0] + vel[1]*vel[1]);
}

// ------------------------------------------------------------------
// Called every tick from OnPlayerRunCmd (survivor only).
void Bhop2_RecordTick(int client, int buttons)
{
    bool onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0;
    bool jumpHeld = (buttons & IN_JUMP) != 0;

    // Count a "press" as a rising edge of IN_JUMP.
    bool pressEdge = jumpHeld && !g_B2_JumpHeldLastTick[client];
    if (pressEdge) g_B2_PressesThisJump[client]++;
    g_B2_JumpHeldLastTick[client] = jumpHeld;

    if (!onGround)
    {
        g_B2_TicksAirborne[client]++;
        g_B2_WasOnGround[client] = false;
        return;
    }

    // On ground this tick.
    if (!g_B2_WasOnGround[client])
    {
        // Just landed. The airborne phase that just ended was one jump in
        // a potential chain. Evaluate it now.
        int airTicks = g_B2_TicksAirborne[client];
        float speed = Bhop2_HorizontalSpeed(client);

        Bhop2_EvaluateJump(client, airTicks, speed);

        g_B2_TicksSinceLand[client] = 0;
        g_B2_TicksAirborne[client] = 0;
        g_B2_PressesThisJump[client] = 0;
    }
    else
    {
        g_B2_TicksSinceLand[client]++;
        // Stood on the ground too long - the chain is over.
        if (g_B2_TicksSinceLand[client] > B2_VALID_MAX_TICKS)
        {
            Bhop2_ResetStreak(client);
        }
    }

    g_B2_WasOnGround[client] = true;
}

// ------------------------------------------------------------------
// One completed jump (airborne phase + the landing). `gapTicks` is how
// long they were on the ground before this jump started - we approximate
// it with TicksSinceLand captured at takeoff; here we use the current
// value which is 0 on a chained hop and grows when they linger.
static void Bhop2_EvaluateJump(int client, int airTicks, float outVelocity)
{
    #pragma unused airTicks

    if (outVelocity > B2_VELOCITY_CAP) { Bhop2_ResetStreak(client); return; }

    int gapTicks = g_B2_TicksSinceLand[client]; // ground ticks before this hop
    int presses  = g_B2_PressesThisJump[client];

    // Streak continuity: chained hop (small gap) at decent speed.
    bool continues = (gapTicks <= B2_VALID_MAX_TICKS) && (outVelocity >= B2_VALID_MIN_VELOCITY);
    if (!continues)
    {
        Bhop2_ResetStreak(client);
        // this jump still starts a fresh streak of length 1
    }

    g_B2_StreakLen[client]++;
    g_B2_TotalJumps[client]++;

    // --- hyperscroll: presses per tick over the airborne phase ---
    // presses*4 / ticks in AntiBhopCheat (their tick unit differs); here
    // airTicks is small for a chained hop so we guard against div-by-zero.
    int denomTicks = airTicks > 0 ? airTicks : 1;
    float pressesPerTick = float(presses) / float(denomTicks);
    bool isHyper = (pressesPerTick >= B2_HYPERSCROLL_PPT) && (presses >= 3);
    if (isHyper)
    {
        g_B2_StreakHyper[client]++; g_B2_TotalHyper[client]++;
        Correlation_ReportEvent(client, CORR_DET_BHOP2, RoundFloat(pressesPerTick * 60.0));
    }

    // --- composite hack jump ---
    bool isHack = (gapTicks <= B2_HACK_MAX_GAP_TICKS)
               && (gapTicks > B2_HACK_LOOSE_GAP || presses <= B2_HACK_MAX_PRESSES)
               && (outVelocity >= B2_HACK_MIN_VELOCITY);
    if (isHack)
    {
        g_B2_StreakHack[client]++; g_B2_TotalHack[client]++;
        Correlation_ReportEvent(client, CORR_DET_BHOP2, 65);
    }

    Bhop2_Judge(client);
}

// ------------------------------------------------------------------
static void Bhop2_Judge(int client)
{
    // Current streak judgement.
    if (g_B2_StreakLen[client] >= B2_CURRENT_MIN_JUMPS)
    {
        float hyperRatio = float(g_B2_StreakHyper[client]) / float(g_B2_StreakLen[client]);
        float hackRatio  = float(g_B2_StreakHack[client])  / float(g_B2_StreakLen[client]);

        if (hyperRatio >= B2_CURRENT_HYPER_RATIO || hackRatio >= B2_CURRENT_HACK_RATIO)
        {
            if (g_B2_Score[client] < 100) g_B2_Score[client] = 100;
        }
    }

    // Lifetime judgement - slower to trip, harder to argue with.
    if (g_B2_TotalJumps[client] >= B2_GLOBAL_MIN_JUMPS)
    {
        float hyperRatio = float(g_B2_TotalHyper[client]) / float(g_B2_TotalJumps[client]);
        float hackRatio  = float(g_B2_TotalHack[client])  / float(g_B2_TotalJumps[client]);

        if (hyperRatio >= B2_GLOBAL_HYPER_RATIO || hackRatio >= B2_GLOBAL_HACK_RATIO)
        {
            if (g_B2_Score[client] < 100) g_B2_Score[client] = 100;
        }
        else if (hyperRatio >= B2_GLOBAL_HYPER_RATIO * 0.75 || hackRatio >= B2_GLOBAL_HACK_RATIO * 0.75)
        {
            // Approaching the threshold - partial score.
            int partial = RoundFloat(60.0 + 40.0 *
                ((hackRatio / B2_GLOBAL_HACK_RATIO > hyperRatio / B2_GLOBAL_HYPER_RATIO)
                    ? (hackRatio / B2_GLOBAL_HACK_RATIO)
                    : (hyperRatio / B2_GLOBAL_HYPER_RATIO)));
            if (partial > 100) partial = 100;
            if (g_B2_Score[client] < partial) g_B2_Score[client] = partial;
        }
    }
}

// ------------------------------------------------------------------
int Bhop2_GetScore(int client)
{
    return g_B2_Score[client];
}
