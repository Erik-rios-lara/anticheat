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
        }
        g_BH_PrevYaw[client] = angles[1];
        g_BH_HasPrevYaw[client] = true;
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
