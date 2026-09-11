// anticheat_osac.sp - detectors ported from OSAntiCheat (Pintuzoft)
// https://github.com/Pintuzoft/OSAntiCheat
//
// OSAntiCheat is a server-side statistical anti-cheat for CS2 whose
// thresholds were read off a 17k-demo archive of real matches, not
// guessed. This module reimplements its 5 detectors that apply cleanly to
// L4D2, all scoped (like the rest of this anti-cheat) to a survivor firing
// at a Special Infected. Each detector is a "logic breach" style check:
// the honest population never produces its signature, so a confirmed
// pattern is near-certain rather than merely suspicious.
//
//   BoneLock    - shots landing <=0.05 deg from head center (sub-quant)
//   SilentAim   - damage dealt while the view points >=10 deg off victim
//   TriggerBot  - shot fired <90ms after the crosshair crosses onto a target
//   KillBurst   - >=4 lethal Special headshots within 15 seconds
//   SpinBot     - sustained yaw rate impossible for a human wrist
//
// The module score is the MAX of the five sub-detectors.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

#define OSAC_HITGROUP_HEAD 1
#define OSAC_EYE_HEIGHT 64.0
#define OSAC_EVENT_EXPIRE 1200.0   // session-long window (matches OSAC's WindowSeconds)

// Must match ANGLE_HISTORY in anticheat_aim.sp - that module owns the
// per-tick angle ring buffer and hands it to OSAC_CheckTrigger below.
#define OSAC_ANGLE_HISTORY 8

// ------------------------------------------------------------------
// BoneLock: shots repeatedly landing within half an angle-quantization
// step of the target's head center. Humans cluster on a 1-2 deg motor
// hump; automated locks occupy a separate physical gap at <=0.05 deg.
#define BONELOCK_SPIKE_DEG        0.05
#define BONELOCK_MIN_SPIKES       3
#define BONELOCK_REACQUIRE_DEG    2.0   // aim must travel this far to reset the hold
#define BONELOCK_ONTARGET_DEG     5.0   // shot must be within this of the body first
#define BONELOCK_MIN_RANGE       64.0   // exclude point-blank (angular metrics degenerate)
#define BONELOCK_HISTORY 16
float g_BL_EventTime[MAXPLAYERS+1][BONELOCK_HISTORY];
int   g_BL_EventHead[MAXPLAYERS+1];
int   g_BL_EventCount[MAXPLAYERS+1];
float g_BL_LastLockYaw[MAXPLAYERS+1];
float g_BL_LastLockPitch[MAXPLAYERS+1];
bool  g_BL_Holding[MAXPLAYERS+1];

// ------------------------------------------------------------------
// SilentAim: a bullet registered damage while the shooter's
// server-visible view provably pointed >=10 deg away from the victim.
// Honest burst-openers peaked at 8.0 deg over 3486 samples.
#define SILENT_OFF_DEG           10.0
#define SILENT_MIN_HITS          3
#define SILENT_BURST_WINDOW      0.25   // shots within this are continuation, not first-of-burst
#define SILENT_HISTORY 16
float g_SA_EventTime[MAXPLAYERS+1][SILENT_HISTORY];
int   g_SA_EventHead[MAXPLAYERS+1];
int   g_SA_EventCount[MAXPLAYERS+1];
float g_SA_LastFire[MAXPLAYERS+1];

// ------------------------------------------------------------------
// TriggerBot: a shot fired within an implausibly short reaction time
// after the crosshair crossed onto an enemy, excluding pre-aimed holds.
#define TRIGGER_ONTARGET_DEG      3.0
#define TRIGGER_HUMAN_FLOOR_MS  90.0
#define TRIGGER_CERTAIN_MS      20.0
#define TRIGGER_PREFIRE_MOVE_DEG  5.0   // shooter must have swept at least this much into the target
#define TRIGGER_MIN_EVENTS        4
#define TRIGGER_WINDOW           60.0
#define TRIGGER_HISTORY 16
float g_TB_EventTime[MAXPLAYERS+1][TRIGGER_HISTORY];
int   g_TB_EventHead[MAXPLAYERS+1];
int   g_TB_EventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
// KillBurst: several lethal Special Infected headshots in quick
// succession. In OSAC this is gated on the victims being unspotted; in
// L4D2 Special Infected almost always appear suddenly (Hunter pounce,
// Smoker from behind) so a tight cluster of Special headshot kills is
// already the aimbot+wallhack signature.
#define KILLBURST_WINDOW        15.0
#define KILLBURST_MIN_VICTIMS   4
#define KILLBURST_HISTORY 16
float g_KB_KillTime[MAXPLAYERS+1][KILLBURST_HISTORY];
int   g_KB_KillVictim[MAXPLAYERS+1][KILLBURST_HISTORY];
int   g_KB_KillHead[MAXPLAYERS+1];
int   g_KB_KillCount[MAXPLAYERS+1];
int   g_KB_LastReported[MAXPLAYERS+1];

