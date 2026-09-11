// anticheat_aim.sp - Aimbot detector for L4D2 Anti-Cheat, scoped to
// Special Infected headshots.
//
// Why this design: the server can never see the player's "real" mouse
// intent - it only ever sees the final view angle the client sends, so
// comparing crosshair-vs-target position cannot distinguish an aimbot that
// moves the visible crosshair from a genuinely precise human (both produce
// identical server-side data). What the server CAN observe is how the
// player's aim angle *changed* between ticks, and how consistent their
// accuracy is over time - both are things no human mouse hand replicates
// perfectly, aimbot or not.
//
// So this detector tracks view-angle samples every tick (like a generic
// snap/consistency aim detector), but only turns that into suspicion at
// the moment of a HEADSHOT on a SPECIAL INFECTED - the specific pattern
// requested: sudden snap immediately before/at a headshot, or unnaturally
// tight aim consistency sustained across several such headshots.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

#define HITGROUP_HEAD 1

// Per-tick view angle history, used to measure the angular snap that
// preceded a qualifying headshot.
#define ANGLE_HISTORY 8
float g_AngleYaw[MAXPLAYERS+1][ANGLE_HISTORY];
float g_AnglePitch[MAXPLAYERS+1][ANGLE_HISTORY];
float g_AngleTime[MAXPLAYERS+1][ANGLE_HISTORY];
int   g_AngleHead[MAXPLAYERS+1];
int   g_AngleCount[MAXPLAYERS+1];

// Qualifying headshot events (on Special Infected only), used to judge
// sustained statistical consistency across several shots.
#define EVENT_HISTORY 32
#define EVENT_MIN_SAMPLES 5
float g_EventSnapDeg[MAXPLAYERS+1][EVENT_HISTORY]; // angular jump in the tick of the shot
int   g_EventHead[MAXPLAYERS+1];
int   g_EventCount[MAXPLAYERS+1];

// A snap must exceed this to be recorded as a candidate event. Real-world
// testing showed this cheat corrects gradually (small per-tick jumps of
// ~2-7 degrees), not a single large flick, so the threshold is low - the
// CONSISTENCY_MAX_STDDEV_DEG filter below is what actually separates a
// script's repeatable correction from a human's naturally erratic
// micro-adjustments while tracking a moving target.
#define SNAP_THRESHOLD_DEG 2.0
// For the "consistency" path: an unnaturally tight, repeatable snap size
// across many headshots (low spread) is what a human can't replicate.
#define CONSISTENCY_MAX_STDDEV_DEG 4.0

// Close-quarters combat produces legitimately sharp aim corrections (the
// target is right on top of you) - ignore shots under this distance so
// melee-range chaos doesn't get counted as evidence.
#define AIM_MIN_DISTANCE 200.0

// Each recorded event "expires" after this long - a player who cheated
// once and then plays clean shouldn't stay flagged forever.
#define EVENT_EXPIRE_SECONDS 600.0
float g_EventTime[MAXPLAYERS+1][EVENT_HISTORY];

