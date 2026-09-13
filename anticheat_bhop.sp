// anticheat_bhop.sp - Automatic Bunny Hop Detector for L4D2 Anti-Cheat
//
// Detection method: Analyzes the timing of jump inputs relative to landing
// events. When a player lands, there is a 1-tick window to jump and keep
// full momentum.
//
// KEY INSIGHT (terrain-aware scoring): on FLAT ground, hitting that 1-tick
// window by hand is genuinely easy - a good human bhopper lands at the
// same height every time, so their rhythm is predictable and a high
// perfect-jump ratio there is NOT strong evidence. On UNEVEN terrain
// (ramps, stairs, ledges, slopes) every landing arrives at a different
// height with a different fall time, so a human cannot pre-time the jump -
// they have to react to a landing they could not predict, and their
// perfect ratio collapses. A script does not care about terrain at all:
// it reacts to the FL_ONGROUND flag, so it stays perfect on flat AND
// uneven ground alike.
//
// So this module weights each jump by how much the landing height changed
// from the previous one. Perfect jumps on varied-height terrain are what
// actually score; perfect jumps on dead-flat ground barely move the
// needle.
//
// It also watches for a SECOND script tell (Metric 4): a long chain of
// perfect jumps where the player never air-strafes. A human keeping a
// bhop chain alive MUST air-strafe every jump to hold speed; someone on
// an auto-bhop who can't actually bhop won't - they just steer. So
// perfect chain + no air-strafe = "auto-bhop, no skill".

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

// ------------------------------------------------------------------
#define BHOP_HISTORY   64    // how many jump attempts to remember
#define BHOP_MIN_JUMPS 25    // minimum samples before scoring
#define BHOP_STREAK_ALERT 10 // consecutive perfect jumps = instant high score

// Shared "how long does a confirmed event still count" window for the
// newer per-event metrics below (5 and 6) - same idea as EVENT_EXPIRE_
// SECONDS in anticheat_aim.sp: a player who did this once and has since
// played clean shouldn't stay flagged forever.
#define BHOP_EVENT_EXPIRE_SECONDS 600.0

static float FMinBhop(float a, float b) { return a < b ? a : b; }

// A landing whose height differs from the previous landing by at least
// this many units counts as "terrain changed" - the jump could not have
// been pre-timed. ~18 units is roughly one stair step in L4D2.
#define BHOP_TERRAIN_STEP_UNITS 18.0
// Minimum number of perfect jumps ON VARIED TERRAIN before the
// terrain-aware metric will score at all.
#define BHOP_MIN_VARIED_PERFECT 6

// ------------------------------------------------------------------
// Gravity honeypot (technique credited to StAC-tf2): once a player racks
// up enough perfect-landing jumps in a row to already be very suspicious,
// silently multiply their gravity for a few jumps. A human bhopper's
// timing is built around normal gravity and falls apart the moment the
// arc changes; a script keeps hitting the same 1-tick window regardless,
// because it isn't reacting to feel at all - it's reacting to the
// FL_ONGROUND flag. Surviving that stretch with the same perfect ratio is
// close to physically impossible for a human and makes for very hard
// evidence to argue with.
#define BHOP_HONEYPOT_STREAK   8     // consecutive perfect jumps that triggers it
#define BHOP_HONEYPOT_GRAV_MIN 6.1
#define BHOP_HONEYPOT_GRAV_MAX 7.9
#define BHOP_HONEYPOT_JUMPS    3     // perfect jumps to survive under honeypot gravity for max bonus