// ------------------------------------------------------------------
// SpinBot: a sustained yaw rate a human wrist cannot hold. A person can
// flick fast for one tick but cannot keep >1000 deg/s going unbroken.
#define SPIN_SUSPECT_RATE     1000.0   // deg/sec sustained
#define SPIN_CONTINUOUS_DEG    720.0   // two full unbroken rotations
#define SPIN_MIN_FRAMES          8
#define SPIN_HISTORY 16
float g_SB_ContinuousDeg[MAXPLAYERS+1];
int   g_SB_LastSign[MAXPLAYERS+1];
float g_SB_PrevYaw[MAXPLAYERS+1];
bool  g_SB_HasPrevYaw[MAXPLAYERS+1];
float g_SB_EventTime[MAXPLAYERS+1][SPIN_HISTORY];
int   g_SB_EventHead[MAXPLAYERS+1];
int   g_SB_EventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
static float OSAC_FAbs(float v) { return v < 0.0 ? -v : v; }
static float OSAC_FMin(float a, float b) { return a < b ? a : b; }

static float OSAC_NormalizeDeg(float d)
{
    while (d > 180.0) d -= 360.0;
    while (d < -180.0) d += 360.0;
    return d;
}

static bool OSAC_IsSpecialInfected(int ent)
{
    if (ent < 1 || ent > MaxClients || !IsClientInGame(ent)) return false;
    if (GetClientTeam(ent) != 3) return false;
    int zclass = GetEntProp(ent, Prop_Send, "m_zombieClass");
    return (zclass >= 1 && zclass <= 8);
}

// Angle (deg) between a client's view direction and the straight line to
// a world point, measured from eye height.
static float OSAC_AimErrorToPoint(const float eyePos[3], const float viewAngles[3], const float targetPos[3])
{
    float toTarget[3];
    MakeVectorFromPoints(eyePos, targetPos, toTarget);
    float wantAng[3];
    GetVectorAngles(toTarget, wantAng);

    float dYaw = OSAC_FAbs(OSAC_NormalizeDeg(viewAngles[1] - wantAng[1]));
    float dPitch = OSAC_FAbs(OSAC_NormalizeDeg(viewAngles[0] - wantAng[0]));
    return SquareRoot(dYaw*dYaw + dPitch*dPitch);
}

static void OSAC_GetEye(int client, float out[3])
{
    GetClientAbsOrigin(client, out);
    out[2] += OSAC_EYE_HEIGHT;
}

// Head center of a target: origin + eye-height offset (OSAC uses feet+64).
static void OSAC_GetHeadCenter(int ent, float out[3])
{
    GetClientAbsOrigin(ent, out);
    out[2] += OSAC_EYE_HEIGHT;
}

// ------------------------------------------------------------------
void OSAC_Init(int client)
{
    g_BL_EventHead[client] = 0;  g_BL_EventCount[client] = 0;  g_BL_Holding[client] = false;
    g_SA_EventHead[client] = 0;  g_SA_EventCount[client] = 0;  g_SA_LastFire[client] = 0.0;
    g_TB_EventHead[client] = 0;  g_TB_EventCount[client] = 0;
    g_KB_KillHead[client] = 0;   g_KB_KillCount[client] = 0;   g_KB_LastReported[client] = 0;
    g_SB_ContinuousDeg[client] = 0.0; g_SB_LastSign[client] = 0; g_SB_HasPrevYaw[client] = false;
    g_SB_EventHead[client] = 0;  g_SB_EventCount[client] = 0;
}

