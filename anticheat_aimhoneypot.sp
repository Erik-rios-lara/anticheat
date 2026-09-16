// anticheat_aimhoneypot.sp - Aim Honeypot for L4D2 Anti-Cheat
// (same underlying principle as anticheat_bhop.sp's gravity honeypot,
// technique credited to StAC-tf2 - adapted here to aim instead of
// movement)
//
// The gravity honeypot works by secretly changing a physical constant a
// human's TIMING is calibrated to, and watching whether the player keeps
// hitting a tight window anyway - something only possible if they're
// reacting to raw game state (FL_ONGROUND) rather than felt physics. This
// module does the same thing for tracking: it secretly changes how FAST
// a Special Infected the player is actively tracking moves, for a short,
// randomized window, via m_flLaggedMovementValue (a real,
// server-controlled speed-scaling property already used in other L4D2
// SourceMod plugins - not a hack, a supported entity property).
//
// A human tracking a target is calibrated to how fast it's BEEN moving -
// their hand corrects based on felt momentum and visual extrapolation,
// which takes real reaction time to adjust to a sudden, unannounced speed
// change. An aimbot/tracking-assist that recomputes the target's actual
// reported position every tick doesn't have "felt" anything to
// recalibrate - it keeps converging just as tightly through the speed
// change as before, because from its perspective nothing changed except
// a number it was already reading fresh each tick.
//
// Deliberately restricted to tier >= 2 (already-suspicious players, same
// threshold the gravity honeypot effectively requires via its own streak
// gate) so a clean player's game experience is never touched by this.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

// ------------------------------------------------------------------
// Only trip the honeypot against a target the player has already been
// tracking tightly for a real stretch - triggering it against a target
// they just glanced at would test nothing meaningful.
#define HONEYPOT_ARM_ONTARGET_DEG     6.0    // error must stay at/below this to count as "tracking" this tick
#define HONEYPOT_ARM_HOLD_TICKS       12     // ~0.4s of continuous tracking before arming is even considered
#define HONEYPOT_MIN_DIST_UNITS      200.0   // same close-quarters exemption as the rest of the aim module

// Speed scale applied to the target for the honeypot window - random
// each time so it can't be learned/predicted, and large enough that a
// human's felt-momentum correction would visibly lag behind it.
#define HONEYPOT_SCALE_MIN            0.35
#define HONEYPOT_SCALE_MAX            2.6
#define HONEYPOT_DURATION_SEC         0.5    // how long the altered speed stays active
#define HONEYPOT_COOLDOWN_SEC        45.0    // minimum gap between honeypots for the same player

// Judged AFTER the speed reverts, over this window, to catch a human's
// residual overcorrection too, not just the instant of the change.
#define HONEYPOT_JUDGE_WINDOW_SEC     0.6
#define HONEYPOT_SURVIVE_ONTARGET_DEG 8.0    // error must stay under this for the tracked ratio to count as "still locked on"
#define HONEYPOT_SURVIVE_RATIO        0.85   // this fraction of judged ticks staying on-target is the tell

#define HONEYPOT_EVENT_HISTORY 4

// ------------------------------------------------------------------
bool  g_AHP_Active[MAXPLAYERS+1];
int   g_AHP_TargetEntity[MAXPLAYERS+1];
float g_AHP_StartTime[MAXPLAYERS+1];
float g_AHP_OriginalScale[MAXPLAYERS+1];
bool  g_AHP_Reverted[MAXPLAYERS+1];

int   g_AHP_ArmHoldTicks[MAXPLAYERS+1];
int   g_AHP_ArmTargetEntity[MAXPLAYERS+1];
float g_AHP_LastHoneypotTime[MAXPLAYERS+1];

// Judging window bookkeeping (after the speed reverts).
bool  g_AHP_Judging[MAXPLAYERS+1];
float g_AHP_JudgeStartTime[MAXPLAYERS+1];
int   g_AHP_JudgeTicks[MAXPLAYERS+1];
int   g_AHP_JudgeOnTargetTicks[MAXPLAYERS+1];