// ------------------------------------------------------------------
// Metric 4: MISSING air-strafe during a long bhop chain.
//
// In Source engine you cannot keep bhopping fast without air-strafing:
// on every jump you must sweep the mouse left/right in sync with the A/D
// keys to gain (or even keep) speed. A skilled human bhopper ALWAYS does
// this - it's not optional, it's how the movement works.
//
// An auto-bhop script keeps the speed for you. Someone using one who
// doesn't actually know how to bhop won't air-strafe at all - they'll
// just move the mouse to steer where they're going, or barely move it.
// So: a long chain of perfect jumps with NO real air-strafe pattern on
// them is a strong "auto-bhop, no skill" signal.
//
// A jump counts as "air-strafed" when, during its airborne phase:
//   - exactly one of A / D was held for a meaningful fraction of the flight
//   - the yaw turned in the matching direction (A => yaw increases /
//     turn left, D => yaw decreases) by at least a small amount
//   - across the chain, the strafe direction alternates (not one constant
//     turn, which is just walking in a circle)
#define BHOP_STRAFE_MIN_CHAIN      6      // only judge chains at least this long
#define BHOP_STRAFE_MIN_YAW_DEG    3.0    // min yaw sweep in the strafe direction per jump
#define BHOP_STRAFE_KEY_FRACTION   0.4    // A or D must be held this fraction of airborne ticks
#define BHOP_NOSTRAFE_RATIO        0.70   // if >= this fraction of a long chain's jumps had no
                                         // air-strafe, that's the suspicious pattern

// ------------------------------------------------------------------
// Metric 5: "Static Turn Rate" (technique credited to Oryx-AC) - a
// silent/auto air-strafe script doesn't just hold A or D, it turns the
// view by the mathematically OPTIMAL yaw delta every single tick: the
// angle that converts the most speed into forward gain for the player's
// current velocity, derived from Source's air-acceleration formula as
// asin(30.0 / speed) in degrees. A human chasing max bhop speed gets
// CLOSE to that angle by feel, but never locks onto it turn after turn -
// their real delta wobbles tick to tick. A script computes the same
// optimized angle every tick and turns exactly that much, so its delta
// sits pinned to the target angle with near-zero deviation for a long,
// unbroken run while airborne.
#define TURNRATE_MAX_SPEED       2560.0  // above this the airstrafe optimum stops being meaningful (surf-like speed)
#define TURNRATE_MIN_SPEED        100.0  // below this the asin() argument blows up / isn't a real strafe attempt
#define TURNRATE_TOLERANCE_DEG      0.35 // how close to the optimum counts as "locked on"
#define TURNRATE_MIN_STREAK          10  // consecutive locked-on ticks needed before this counts as evidence
#define TURNRATE_EVENT_HISTORY       12
int   g_BH_TurnRateStreak[MAXPLAYERS+1];
float g_BH_TurnRateEventTime[MAXPLAYERS+1][TURNRATE_EVENT_HISTORY];
int   g_BH_TurnRateEventHead[MAXPLAYERS+1];
int   g_BH_TurnRateEventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
// Metric 6: "Strafe-Key Sync" (technique credited to Oryx-AC's BASH
// module) - measures the tick gap between a strafe key (A/D) changing
// state and the view yaw actually turning in the matching direction. A
// human's mouse hand reacts to their own keypress with real, variable
// lag - never the same tick, over and over. A silent-strafe / auto-sync
// script turns the view on the EXACT same tick the key state changes,
// every time, because both are driven by the same code path instead of
// a hand pressing a key and separately moving a mouse.
#define SYNC_MIN_YAW_DEG          1.0    // minimum yaw turn this tick to count as "a real strafe turn"
#define SYNC_PERFECT_TICK_GAP       0    // key-change-to-turn gap of exactly this = a "perfect" sync sample
#define SYNC_HISTORY 30                  // last N judged strafe transitions
#define SYNC_MIN_SAMPLES           18
#define SYNC_PERFECT_RATIO         0.80  // this fraction of samples at perfect sync is the tell
bool  g_BH_SyncPrevLeft[MAXPLAYERS+1];
bool  g_BH_SyncPrevRight[MAXPLAYERS+1];
int   g_BH_SyncTicksSinceKeyChange[MAXPLAYERS+1];
bool  g_BH_SyncAwaitingTurn[MAXPLAYERS+1];
int   g_BH_SyncGapTicks[MAXPLAYERS+1][SYNC_HISTORY]; // tick gap recorded per judged sample (capped)
int   g_BH_SyncHead[MAXPLAYERS+1];
int   g_BH_SyncCount[MAXPLAYERS+1];
float g_BH_SyncLastEventTime[MAXPLAYERS+1];