// ------------------------------------------------------------------
// "Angle Repeat" path (technique credited to the StAC-tf2 anti-cheat):
// a human aiming - even snapping onto a target in a panic - always has
// some residual mouse drift immediately before and after the snap. A
// script that jumps straight to the target and then holds perfectly still
// produces an isolated snap: near-zero noise, one large jump, near-zero
// noise again. This is harder to fake than a raw snap-size threshold,
// because a human deliberately adding "noise" around their shots to evade
// this either ruins their aim or reproduces the same detectable pattern.
//
// Runs every tick while the attack button is held, independent of the
// headshot/Special-Infected gating above - it has its own noise/snap
// thresholds that already reject normal tracking on their own.
#define REPEAT_NOISE_DEG 0.5   // below this counts as "held still"
#define REPEAT_SNAP_DEG  10.0  // above this counts as "a sudden jump"
#define REPEAT_MIN_SAMPLES 5
#define REPEAT_EVENT_HISTORY 32
float g_RepeatEventDeg[MAXPLAYERS+1][REPEAT_EVENT_HISTORY];
float g_RepeatEventTime[MAXPLAYERS+1][REPEAT_EVENT_HISTORY];
int   g_RepeatEventHead[MAXPLAYERS+1];
int   g_RepeatEventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
// "Cmdnum Spike" path (technique credited to StAC-tf2): some cheats fire
// a "perfect shot" by jumping the client's command_number ahead several
// values on the exact usercmd that pulls the trigger. This does not move
// the crosshair at all - it is a client-side trick that skips the bullet
// spread/recoil pattern the server would otherwise apply for that shot.
// It's a completely different signal from the angle-based paths above:
// no aim data is involved at all, only the sequence integrity of the
// commands the client is sending.
//
// A legitimate client's cmdnum always increases by exactly 1 each tick
// (barring choke, which the lag-check below already filters out). A jump
// of many values on the very tick a shot is fired is not something normal
// network jitter produces.
#define CMDSPIKE_THRESHOLD_SHOT   12   // jump this big on a firing tick = spike
#define CMDSPIKE_THRESHOLD_IDLE   32   // bigger allowance off a firing tick (spawn/loading jitter etc.)
#define CMDSPIKE_MIN_SAMPLES 3
#define CMDSPIKE_EVENT_HISTORY 32
int   g_CmdNumPrev[MAXPLAYERS+1];
int   g_CmdNumPrevPrev[MAXPLAYERS+1];
bool  g_CmdNumHasPrev[MAXPLAYERS+1];
float g_CmdSpikeEventTime[MAXPLAYERS+1][CMDSPIKE_EVENT_HISTORY];
int   g_CmdSpikeEventHead[MAXPLAYERS+1];
int   g_CmdSpikeEventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
// "Aimlock" path (technique credited to Little-Anti-Cheat / Lilac): rather
// than looking at a single snap, this watches the angle *converge* onto a
// Special Infected over several consecutive ticks. Legitimate tracking
// closes the gap gradually and proportionally - a human correcting their
// aim moves less as they get closer to on-target, but the ratio from tick
// to tick is noisy. A script that has locked onto the target collapses
// the remaining angle almost immediately (this tick's leftover angle to
// the target is a small fraction of the previous tick's) while ALSO still
// producing a big raw angle jump to get there - a human closing in that
// fast doesn't have a leftover angle worth collapsing in the first place.
// Sustaining that exact shape for a stretch of ticks is the tell.
#define AIMLOCK_CONVERGE_RATIO   0.10  // remaining angle-to-target drops to <=10% of previous sample's
#define AIMLOCK_MIN_JUMP_DEG     20.0  // ...while still moving at least this much between samples
// This check is sampled every 2nd game tick (perf), so each "hold" unit is
// ~2 ticks. 4 => ~8 ticks => ~0.25s sustained, still well short of any
// human tracking a moving target that smoothly.
#define AIMLOCK_HOLD_TICKS       4
#define AIMLOCK_MIN_SAMPLES 2
#define AIMLOCK_EVENT_HISTORY 16
int   g_AimlockHoldTicks[MAXPLAYERS+1];
float g_AimlockPrevDeltaDeg[MAXPLAYERS+1]; // angle-to-nearest-target left over on the previous tick
float g_AimlockEventTime[MAXPLAYERS+1][AIMLOCK_EVENT_HISTORY];
int   g_AimlockEventHead[MAXPLAYERS+1];
int   g_AimlockEventCount[MAXPLAYERS+1];

void Aim_Init(int client)
{
    g_AngleHead[client] = 0;
    g_AngleCount[client] = 0;
    g_EventHead[client] = 0;
    g_EventCount[client] = 0;
    g_RepeatEventHead[client] = 0;
    g_RepeatEventCount[client] = 0;
    g_CmdNumHasPrev[client] = false;
    g_CmdSpikeEventHead[client] = 0;
    g_CmdSpikeEventCount[client] = 0;
    g_AimlockHoldTicks[client] = 0;
    g_AimlockEventHead[client] = 0;
    g_AimlockEventCount[client] = 0;
    g_AimlockPrevDeltaDeg[client] = -1.0;
}