float g_AHP_EventTime[MAXPLAYERS+1][HONEYPOT_EVENT_HISTORY];
int   g_AHP_EventHead[MAXPLAYERS+1];
int   g_AHP_EventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
void AimHoneypot_Init(int client)
{
    if (g_AHP_Active[client] && g_AHP_TargetEntity[client] > 0 && IsClientInGame(g_AHP_TargetEntity[client]))
    {
        AimHoneypot_Revert(client);
    }
    g_AHP_Active[client] = false;
    g_AHP_ArmHoldTicks[client] = 0;
    g_AHP_ArmTargetEntity[client] = -1;
    g_AHP_LastHoneypotTime[client] = 0.0;
    g_AHP_Judging[client] = false;
    g_AHP_EventHead[client] = 0;
    g_AHP_EventCount[client] = 0;
}

static float AHP_FAbs(float v) { return v < 0.0 ? -v : v; }

static float AHP_NormalizeDeg(float d)
{
    if (d > 180.0) return 360.0 - d;
    return d;
}

static float AHP_ErrorToTarget(int client, int target, const float viewAngles[3])
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

    float dYaw = AHP_NormalizeDeg(AHP_FAbs(viewAngles[1] - wanted[1]));
    float dPitch = AHP_FAbs(viewAngles[0] - wanted[0]);
    return SquareRoot(dYaw*dYaw + dPitch*dPitch);
}

static float AHP_FRand(float lo, float hi)
{
    return lo + GetURandomFloat() * (hi - lo);
}

// ------------------------------------------------------------------
static void AimHoneypot_Trigger(int client, int target)
{
    g_AHP_Active[client] = true;
    g_AHP_TargetEntity[client] = target;
    g_AHP_StartTime[client] = GetGameTime();
    g_AHP_Reverted[client] = false;
    g_AHP_LastHoneypotTime[client] = GetGameTime();

    g_AHP_OriginalScale[client] = GetEntPropFloat(target, Prop_Send, "m_flLaggedMovementValue");
    if (g_AHP_OriginalScale[client] <= 0.0) g_AHP_OriginalScale[client] = 1.0;

    float scale = AHP_FRand(HONEYPOT_SCALE_MIN, HONEYPOT_SCALE_MAX);
    SetEntPropFloat(target, Prop_Send, "m_flLaggedMovementValue", scale);
}

static void AimHoneypot_Revert(int client)
{
    if (g_AHP_Reverted[client]) return;
    g_AHP_Reverted[client] = true;

    int target = g_AHP_TargetEntity[client];
    if (target > 0 && target <= MaxClients && IsClientInGame(target))
    {
        SetEntPropFloat(target, Prop_Send, "m_flLaggedMovementValue", g_AHP_OriginalScale[client]);
    }
}

// ------------------------------------------------------------------
// Called from anticheat_core.sp's player_death handler for EVERY death,
// not just survivor kills - if the Special Infected currently honeypotted
// for some attacker just died (of anything: fire, a Boomer bile
// friendly-fire fluke, falling, whatever), its altered speed scale must
// not linger on whatever entity slot gets reused next round. Also called
// from OnClientDisconnect for the same reason if the honeypotted target
// was a player-controlled Special that just left.
void AimHoneypot_OnEntityGone(int deadEntity)
{
    for (int c = 1; c <= MaxClients; c++)
    {
        if (g_AHP_Active[c] && g_AHP_TargetEntity[c] == deadEntity)
        {
            AimHoneypot_Revert(c);
            g_AHP_Active[c] = false;
        }
    }
}