// ------------------------------------------------------------------
// Per-player state
bool  g_BH_WasOnGround[MAXPLAYERS+1];      // was player on ground last tick?
bool  g_BH_JumpedLastTick[MAXPLAYERS+1];   // did player send IN_JUMP last tick?

// History ring buffer: true = perfect jump (jumped within 1 tick of landing)
bool  g_BH_History[MAXPLAYERS+1][BHOP_HISTORY];
// Parallel buffer: true = this landing's height differed from the previous
// landing by >= BHOP_TERRAIN_STEP_UNITS (terrain changed, jump could not
// be pre-timed).
bool  g_BH_VariedTerrain[MAXPLAYERS+1][BHOP_HISTORY];
// Parallel buffer: -1 = this perfect jump was part of a long chain and had
// NO air-strafe; +1 = it had a real air-strafe; 0 = not part of a judged
// chain / not a perfect jump.
int   g_BH_StrafeMark[MAXPLAYERS+1][BHOP_HISTORY];
int   g_BH_Head[MAXPLAYERS+1];
int   g_BH_Count[MAXPLAYERS+1];

// Last landing height, to measure terrain change between consecutive jumps.
float g_BH_LastLandZ[MAXPLAYERS+1];
bool  g_BH_HasLastLandZ[MAXPLAYERS+1];

// --- Per-jump air-strafe accumulation (reset each takeoff) ---
int   g_BH_AirTicks[MAXPLAYERS+1];       // ticks spent airborne this jump
int   g_BH_KeyLeftTicks[MAXPLAYERS+1];   // ticks with IN_MOVELEFT (A) held, airborne
int   g_BH_KeyRightTicks[MAXPLAYERS+1];  // ticks with IN_MOVERIGHT (D) held, airborne
float g_BH_YawLeftSweep[MAXPLAYERS+1];   // total yaw turned "left" (increasing) while airborne
float g_BH_YawRightSweep[MAXPLAYERS+1];  // total yaw turned "right" (decreasing) while airborne
float g_BH_PrevYaw[MAXPLAYERS+1];
bool  g_BH_HasPrevYaw[MAXPLAYERS+1];

// Streak tracking (streaks only count perfect jumps on varied terrain -
// a long perfect streak on flat ground is not the signal we want).
int   g_BH_CurrentStreak[MAXPLAYERS+1];
int   g_BH_MaxStreak[MAXPLAYERS+1];

// Honeypot state
bool  g_BH_HoneypotActive[MAXPLAYERS+1];
int   g_BH_HoneypotPerfectCount[MAXPLAYERS+1]; // perfect jumps survived while active
int   g_BH_HoneypotBonus[MAXPLAYERS+1];        // accumulated score bonus from surviving it

// ------------------------------------------------------------------
void Bhop_Init(int client)
{
    g_BH_WasOnGround[client]    = false;
    g_BH_JumpedLastTick[client] = false;
    g_BH_Head[client]           = 0;
    g_BH_Count[client]          = 0;
    g_BH_CurrentStreak[client]  = 0;
    g_BH_MaxStreak[client]      = 0;
    g_BH_HasLastLandZ[client]   = false;

    g_BH_AirTicks[client]       = 0;
    g_BH_KeyLeftTicks[client]   = 0;
    g_BH_KeyRightTicks[client]  = 0;
    g_BH_YawLeftSweep[client]   = 0.0;
    g_BH_YawRightSweep[client]  = 0.0;
    g_BH_HasPrevYaw[client]     = false;
    for (int i = 0; i < BHOP_HISTORY; i++) g_BH_StrafeMark[client][i] = 0;

    if (g_BH_HoneypotActive[client] && IsClientInGame(client))
    {
        SetEntityGravity(client, 1.0);
    }
    g_BH_HoneypotActive[client] = false;
    g_BH_HoneypotPerfectCount[client] = 0;
    g_BH_HoneypotBonus[client] = 0;

    g_BH_TurnRateStreak[client] = 0;
    g_BH_TurnRateEventHead[client] = 0;
    g_BH_TurnRateEventCount[client] = 0;

    g_BH_SyncPrevLeft[client] = false;
    g_BH_SyncPrevRight[client] = false;
    g_BH_SyncTicksSinceKeyChange[client] = 0;
    g_BH_SyncAwaitingTurn[client] = false;
    g_BH_SyncHead[client] = 0;
    g_BH_SyncCount[client] = 0;
    g_BH_SyncLastEventTime[client] = 0.0;
}