// ------------------------------------------------------------------
// The CHEAP part of the per-tick aim work: keep the angle-history ring
// buffer and run the checks that are pure arithmetic on values already in
// hand (angle-repeat, cmdnum-spike). No per-client scans here.
void Aim_RecordAngleCheap(int client, const float angles[3], int buttons, int cmdnum)
{
    int idx = g_AngleHead[client];
    g_AngleYaw[client][idx]   = angles[0];
    g_AnglePitch[client][idx] = angles[1];
    g_AngleTime[client][idx]  = GetGameTime();
    g_AngleHead[client] = (idx + 1) % ANGLE_HISTORY;
    if (g_AngleCount[client] < ANGLE_HISTORY) g_AngleCount[client]++;

    if (buttons & IN_ATTACK) Aim_CheckAngleRepeat(client);
    Aim_CheckCmdnumSpike(client, cmdnum, (buttons & IN_ATTACK) != 0);
}

// ------------------------------------------------------------------
// "Cmdnum Spike" check (see comment near CMDSPIKE_* constants above).
// Compares this tick's cmdnum against the previous one; a jump far bigger
// than 1 that lands on a firing tick is the signature of a no-spread/
// perfect-shot cheat skipping ahead in the command sequence.
static void Aim_CheckCmdnumSpike(int client, int cmdnum, bool firing)
{
    if (!g_CmdNumHasPrev[client])
    {
        g_CmdNumPrevPrev[client] = cmdnum;
        g_CmdNumPrev[client] = cmdnum;
        g_CmdNumHasPrev[client] = true;
        return;
    }

    int spike = g_CmdNumPrev[client] - g_CmdNumPrevPrev[client];
    int threshold = firing ? CMDSPIKE_THRESHOLD_SHOT : CMDSPIKE_THRESHOLD_IDLE;

    if (spike >= threshold || spike <= -threshold)
    {
        int idx = g_CmdSpikeEventHead[client];
        g_CmdSpikeEventTime[client][idx] = GetGameTime();
        g_CmdSpikeEventHead[client] = (idx + 1) % CMDSPIKE_EVENT_HISTORY;
        if (g_CmdSpikeEventCount[client] < CMDSPIKE_EVENT_HISTORY) g_CmdSpikeEventCount[client]++;
    }

    g_CmdNumPrevPrev[client] = g_CmdNumPrev[client];
    g_CmdNumPrev[client] = cmdnum;
}

static float NormalizeAngleDiff(float diff)
{
    if (diff > 180.0) return 360.0 - diff;
    return diff;
}

// ------------------------------------------------------------------
// "Angle Repeat" check (see comment near REPEAT_* constants above).
// Looks at the 4 deltas across the last 5 recorded ticks and flags an
// isolated snap: noise, JUMP, noise, noise (or the jump one slot earlier).
static void Aim_CheckAngleRepeat(int client)
{
    if (g_AngleCount[client] < 5) return;

    int head = g_AngleHead[client];
    float d[4];
    for (int i = 0; i < 4; i++)
    {
        int idxA = (head - 1 - i + ANGLE_HISTORY) % ANGLE_HISTORY;
        int idxB = (head - 2 - i + ANGLE_HISTORY) % ANGLE_HISTORY;

        float dYaw = FAbs(g_AngleYaw[client][idxA] - g_AngleYaw[client][idxB]);
        float dPitch = FAbs(g_AnglePitch[client][idxA] - g_AnglePitch[client][idxB]);
        dYaw = NormalizeAngleDiff(dYaw);
        // d[0] is the most recent delta, d[3] the oldest of the 4.
        d[i] = SquareRoot(dYaw*dYaw + dPitch*dPitch);
    }

    // d[3],d[2],d[1],d[0] in chronological order. Match either "jump in the
    // middle-early slot" or "jump in the middle-late slot", both flanked by
    // near-zero noise - a snap that arrives out of nowhere and is followed
    // by dead stillness, exactly what a script's target-lock produces and a
    // human's continuous mouse drift does not.
    bool isNoise0 = d[3] > 0.0 && d[3] < REPEAT_NOISE_DEG;
    bool isNoise2 = d[1] > 0.0 && d[1] < REPEAT_NOISE_DEG;
    bool isNoise3 = d[0] > 0.0 && d[0] < REPEAT_NOISE_DEG;
    bool isNoise1 = d[2] > 0.0 && d[2] < REPEAT_NOISE_DEG;

    float jumpDeg = 0.0;
    if (isNoise0 && d[2] > REPEAT_SNAP_DEG && isNoise2 && isNoise3)
    {
        jumpDeg = d[2];
    }
    else if (isNoise0 && isNoise1 && d[1] > REPEAT_SNAP_DEG && isNoise3)
    {
        jumpDeg = d[1];
    }
    else
    {
        return;
    }

    int idx = g_RepeatEventHead[client];
    g_RepeatEventDeg[client][idx] = jumpDeg;
    g_RepeatEventTime[client][idx] = GetGameTime();
    g_RepeatEventHead[client] = (idx + 1) % REPEAT_EVENT_HISTORY;
    if (g_RepeatEventCount[client] < REPEAT_EVENT_HISTORY) g_RepeatEventCount[client]++;
}