// ------------------------------------------------------------------
// Called every tick from OnPlayerRunCmd (survivor only).
void OSAC_RecordTick(int client, const float angles[3])
{
    // SpinBot: track sustained same-direction yaw rotation.
    if (!g_SB_HasPrevYaw[client])
    {
        g_SB_PrevYaw[client] = angles[1];
        g_SB_HasPrevYaw[client] = true;
        return;
    }

    float dYaw = OSAC_NormalizeDeg(angles[1] - g_SB_PrevYaw[client]);
    g_SB_PrevYaw[client] = angles[1];

    float tick = GetTickInterval();
    if (tick <= 0.0) return;
    float rate = OSAC_FAbs(dYaw) / tick; // deg/sec this tick

    int sign = dYaw > 0.0 ? 1 : (dYaw < 0.0 ? -1 : 0);

    if (rate >= SPIN_SUSPECT_RATE && sign != 0 && (g_SB_LastSign[client] == 0 || sign == g_SB_LastSign[client]))
    {
        g_SB_ContinuousDeg[client] += OSAC_FAbs(dYaw);
        g_SB_LastSign[client] = sign;

        if (g_SB_ContinuousDeg[client] >= SPIN_CONTINUOUS_DEG)
        {
            int idx = g_SB_EventHead[client];
            g_SB_EventTime[client][idx] = GetGameTime();
            g_SB_EventHead[client] = (idx + 1) % SPIN_HISTORY;
            if (g_SB_EventCount[client] < SPIN_HISTORY) g_SB_EventCount[client]++;
            g_SB_ContinuousDeg[client] = 0.0; // one confirmed spin = one event
            Correlation_ReportEvent(client, CORR_DET_OSAC_SPINBOT, 90);
        }
    }
    else
    {
        // Direction reversed or rate dropped below the floor - the run is broken.
        g_SB_ContinuousDeg[client] = 0.0;
        g_SB_LastSign[client] = 0;
    }
}

// ------------------------------------------------------------------
// Called from Hook_TraceAttack: a survivor's bullet hit `victim`.
// `firstOfBurst` distinguishes the opening shot from spray continuation.
void OSAC_RecordShot(int attacker, int victim, int hitgroup, const float attackerAngles[3])
{
    if (!OSAC_IsSpecialInfected(victim)) return;
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return;

    float now = GetGameTime();
    bool firstOfBurst = (now - g_SA_LastFire[attacker]) > SILENT_BURST_WINDOW;
    g_SA_LastFire[attacker] = now;

    float eye[3];
    OSAC_GetEye(attacker, eye);

    float victimBody[3];
    GetClientAbsOrigin(victim, victimBody);
    victimBody[2] += 32.0; // torso-ish reference point

    float victimHead[3];
    OSAC_GetHeadCenter(victim, victimHead);

    float range = GetVectorDistance(eye, victimHead);
    if (range < BONELOCK_MIN_RANGE) return; // point-blank: angular metrics degenerate

    float errBody = OSAC_AimErrorToPoint(eye, attackerAngles, victimBody);
    float errHead = OSAC_AimErrorToPoint(eye, attackerAngles, victimHead);

    // --- SilentAim: damage while view pointed far off the victim ---
    if (firstOfBurst && errBody >= SILENT_OFF_DEG)
    {
        int idx = g_SA_EventHead[attacker];
        g_SA_EventTime[attacker][idx] = now;
        g_SA_EventHead[attacker] = (idx + 1) % SILENT_HISTORY;
        if (g_SA_EventCount[attacker] < SILENT_HISTORY) g_SA_EventCount[attacker]++;

        // Severity: how far past the honest-population ceiling (8 deg) this hit was.
        Correlation_ReportEvent(attacker, CORR_DET_OSAC_SILENTAIM, RoundFloat(50.0 + (errBody - SILENT_OFF_DEG) * 2.0));
    }

    // --- BoneLock: repeated sub-quantization hits on head center ---
    // Only meaningful when the shot was actually on the body to begin with.
    if (errBody <= BONELOCK_ONTARGET_DEG && hitgroup == OSAC_HITGROUP_HEAD)
    {
        if (errHead <= BONELOCK_SPIKE_DEG)
        {
            // Has the aim moved off the previous lock since we last counted?
            bool reacquired = true;
            if (g_BL_Holding[attacker])
            {
                float moved = SquareRoot(
                    Pow(OSAC_NormalizeDeg(attackerAngles[1] - g_BL_LastLockYaw[attacker]), 2.0) +
                    Pow(OSAC_NormalizeDeg(attackerAngles[0] - g_BL_LastLockPitch[attacker]), 2.0));
                reacquired = (moved >= BONELOCK_REACQUIRE_DEG);
            }

            if (reacquired)
            {
                int idx = g_BL_EventHead[attacker];
                g_BL_EventTime[attacker][idx] = now;
                g_BL_EventHead[attacker] = (idx + 1) % BONELOCK_HISTORY;
                if (g_BL_EventCount[attacker] < BONELOCK_HISTORY) g_BL_EventCount[attacker]++;

                // Sub-quantization hit - the strongest single-shot evidence
                // this whole plugin can produce. Fixed high severity.
                Correlation_ReportEvent(attacker, CORR_DET_OSAC_BONELOCK, 95);
            }
            g_BL_Holding[attacker] = true;
            g_BL_LastLockYaw[attacker] = attackerAngles[1];
            g_BL_LastLockPitch[attacker] = attackerAngles[0];
        }
        else
        {
            g_BL_Holding[attacker] = false;
        }
    }
}