// ------------------------------------------------------------------
static float Bhop_FAbs(float v) { return v < 0.0 ? -v : v; }

// "Static Turn Rate" check (see comment near TURNRATE_* constants above).
// Computes this tick's mathematically optimal air-strafe angle for the
// player's current ground-plane speed and checks how close the real yaw
// delta landed to it.
static void Bhop_CheckStaticTurnRate(int client, float dy)
{
    float vel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
    float speed = SquareRoot(vel[0]*vel[0] + vel[1]*vel[1]);

    if (speed < TURNRATE_MIN_SPEED || speed > TURNRATE_MAX_SPEED)
    {
        g_BH_TurnRateStreak[client] = 0;
        return;
    }

    // asin() argument must stay in [-1, 1] - guard the edge the same way
    // Oryx-AC's reference implementation does before the ratio ever gets
    // there, rather than let a math domain error zero it out silently.
    float ratio = 30.0 / speed;
    if (ratio > 1.0) ratio = 1.0;
    float optimalDeg = ArcSine(ratio) * 57.29577951308232;

    float realDeg = Bhop_FAbs(dy);
    float diff = Bhop_FAbs(realDeg - optimalDeg);

    if (diff <= TURNRATE_TOLERANCE_DEG)
    {
        g_BH_TurnRateStreak[client]++;
        if (g_BH_TurnRateStreak[client] >= TURNRATE_MIN_STREAK)
        {
            int idx = g_BH_TurnRateEventHead[client];
            g_BH_TurnRateEventTime[client][idx] = GetGameTime();
            g_BH_TurnRateEventHead[client] = (idx + 1) % TURNRATE_EVENT_HISTORY;
            if (g_BH_TurnRateEventCount[client] < TURNRATE_EVENT_HISTORY) g_BH_TurnRateEventCount[client]++;

            // Severity: a longer unbroken lock onto the mathematical
            // optimum is stronger evidence - a human's feel-based strafe
            // does not stay pinned this tightly this long.
            int severity = RoundFloat(50.0 + float(g_BH_TurnRateStreak[client] - TURNRATE_MIN_STREAK) * 3.0);
            Correlation_ReportEvent(client, CORR_DET_BHOP_TURNRATE, severity);
            g_BH_TurnRateStreak[client] = 0; // one confirmed lock-on = one event, keep judging fresh
        }
    }
    else
    {
        g_BH_TurnRateStreak[client] = 0;
    }
}