// ------------------------------------------------------------------
// Angle (in degrees) between the client's current view direction and the
// straight line to a target's eye position - i.e. how far off-target the
// crosshair currently is. Returns -1.0 if there is no valid nearest
// Special Infected in front of the client to measure against.
static float Aim_GetAngleToNearestTarget(int client, const float viewAngles[3])
{
    float eyePos[3];
    GetClientEyePosition(client, eyePos);

    float bestDist = 99999999.0;
    float bestDeg = -1.0;

    // Iterate the shared per-frame Special Infected cache (built once in
    // OnPlayerRunCmd) instead of scanning all client slots here.
    for (int c = 0; c < g_SpecialCacheCount; c++)
    {
        int i = g_SpecialCache[c];
        if (!IsClientInGame(i)) continue;

        float targetPos[3];
        GetClientEyePosition(i, targetPos);

        float dist = GetVectorDistance(eyePos, targetPos);
        if (dist >= bestDist) continue;
        // Same close-quarters exemption used elsewhere - melee range
        // produces legitimately erratic tracking.
        if (dist < AIM_MIN_DISTANCE) continue;

        float toTarget[3];
        MakeVectorFromPoints(eyePos, targetPos, toTarget);
        float wanted[3];
        GetVectorAngles(toTarget, wanted);

        float dYaw = FAbs(viewAngles[1] - wanted[1]);
        dYaw = NormalizeAngleDiff(dYaw);
        float dPitch = FAbs(viewAngles[0] - wanted[0]);
        float deg = SquareRoot(dYaw*dYaw + dPitch*dPitch);

        bestDist = dist;
        bestDeg = deg;
    }

    return bestDeg;
}

// Throttled entry point (called every 2nd tick from OnPlayerRunCmd).
void Aim_CheckAimlockThrottled(int client, const float angles[3])
{
    Aim_CheckAimlock(client, angles);
}

// TriggerBot entry point - reuses this module's angle-history ring buffer
// (no separate buffer in the OSAC module). Called every 2nd tick while
// IN_ATTACK is held.
void Aim_RunTriggerCheck(int client)
{
    OSAC_CheckTrigger(client, g_AngleYaw[client], g_AnglePitch[client],
                      g_AngleTime[client], g_AngleHead[client],
                      ANGLE_HISTORY, g_AngleCount[client]);
}