// ------------------------------------------------------------------
// Called from OnPlayerRunCmd when the survivor is pressing IN_ATTACK,
// with the per-tick angle history so we can walk back to the crossing.
void OSAC_CheckTrigger(int client, const float angleYaw[OSAC_ANGLE_HISTORY], const float anglePitch[OSAC_ANGLE_HISTORY], const float angleTime[OSAC_ANGLE_HISTORY], int histHead, int histSize, int histCount)
{
    if (histCount < 4) return;

    // Nearest Special Infected right now.
    float eye[3];
    OSAC_GetEye(client, eye);
    float viewAngles[3];
    GetClientEyeAngles(client, viewAngles);

    int nearest = -1;
    float nearestErr = 99999.0;
    // Shared per-frame Special Infected cache (built in OnPlayerRunCmd).
    for (int c = 0; c < g_SpecialCacheCount; c++)
    {
        int i = g_SpecialCache[c];
        if (!IsClientInGame(i)) continue;
        float body[3];
        GetClientAbsOrigin(i, body);
        body[2] += 32.0;
        float err = OSAC_AimErrorToPoint(eye, viewAngles, body);
        if (err < nearestErr) { nearestErr = err; nearest = i; }
    }
    if (nearest == -1 || nearestErr > TRIGGER_ONTARGET_DEG) return; // not on target

    // Walk back through the angle history: find the tick where the aim
    // was NOT yet on target (the "crossing"). Reaction = now - crossing.
    float now = GetGameTime();
    float nb[3];
    GetClientAbsOrigin(nearest, nb);
    nb[2] += 32.0;

    float crossingTime = -1.0;
    float sweptDeg = 0.0;
    int checks = histCount < histSize ? histCount : histSize;
    for (int k = 1; k <= checks; k++)
    {
        int idx = (histHead - 1 - k + histSize) % histSize;
        float va[3];
        va[0] = anglePitch[idx];
        va[1] = angleYaw[idx];
        va[2] = 0.0;
        float err = OSAC_AimErrorToPoint(eye, va, nb);

        // total angular sweep between this old sample and now
        float sweep = SquareRoot(
            Pow(OSAC_NormalizeDeg(viewAngles[1] - va[1]), 2.0) +
            Pow(OSAC_NormalizeDeg(viewAngles[0] - va[0]), 2.0));
        if (sweep > sweptDeg) sweptDeg = sweep;

        if (err > TRIGGER_ONTARGET_DEG)
        {
            crossingTime = angleTime[idx];
            break;
        }
    }

    if (crossingTime < 0.0) return;       // was on target the whole lookback = pre-aimed hold, not triggerbot
    if (sweptDeg < TRIGGER_PREFIRE_MOVE_DEG) return; // enemy walked into a static aim, not a shooter-driven flick

    float reactionMs = (now - crossingTime) * 1000.0;
    if (reactionMs >= TRIGGER_HUMAN_FLOOR_MS) return; // human-plausible reaction

    int idx = g_TB_EventHead[client];
    g_TB_EventTime[client][idx] = now;
    g_TB_EventHead[client] = (idx + 1) % TRIGGER_HISTORY;
    if (g_TB_EventCount[client] < TRIGGER_HISTORY) g_TB_EventCount[client]++;

    // Severity: how far under the human reaction floor this shot was.
    Correlation_ReportEvent(client, CORR_DET_OSAC_TRIGGER, RoundFloat(50.0 + (TRIGGER_HUMAN_FLOOR_MS - reactionMs)));
}