// "Strafe-Key Sync" check (see comment near SYNC_* constants above). Waits
// for a strafe key's state to change, then measures how many ticks pass
// before the view actually turns in the matching direction.
static void Bhop_CheckStrafeSync(int client, int buttons, float dy)
{
    bool left  = (buttons & IN_MOVELEFT)  != 0;
    bool right = (buttons & IN_MOVERIGHT) != 0;

    bool keyChanged = (left != g_BH_SyncPrevLeft[client]) || (right != g_BH_SyncPrevRight[client]);
    g_BH_SyncPrevLeft[client] = left;
    g_BH_SyncPrevRight[client] = right;

    if (keyChanged)
    {
        g_BH_SyncAwaitingTurn[client] = true;
        g_BH_SyncTicksSinceKeyChange[client] = 0;
        return; // the turn that answers THIS change starts being measured next tick
    }

    if (!g_BH_SyncAwaitingTurn[client]) return;

    g_BH_SyncTicksSinceKeyChange[client]++;

    // Exactly one of left/right held is a real strafe attempt to judge;
    // both or neither isn't a clean sample.
    bool oneKeyHeld = (left != right);
    if (!oneKeyHeld) { g_BH_SyncAwaitingTurn[client] = false; return; }

    bool turnedMatchingDir = (left && dy > 0.0) || (right && dy < 0.0);
    if (Bhop_FAbs(dy) < SYNC_MIN_YAW_DEG) return; // no real turn yet, keep waiting a few more ticks

    g_BH_SyncAwaitingTurn[client] = false; // this transition is now judged either way

    if (!turnedMatchingDir) return; // turned the wrong way - not a clean sample, discard

    int gap = g_BH_SyncTicksSinceKeyChange[client] - 1; // ticks between the key change and the turn landing
    int idx = g_BH_SyncHead[client];
    g_BH_SyncGapTicks[client][idx] = gap;
    g_BH_SyncHead[client] = (idx + 1) % SYNC_HISTORY;
    if (g_BH_SyncCount[client] < SYNC_HISTORY) g_BH_SyncCount[client]++;

    int total = g_BH_SyncCount[client];
    if (total < SYNC_MIN_SAMPLES) return;

    int perfect = 0;
    for (int i = 0; i < total; i++)
    {
        if (g_BH_SyncGapTicks[client][i] <= SYNC_PERFECT_TICK_GAP) perfect++;
    }
    float perfectRatio = float(perfect) / float(total);
    if (perfectRatio < SYNC_PERFECT_RATIO) return;

    float now = GetGameTime();
    if (now - g_BH_SyncLastEventTime[client] < 3.0) return; // don't re-fire every single qualifying sample
    g_BH_SyncLastEventTime[client] = now;

    int severity = RoundFloat(45.0 + (perfectRatio - SYNC_PERFECT_RATIO) / (1.0 - SYNC_PERFECT_RATIO) * 55.0);
    Correlation_ReportEvent(client, CORR_DET_BHOP_SYNC, severity);
}