// ------------------------------------------------------------------
// "Aimlock" check (see comment near AIMLOCK_* constants above). Compares
// how much leftover angle-to-target remains this tick versus last tick.
static void Aim_CheckAimlock(int client, const float angles[3])
{
    float deltaDeg = Aim_GetAngleToNearestTarget(client, angles);

    if (deltaDeg < 0.0)
    {
        // No valid target in range right now - can't judge convergence.
        g_AimlockPrevDeltaDeg[client] = -1.0;
        g_AimlockHoldTicks[client] = 0;
        return;
    }

    float prevDeg = g_AimlockPrevDeltaDeg[client];
    g_AimlockPrevDeltaDeg[client] = deltaDeg;

    if (prevDeg < 0.0) return; // first sample since acquiring a target, nothing to compare yet

    bool converging = (prevDeg > 1.0) && (deltaDeg <= prevDeg * AIMLOCK_CONVERGE_RATIO);
    bool bigJump = FAbs(prevDeg - deltaDeg) >= AIMLOCK_MIN_JUMP_DEG;

    if (converging && bigJump)
    {
        g_AimlockHoldTicks[client]++;
        if (g_AimlockHoldTicks[client] >= AIMLOCK_HOLD_TICKS)
        {
            int idx = g_AimlockEventHead[client];
            g_AimlockEventTime[client][idx] = GetGameTime();
            g_AimlockEventHead[client] = (idx + 1) % AIMLOCK_EVENT_HISTORY;
            if (g_AimlockEventCount[client] < AIMLOCK_EVENT_HISTORY) g_AimlockEventCount[client]++;
            // Reset the hold so a single sustained lock doesn't count as
            // dozens of events - each confirmed lock-on is one event.
            g_AimlockHoldTicks[client] = 0;
        }
    }
    else
    {
        g_AimlockHoldTicks[client] = 0;
    }
}

// ------------------------------------------------------------------
static bool IsSpecialInfected(int victim)
{
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim)) return false;
    if (GetClientTeam(victim) != 3) return false; // 3 = Infected team

    int zclass = GetEntProp(victim, Prop_Send, "m_zombieClass");
    return (zclass >= 1 && zclass <= 8); // Smoker..Tank (7 = Witch included)
}

static float FAbs(float v) { return v < 0.0 ? -v : v; }

// ------------------------------------------------------------------
// Called from Hook_TraceAttack. Only headshots on Special Infected reach
// here (filtered by the caller isn't required, but we double check).
void Aim_RecordShot(int attacker, int victim, int hitgroup)
{
    if (hitgroup != HITGROUP_HEAD) return;
    if (!IsSpecialInfected(victim)) return;
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return;

    // Close-quarters shots produce legitimately sharp corrections - skip them.
    float posAttacker[3], posVictim[3];
    GetClientAbsOrigin(attacker, posAttacker);
    GetClientAbsOrigin(victim, posVictim);
    if (GetVectorDistance(posAttacker, posVictim) < AIM_MIN_DISTANCE) return;

    int count = g_AngleCount[attacker];
    if (count < 2) return;

    // Angular jump between the two most recent recorded ticks - the snap
    // that happened right at/just before this shot landed.
    int head = g_AngleHead[attacker];
    int idxCurr = (head - 1 + ANGLE_HISTORY) % ANGLE_HISTORY;
    int idxPrev = (head - 2 + ANGLE_HISTORY) % ANGLE_HISTORY;

    float dt = g_AngleTime[attacker][idxCurr] - g_AngleTime[attacker][idxPrev];
    if (dt <= 0.0 || dt > GetTickInterval() * 2.0) return; // not consecutive ticks

    float dYaw = FAbs(g_AngleYaw[attacker][idxCurr] - g_AngleYaw[attacker][idxPrev]);
    float dPitch = FAbs(g_AnglePitch[attacker][idxCurr] - g_AnglePitch[attacker][idxPrev]);
    if (dYaw > 180.0) dYaw = 360.0 - dYaw;
    float snapDeg = SquareRoot(dYaw*dYaw + dPitch*dPitch);

    if (snapDeg < SNAP_THRESHOLD_DEG) return; // no sudden flick, nothing to record

    int idx = g_EventHead[attacker];
    g_EventSnapDeg[attacker][idx] = snapDeg;
    g_EventTime[attacker][idx] = GetGameTime();
    g_EventHead[attacker] = (idx + 1) % EVENT_HISTORY;
    if (g_EventCount[attacker] < EVENT_HISTORY) g_EventCount[attacker]++;
}

static float FMin(float a, float b) { return a < b ? a : b; }
static float FMax(float a, float b) { return a > b ? a : b; }