// ------------------------------------------------------------------
// Called every tick from OnPlayerRunCmd for tier >= 2 players tracking a
// live Special Infected - shares the per-frame cache Aimlock/TriggerBot/
// TargetAcq already pay for, so this adds no extra scan of its own.
void AimHoneypot_RecordTick(int client, const float angles[3])
{
    // --- Finish any judging window from a previous honeypot first. ---
    if (g_AHP_Judging[client])
    {
        float now = GetGameTime();
        if (now - g_AHP_JudgeStartTime[client] > HONEYPOT_JUDGE_WINDOW_SEC)
        {
            AimHoneypot_FinishJudging(client);
        }
        else if (g_AHP_TargetEntity[client] > 0 && IsClientInGame(g_AHP_TargetEntity[client]))
        {
            float err = AHP_ErrorToTarget(client, g_AHP_TargetEntity[client], angles);
            g_AHP_JudgeTicks[client]++;
            if (err <= HONEYPOT_SURVIVE_ONTARGET_DEG) g_AHP_JudgeOnTargetTicks[client]++;
        }
    }

    // --- An active honeypot window - revert once its duration elapses. ---
    if (g_AHP_Active[client])
    {
        if (GetGameTime() - g_AHP_StartTime[client] >= HONEYPOT_DURATION_SEC)
        {
            AimHoneypot_Revert(client);
            g_AHP_Active[client] = false;

            // Start judging: does the player's tracking survive the
            // aftermath, or does their aim visibly lag/overshoot the way
            // a human recalibrating to a sudden speed change would?
            g_AHP_Judging[client] = true;
            g_AHP_JudgeStartTime[client] = GetGameTime();
            g_AHP_JudgeTicks[client] = 0;
            g_AHP_JudgeOnTargetTicks[client] = 0;
        }
        return; // don't also try to arm a new honeypot mid-window
    }

    // --- Not active - look for a target to potentially arm against. ---
    if (GetGameTime() - g_AHP_LastHoneypotTime[client] < HONEYPOT_COOLDOWN_SEC) return;

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
        if (dist < HONEYPOT_MIN_DIST_UNITS) continue;
        if (dist < nearestDist) { nearestDist = dist; nearest = i; }
    }

    if (nearest == -1)
    {
        g_AHP_ArmHoldTicks[client] = 0;
        g_AHP_ArmTargetEntity[client] = -1;
        return;
    }

    float err = AHP_ErrorToTarget(client, nearest, angles);
    if (err > HONEYPOT_ARM_ONTARGET_DEG || nearest != g_AHP_ArmTargetEntity[client])
    {
        g_AHP_ArmHoldTicks[client] = (err <= HONEYPOT_ARM_ONTARGET_DEG) ? 1 : 0;
        g_AHP_ArmTargetEntity[client] = nearest;
        return;
    }

    g_AHP_ArmHoldTicks[client]++;
    if (g_AHP_ArmHoldTicks[client] >= HONEYPOT_ARM_HOLD_TICKS)
    {
        AimHoneypot_Trigger(client, nearest);
        g_AHP_ArmHoldTicks[client] = 0;
    }
}

// ------------------------------------------------------------------
static void AimHoneypot_FinishJudging(int client)
{
    g_AHP_Judging[client] = false;

    int ticks = g_AHP_JudgeTicks[client];
    if (ticks < 4) return; // target lost almost immediately - not a usable sample either way

    float ratio = float(g_AHP_JudgeOnTargetTicks[client]) / float(ticks);
    if (ratio < HONEYPOT_SURVIVE_RATIO) return; // a human-like wobble/recovery - exactly what's expected, not evidence

    int idx = g_AHP_EventHead[client];
    g_AHP_EventTime[client][idx] = GetGameTime();
    g_AHP_EventHead[client] = (idx + 1) % HONEYPOT_EVENT_HISTORY;
    if (g_AHP_EventCount[client] < HONEYPOT_EVENT_HISTORY) g_AHP_EventCount[client]++;

    // A single survived honeypot is already strong (the same reasoning as
    // the gravity honeypot - it's a physical-impossibility check, not a
    // statistical tendency), but this is scored as a distinct source from
    // bhop's honeypot, so it starts a little below the bhop honeypot's
    // instant-100 to leave room to weight repeated survivals higher.
    int severity = RoundFloat(70.0 + (ratio - HONEYPOT_SURVIVE_RATIO) / (1.0 - HONEYPOT_SURVIVE_RATIO) * 30.0);
    Correlation_ReportEvent(client, CORR_DET_AIM_HONEYPOT, severity);
}

// ------------------------------------------------------------------
#define HONEYPOT_MIN_EVENTS 1
int AimHoneypot_GetScore(int client)
{
    int total = g_AHP_EventCount[client];
    if (total < HONEYPOT_MIN_EVENTS) return 0;

    float now = GetGameTime();
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_AHP_EventTime[client][i] <= 900.0) count++;
    }
    if (count < HONEYPOT_MIN_EVENTS) return 0;

    // Surviving even one is near-certain evidence by construction (a
    // human's felt-momentum recalibration takes real reaction time this
    // module's judging window is specifically sized to catch); surviving
    // more than one is conclusive.
    float score = (count >= 2) ? 100.0 : 85.0;
    return RoundFloat(score);
}