// ------------------------------------------------------------------
// Called every tick from OnPlayerRunCmd
void Bhop_RecordTick(int client, int buttons, const float angles[3])
{
    bool onGround    = (GetEntityFlags(client) & FL_ONGROUND) != 0;
    bool pressingJump = (buttons & IN_JUMP) != 0;

    // --- Air-strafe accumulation (only while airborne) ---
    if (!onGround)
    {
        g_BH_AirTicks[client]++;
        if (buttons & IN_MOVELEFT)  g_BH_KeyLeftTicks[client]++;
        if (buttons & IN_MOVERIGHT) g_BH_KeyRightTicks[client]++;

        if (g_BH_HasPrevYaw[client])
        {
            float dy = angles[1] - g_BH_PrevYaw[client];
            // normalize to (-180, 180]
            while (dy > 180.0)  dy -= 360.0;
            while (dy <= -180.0) dy += 360.0;
            // In Source, yaw INCREASES when you turn left. An A-key
            // air-strafe turns left; a D-key air-strafe turns right.
            if (dy > 0.0) g_BH_YawLeftSweep[client]  += dy;
            else          g_BH_YawRightSweep[client] += -dy;

            Bhop_CheckStaticTurnRate(client, dy);
            Bhop_CheckStrafeSync(client, buttons, dy);
        }
        g_BH_PrevYaw[client] = angles[1];
        g_BH_HasPrevYaw[client] = true;
    }
    else
    {
        // Grounded - no airborne strafe to judge this tick. A sync sample
        // waiting on a turn that never came (landed mid-measurement) is
        // simply dropped rather than counted either way.
        g_BH_SyncAwaitingTurn[client] = false;
    }

    // Detect landing: the player went from airborne last tick to on ground this tick.
    // This is the moment when a perfect bhop can be performed.
    bool justLanded = !g_BH_WasOnGround[client] && onGround;

    if (justLanded)
    {
        // Did the player press jump in this exact tick (first tick on ground)?
        // That's what auto-bhop does. Humans almost always take 1+ extra ticks.
        // Usercmd delivery and physics order can shift the input by one tick.
        bool perfectJump = pressingJump || g_BH_JumpedLastTick[client];

        // How much did the ground height change since the previous landing?
        // A big change means the player could not have pre-timed this jump.
        float landPos[3];
        GetClientAbsOrigin(client, landPos);
        bool variedTerrain = false;
        if (g_BH_HasLastLandZ[client])
        {
            float dz = landPos[2] - g_BH_LastLandZ[client];
            if (dz < 0.0) dz = -dz;
            variedTerrain = (dz >= BHOP_TERRAIN_STEP_UNITS);
        }
        g_BH_LastLandZ[client] = landPos[2];
        g_BH_HasLastLandZ[client] = true;

        // --- Classify the air-strafe of the jump that just ended ---
        // Did the player do a real air-strafe during the airborne phase?
        int strafeMark = 0; // 0 = not judged this jump
        int airT = g_BH_AirTicks[client];
        if (perfectJump && airT >= 3)
        {
            float keyFrac = BHOP_STRAFE_KEY_FRACTION * float(airT);
            bool heldLeft  = float(g_BH_KeyLeftTicks[client])  >= keyFrac;
            bool heldRight = float(g_BH_KeyRightTicks[client]) >= keyFrac;

            // Exactly one direction key, matching yaw sweep in that direction.
            bool leftStrafe  = heldLeft  && !heldRight && g_BH_YawLeftSweep[client]  >= BHOP_STRAFE_MIN_YAW_DEG;
            bool rightStrafe = heldRight && !heldLeft  && g_BH_YawRightSweep[client] >= BHOP_STRAFE_MIN_YAW_DEG;

            if (leftStrafe || rightStrafe)
                strafeMark = 1;  // real air-strafe on this jump
            else
                strafeMark = -1; // perfect jump, but NO air-strafe
        }

        int idx = g_BH_Head[client];
        g_BH_History[client][idx] = perfectJump;
        g_BH_VariedTerrain[client][idx] = variedTerrain;
        g_BH_StrafeMark[client][idx] = strafeMark;
        g_BH_Head[client] = (idx + 1) % BHOP_HISTORY;
        if (g_BH_Count[client] < BHOP_HISTORY) g_BH_Count[client]++;

        // Reset the per-jump air-strafe accumulators for the next hop.
        g_BH_AirTicks[client]      = 0;
        g_BH_KeyLeftTicks[client]  = 0;
        g_BH_KeyRightTicks[client] = 0;
        g_BH_YawLeftSweep[client]  = 0.0;
        g_BH_YawRightSweep[client] = 0.0;

        // Streak tracking - only perfect jumps on VARIED terrain extend the
        // streak. A perfect jump on flat ground neither extends nor breaks
        // it (it's just not evidence either way); a MISS always breaks it.
        if (!perfectJump)
        {
            g_BH_CurrentStreak[client] = 0;
            // A miss under honeypot gravity is exactly what a human would
            // do - stand down without penalty, this landing wasn't a lie.
            if (g_BH_HoneypotActive[client])
            {
                SetEntityGravity(client, 1.0);
                g_BH_HoneypotActive[client] = false;
                g_BH_HoneypotPerfectCount[client] = 0;
            }
        }
        else if (variedTerrain)
        {
            g_BH_CurrentStreak[client]++;
            if (g_BH_CurrentStreak[client] > g_BH_MaxStreak[client])
                g_BH_MaxStreak[client] = g_BH_CurrentStreak[client];
        }

        if (g_BH_HoneypotActive[client] && perfectJump)
        {
            g_BH_HoneypotPerfectCount[client]++;
            // Kept hitting the 1-tick window even with gravity thrown off -
            // a human's felt timing would have broken by now. Score it and
            // let the honeypot keep running in case they keep proving it.
            if (g_BH_HoneypotPerfectCount[client] >= BHOP_HONEYPOT_JUMPS)
            {
                g_BH_HoneypotBonus[client] = 100;
                // Physical-impossibility evidence, not a statistical
                // tendency - report at max severity.
                Correlation_ReportEvent(client, CORR_DET_BHOP_RATIO, 100);
            }
        }
        else if (!g_BH_HoneypotActive[client] && g_BH_CurrentStreak[client] >= BHOP_HONEYPOT_STREAK)
        {
            // Already a very suspicious streak under normal gravity - throw
            // off their timing and see if they keep hopping perfectly.
            float grav = float_rand_bhop(BHOP_HONEYPOT_GRAV_MIN, BHOP_HONEYPOT_GRAV_MAX);
            SetEntityGravity(client, grav);
            g_BH_HoneypotActive[client] = true;
            g_BH_HoneypotPerfectCount[client] = 0;
        }
    }

    // Save state for next tick
    g_BH_WasOnGround[client]    = onGround;
    g_BH_JumpedLastTick[client] = pressingJump;
}