// Path 1: snap immediately before a headshot on a Special Infected,
// judged for sustained statistical consistency across several shots.
static int Aim_GetHeadshotScore(int client)
{
    int total = g_EventCount[client];
    if (total < EVENT_MIN_SAMPLES) return 0;

    // Only count events that haven't expired - a player who cheated once
    // and has since played clean for a while shouldn't stay flagged forever.
    float now = GetGameTime();
    float sum = 0.0;
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_EventTime[client][i] > EVENT_EXPIRE_SECONDS) continue;
        sum += g_EventSnapDeg[client][i];
        count++;
    }
    if (count < EVENT_MIN_SAMPLES) return 0;
    float avg = sum / float(count);

    float varSum = 0.0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_EventTime[client][i] > EVENT_EXPIRE_SECONDS) continue;
        float d = g_EventSnapDeg[client][i] - avg;
        varSum += d * d;
    }
    float stddev = SquareRoot(varSum / float(count));

    // A human occasionally snap-flicks onto a headshot in a panic, but the
    // size of that flick varies wildly shot to shot. A script that
    // auto-snaps to the head produces a tight, repeatable jump size
    // instead - same target distance, same correction, over and over.
    float score = 0.0;
    score += FMin(float(count - EVENT_MIN_SAMPLES) * 8.0, 50.0);
    if (stddev < CONSISTENCY_MAX_STDDEV_DEG)
    {
        score += FMin((CONSISTENCY_MAX_STDDEV_DEG - stddev) * 12.0, 50.0);
    }

    if (score > 100.0) score = 100.0;
    return RoundFloat(score);
}

// Path 2: "Angle Repeat" - isolated snaps while firing, independent of
// hitgroup/target (see Aim_CheckAngleRepeat comment above). Sustained
// repetition of this exact shape is what separates a script from a human
// panic-flick, which is a one-off, not a pattern.
static int Aim_GetAngleRepeatScore(int client)
{
    int total = g_RepeatEventCount[client];
    if (total < REPEAT_MIN_SAMPLES) return 0;

    float now = GetGameTime();
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_RepeatEventTime[client][i] <= EVENT_EXPIRE_SECONDS) count++;
    }
    if (count < REPEAT_MIN_SAMPLES) return 0;

    float score = FMin(float(count - REPEAT_MIN_SAMPLES) * 10.0, 100.0);
    return RoundFloat(score);
}

// Path 3: "Cmdnum Spike" - command_number jumps far ahead on a firing
// tick, the signature of a no-spread/perfect-shot cheat. Independent of
// view angles entirely, so it catches cheats that never touch the mouse.
static int Aim_GetCmdSpikeScore(int client)
{
    int total = g_CmdSpikeEventCount[client];
    if (total < CMDSPIKE_MIN_SAMPLES) return 0;

    float now = GetGameTime();
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_CmdSpikeEventTime[client][i] <= EVENT_EXPIRE_SECONDS) count++;
    }
    if (count < CMDSPIKE_MIN_SAMPLES) return 0;

    float score = FMin(float(count - CMDSPIKE_MIN_SAMPLES) * 15.0 + 40.0, 100.0);
    return RoundFloat(score);
}

// Path 4: "Aimlock" - sustained angle convergence onto a Special Infected,
// independent of whether a shot ever landed. Catches lock-on/silent-aim
// cheats that track a target smoothly rather than snapping onto it once.
static int Aim_GetAimlockScore(int client)
{
    int total = g_AimlockEventCount[client];
    if (total < AIMLOCK_MIN_SAMPLES) return 0;

    float now = GetGameTime();
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_AimlockEventTime[client][i] <= EVENT_EXPIRE_SECONDS) count++;
    }
    if (count < AIMLOCK_MIN_SAMPLES) return 0;

    float score = FMin(float(count - AIMLOCK_MIN_SAMPLES) * 20.0 + 50.0, 100.0);
    return RoundFloat(score);
}

int Aim_GetScore(int client)
{
    float best = FMax(float(Aim_GetHeadshotScore(client)), float(Aim_GetAngleRepeatScore(client)));
    best = FMax(best, float(Aim_GetCmdSpikeScore(client)));
    best = FMax(best, float(Aim_GetAimlockScore(client)));
    return RoundFloat(best);
}