// ------------------------------------------------------------------
// Called from a player_death event: `attacker` killed `victim` with a headshot.
void OSAC_NoteKill(int attacker, int victim, bool headshot)
{
    if (!headshot) return;
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return;
    if (!OSAC_IsSpecialInfected(victim)) return;

    float now = GetGameTime();

    // Purge kills older than the window, then check for a duplicate victim.
    int idx = g_KB_KillHead[attacker];
    g_KB_KillTime[attacker][idx] = now;
    g_KB_KillVictim[attacker][idx] = victim;
    g_KB_KillHead[attacker] = (idx + 1) % KILLBURST_HISTORY;
    if (g_KB_KillCount[attacker] < KILLBURST_HISTORY) g_KB_KillCount[attacker]++;

    // Only report to the correlation engine once the burst pattern itself
    // is confirmed (>=KILLBURST_MIN_VICTIMS distinct in the window) - a
    // single legitimate headshot kill is not raw evidence on its own and
    // would just add noise to every good player's correlation buffer.
    if (OSAC_KillBurstScore(attacker) > 0)
    {
        Correlation_ReportEvent(attacker, CORR_DET_OSAC_KILLBURST, 80);
    }
}

// ------------------------------------------------------------------
// All the per-detector event ring buffers are sized 16, so one fixed
// signature covers them all.
static int OSAC_CountRecent(const float times[16], int total, float window)
{
    float now = GetGameTime();
    int n = 0;
    for (int i = 0; i < total; i++)
        if (now - times[i] <= window) n++;
    return n;
}

static int OSAC_BoneLockScore(int client)
{
    int n = OSAC_CountRecent(g_BL_EventTime[client], g_BL_EventCount[client], OSAC_EVENT_EXPIRE);
    if (n < BONELOCK_MIN_SPIKES) return 0;
    return RoundFloat(OSAC_FMin(80.0 + float(n - BONELOCK_MIN_SPIKES) * 10.0, 100.0));
}

static int OSAC_SilentAimScore(int client)
{
    int n = OSAC_CountRecent(g_SA_EventTime[client], g_SA_EventCount[client], OSAC_EVENT_EXPIRE);
    if (n < SILENT_MIN_HITS) return 0;
    return RoundFloat(OSAC_FMin(80.0 + float(n - SILENT_MIN_HITS) * 10.0, 100.0));
}

static int OSAC_TriggerScore(int client)
{
    int n = OSAC_CountRecent(g_TB_EventTime[client], g_TB_EventCount[client], TRIGGER_WINDOW);
    if (n < TRIGGER_MIN_EVENTS) return 0;
    return RoundFloat(OSAC_FMin(70.0 + float(n - TRIGGER_MIN_EVENTS) * 10.0, 100.0));
}

static int OSAC_KillBurstScore(int client)
{
    // Distinct victims within the 15s window.
    float now = GetGameTime();
    int total = g_KB_KillCount[client];
    int distinct = 0;
    int seen[KILLBURST_HISTORY];
    for (int i = 0; i < total; i++)
    {
        if (now - g_KB_KillTime[client][i] > KILLBURST_WINDOW) continue;
        int v = g_KB_KillVictim[client][i];
        bool dup = false;
        for (int j = 0; j < distinct; j++) if (seen[j] == v) { dup = true; break; }
        if (!dup) { seen[distinct] = v; distinct++; }
    }

    if (distinct < KILLBURST_MIN_VICTIMS) return 0;
    return RoundFloat(OSAC_FMin(90.0 + float(distinct - KILLBURST_MIN_VICTIMS) * 5.0, 100.0));
}

static int OSAC_SpinBotScore(int client)
{
    int n = OSAC_CountRecent(g_SB_EventTime[client], g_SB_EventCount[client], OSAC_EVENT_EXPIRE);
    if (n < 2) return 0; // single occurrence = fluke
    return RoundFloat(OSAC_FMin(85.0 + float(n - 2) * 7.0, 100.0));
}

int OSAC_GetScore(int client)
{
    int best = OSAC_BoneLockScore(client);
    int s = OSAC_SilentAimScore(client); if (s > best) best = s;
    s = OSAC_TriggerScore(client);       if (s > best) best = s;
    s = OSAC_KillBurstScore(client);     if (s > best) best = s;
    s = OSAC_SpinBotScore(client);       if (s > best) best = s;
    return best;
}