// ------------------------------------------------------------------
int Bhop_GetScore(int client)
{
    int count = g_BH_Count[client];
    if (count < BHOP_MIN_JUMPS) return 0;

    // Tally overall and terrain-split.
    int perfectJumps = 0;
    int variedTotal = 0;
    int variedPerfect = 0;
    int strafeJudged = 0;   // perfect jumps we could judge air-strafe on
    int noStrafeJumps = 0;  // ...of those, how many had NO air-strafe
    for (int i = 0; i < count; i++)
    {
        bool p = g_BH_History[client][i];
        if (p) perfectJumps++;
        if (g_BH_VariedTerrain[client][i])
        {
            variedTotal++;
            if (p) variedPerfect++;
        }
        int sm = g_BH_StrafeMark[client][i];
        if (sm != 0)
        {
            strafeJudged++;
            if (sm == -1) noStrafeJumps++;
        }
    }
    float flatRatio = float(perfectJumps) / float(count);

    // --- Metric 1: perfect-jump ratio ON VARIED TERRAIN ---
    // This is the real signal. Landing perfectly again and again when the
    // ground height keeps changing is something a human hand cannot do -
    // they can't pre-time a jump onto a surface they haven't landed on yet.
    // A script hits it anyway because it only watches FL_ONGROUND.
    float ratioScore = 0.0;
    if (variedTotal >= BHOP_MIN_VARIED_PERFECT && variedPerfect >= BHOP_MIN_VARIED_PERFECT)
    {
        float vRatio = float(variedPerfect) / float(variedTotal);
        // Humans on uneven terrain land perfect maybe 15-35% of the time.
        // <50%  = human range = 0 pts
        // 50-70% = suspicious
        // 70-88% = very suspicious
        // >88%  = script
        if (vRatio < 0.50)       ratioScore = 0.0;
        else if (vRatio < 0.70)  ratioScore = (vRatio - 0.50) / 0.20 * 45.0;         // 0-45
        else if (vRatio < 0.88)  ratioScore = 45.0 + (vRatio - 0.70) / 0.18 * 40.0;  // 45-85
        else                     ratioScore = 85.0 + (vRatio - 0.88) / 0.12 * 15.0;  // 85-100
    }

    // --- Metric 1b: flat-ground ratio, heavily discounted ---
    // A very high flat-ground ratio still means *something* (a casual
    // bhopper doesn't hit 90%+), but it is weak evidence on its own, so it
    // is capped low and only contributes when it is extreme.
    float flatScore = 0.0;
    if (flatRatio >= 0.85)
        flatScore = (flatRatio - 0.85) / 0.15 * 30.0; // 0-30 only, and only above 85%

    float bestRatioScore = ratioScore > flatScore ? ratioScore : flatScore;

    // --- Metric 2: max perfect streak on varied terrain ---
    // The streak counter only advances on varied-terrain perfect jumps
    // (see Bhop_RecordTick), so this is already terrain-filtered.
    float streakBonus = 0.0;
    int maxStreak = g_BH_MaxStreak[client];
    if (maxStreak >= BHOP_STREAK_ALERT)
    {
        streakBonus = float(maxStreak - BHOP_STREAK_ALERT) * 4.0;
        if (streakBonus > 30.0) streakBonus = 30.0;
    }

    float combined = bestRatioScore * 0.75 + streakBonus;
    if (combined > 100.0) combined = 100.0;

    // --- Metric 4: perfect bhop chain WITHOUT air-strafe ---
    // A skilled human keeps a bhop chain alive by air-strafing every jump -
    // it is mechanically required to hold speed. Someone on an auto-bhop
    // who can't actually bhop won't strafe; they'll just steer. So a long
    // run of perfect jumps where most had no real air-strafe is the
    // "auto-bhop, no skill" signature.
    if (strafeJudged >= BHOP_STRAFE_MIN_CHAIN)
    {
        float noStrafeRatio = float(noStrafeJumps) / float(strafeJudged);
        if (noStrafeRatio >= BHOP_NOSTRAFE_RATIO)
        {
            // Scales from ~55 at the threshold up to 100 when essentially
            // every perfect jump in a long chain had no strafe at all.
            float m4 = 55.0 + (noStrafeRatio - BHOP_NOSTRAFE_RATIO) / (1.0 - BHOP_NOSTRAFE_RATIO) * 45.0;
            // Only count it as strong once the sample is solid - a handful
            // of judged jumps isn't enough.
            if (strafeJudged >= BHOP_STRAFE_MIN_CHAIN * 2 && m4 > combined) combined = m4;
            else if (m4 * 0.6 > combined) combined = m4 * 0.6; // provisional weight on a small sample
        }
    }
    if (combined > 100.0) combined = 100.0;

    // --- Metric 5: static turn rate (optimized air-strafe angle) ---
    // Each confirmed event already required a long unbroken lock onto the
    // mathematically-derived optimum (see Bhop_CheckStaticTurnRate), so
    // this is judged evidence, not a raw sample - even one recent event
    // is meaningful, repeats push it to the cap fast.
    int turnRateRecent = 0;
    {
        float now5 = GetGameTime();
        int total5 = g_BH_TurnRateEventCount[client];
        for (int i = 0; i < total5; i++)
        {
            if (now5 - g_BH_TurnRateEventTime[client][i] <= BHOP_EVENT_EXPIRE_SECONDS) turnRateRecent++;
        }
    }
    if (turnRateRecent >= 1)
    {
        float m5 = FMinBhop(65.0 + float(turnRateRecent - 1) * 15.0, 100.0);
        if (m5 > combined) combined = m5;
    }

    // --- Metric 6: strafe-key-to-yaw sync ---
    // Correlation_ReportEvent for this path is already gated on a tight
    // perfect-sync ratio across a real sample (see Bhop_CheckStrafeSync),
    // so a confirmed report here is a judged pattern, not a raw count.
    int syncRecent = 0;
    {
        float now6 = GetGameTime();
        int total6 = g_BH_SyncCount[client];
        // Sync doesn't keep a separate event-time ring (the gap samples
        // ARE the ring); use the last-event timestamp as a simple
        // recency gate instead - one qualifying report is enough given
        // how tightly Bhop_CheckStrafeSync already gates it.
        if (total6 >= SYNC_MIN_SAMPLES && now6 - g_BH_SyncLastEventTime[client] <= BHOP_EVENT_EXPIRE_SECONDS
            && g_BH_SyncLastEventTime[client] > 0.0)
        {
            syncRecent = 1;
        }
    }
    if (syncRecent >= 1)
    {
        float m6 = 60.0;
        if (m6 > combined) combined = m6;
    }
    if (combined > 100.0) combined = 100.0;

    // --- Metric 3: gravity honeypot ---
    // Surviving several perfect landings under artificially heavy, randomized
    // gravity is evidence no other metric here can produce - it isn't a
    // statistical pattern, it's the physical impossibility of a human
    // reacting correctly to a physics change their felt timing never saw
    // coming. Overrides everything else once earned.
    if (g_BH_HoneypotBonus[client] > 0) combined = 100.0;

    return RoundFloat(combined);
}

static float float_rand_bhop(float min, float max)
{
    float scale = GetURandomFloat();
    return min + scale * (max - min);
}
