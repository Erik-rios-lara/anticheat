// anticheat_integrity.sp - Packet/usercmd integrity checks for L4D2 Anti-Cheat
// (techniques credited to StAC-tf2)
//
// Unlike Aim and Bhop, these two checks don't look at behavior at all -
// they look at whether the usercmd the client sent is even physically or
// structurally possible for a legitimate client to produce. Both are
// near-zero false-positive by construction, so they act as a strong,
// independent signal when either module trips.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

// ------------------------------------------------------------------
// "Fake Angles" check: a legitimate client can never send a pitch outside
// +/-89 degrees or a roll outside +/-50 degrees - these are hard clamps
// the game's own input code enforces before the usercmd is even built.
// Some crude cheats (older aim/ESP tools poking view angles directly)
// bypass that clamp and send angles the real client never could.
#define FAKEANGLE_PITCH_LIMIT 89.0001
#define FAKEANGLE_ROLL_LIMIT  50.0001
#define FAKEANGLE_MIN_SAMPLES 3
#define FAKEANGLE_EVENT_HISTORY 16

// ------------------------------------------------------------------
// "Invalid Usercmd" check: cmdnum/tickcount going negative, or the
// buttons bitmask using bits beyond what the game ever sets (>= bit 26,
// since IN_ATTACK3 is the highest real flag at 1<<25), both indicate a
// hand-crafted or corrupted usercmd rather than one the real client
// produced.
#define INVALIDCMD_MIN_SAMPLES 3
#define INVALIDCMD_EVENT_HISTORY 16
#define INVALIDCMD_BUTTON_LIMIT (1 << 26)

#define INTEGRITY_EVENT_EXPIRE_SECONDS 600.0

float g_FakeAngleEventTime[MAXPLAYERS+1][FAKEANGLE_EVENT_HISTORY];
int   g_FakeAngleEventHead[MAXPLAYERS+1];
int   g_FakeAngleEventCount[MAXPLAYERS+1];

float g_InvalidCmdEventTime[MAXPLAYERS+1][INVALIDCMD_EVENT_HISTORY];
int   g_InvalidCmdEventHead[MAXPLAYERS+1];
int   g_InvalidCmdEventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
// "Speedhack" check (technique credited to SMAC's smac_speedhack
// module): a tick-credit system. Real server time elapsed refills a
// credit balance at exactly the server's tickrate; every usercmd the
// server actually processes for this client spends one credit. A
// legitimate client can never send more commands than real time allows
// (that's what the tickrate IS), so the balance should hover near zero
// and occasionally go slightly negative under normal jitter. A timescale
// cheat (or straight command injection) drives commands in faster than
// real time is passing, so the balance goes and stays deeply negative -
// exactly the signature no amount of network jitter alone can produce,
// which is why this also demands a STABLE ping (jitter alone can cause a
// one-off burst of buffered commands catching up, which is normal and
// must not be flagged).
#define SPEEDHACK_CHECK_INTERVAL   0.1    // how often the credit balance is topped up
#define SPEEDHACK_BUFFER_TICKS     2.0    // credit allowance beyond exact real-time (2 tickrate worth of slack)
#define SPEEDHACK_DEFICIT_TRIGGER  30     // consecutive intervals with an exhausted balance
#define SPEEDHACK_LATENCY_STABLE_MS 5.0   // ping must not have jumped more than this since last check
#define SPEEDHACK_EVENT_HISTORY 8
float g_SpeedhackCredit[MAXPLAYERS+1];
float g_SpeedhackLastCheck[MAXPLAYERS+1];
float g_SpeedhackPrevLatency[MAXPLAYERS+1];
int   g_SpeedhackDeficitStreak[MAXPLAYERS+1];
float g_SpeedhackEventTime[MAXPLAYERS+1][SPEEDHACK_EVENT_HISTORY];
int   g_SpeedhackEventHead[MAXPLAYERS+1];
int   g_SpeedhackEventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
// "Noclip" check: traces a ray between the player's position last tick
// and this tick along MASK_PLAYERSOLID. A legitimate client's movement
// is resolved by the engine's own collision every tick, so the path
// between two consecutive positions can never cross a solid surface - if
// it does, something moved the player through geometry the server itself
// would never have allowed, which is what a noclip-style position
// teleport/phase cheat produces. Very high speed (grenade knockback,
// Charger/Hunter pounce launches) can also produce a long jump between
// samples, so this only judges movement under a speed ceiling where a
// real collision response would still have been meaningful.
#define NOCLIP_MAX_JUDGE_SPEED   900.0   // ignore movement faster than this - not a normal walk/run/strafe distance
#define NOCLIP_MIN_MOVE_UNITS      4.0   // ignore sub-pixel jitter between samples
#define NOCLIP_EVENT_HISTORY 8
float g_NoclipPrevPos[MAXPLAYERS+1][3];
bool  g_NoclipHasPrevPos[MAXPLAYERS+1];
float g_NoclipEventTime[MAXPLAYERS+1][NOCLIP_EVENT_HISTORY];
int   g_NoclipEventHead[MAXPLAYERS+1];
int   g_NoclipEventCount[MAXPLAYERS+1];

void Integrity_Init(int client)
{
    g_FakeAngleEventHead[client] = 0;
    g_FakeAngleEventCount[client] = 0;
    g_InvalidCmdEventHead[client] = 0;
    g_InvalidCmdEventCount[client] = 0;

    g_SpeedhackCredit[client] = 0.0;
    g_SpeedhackLastCheck[client] = 0.0;
    g_SpeedhackPrevLatency[client] = 0.0;
    g_SpeedhackDeficitStreak[client] = 0;
    g_SpeedhackEventHead[client] = 0;
    g_SpeedhackEventCount[client] = 0;

    g_NoclipHasPrevPos[client] = false;
    g_NoclipEventHead[client] = 0;
    g_NoclipEventCount[client] = 0;
}

// ------------------------------------------------------------------
// Called every tick (OnPlayerRunCmd).
void Integrity_RecordTick(int client, const float angles[3], int buttons, int cmdnum, int tickcount)
{
    // Fake angles - pitch/roll outside the range the client's own input
    // code physically clamps to.
    if (FloatAbs(angles[0]) > FAKEANGLE_PITCH_LIMIT || FloatAbs(angles[2]) > FAKEANGLE_ROLL_LIMIT)
    {
        int idx = g_FakeAngleEventHead[client];
        g_FakeAngleEventTime[client][idx] = GetGameTime();
        g_FakeAngleEventHead[client] = (idx + 1) % FAKEANGLE_EVENT_HISTORY;
        if (g_FakeAngleEventCount[client] < FAKEANGLE_EVENT_HISTORY) g_FakeAngleEventCount[client]++;

        // Hard engine-limit violation - near-certain evidence on its own.
        Correlation_ReportEvent(client, CORR_DET_INTEGRITY, 90);
    }

    // Invalid usercmd - negative sequence fields, or a buttons mask using
    // bits the real client never sets.
    if (cmdnum < 0 || tickcount < 0 || buttons >= INVALIDCMD_BUTTON_LIMIT)
    {
        int idx = g_InvalidCmdEventHead[client];
        g_InvalidCmdEventTime[client][idx] = GetGameTime();
        g_InvalidCmdEventHead[client] = (idx + 1) % INVALIDCMD_EVENT_HISTORY;
        if (g_InvalidCmdEventCount[client] < INVALIDCMD_EVENT_HISTORY) g_InvalidCmdEventCount[client]++;

        Correlation_ReportEvent(client, CORR_DET_INTEGRITY, 90);
    }

    Integrity_CheckSpeedhack(client);
    Integrity_CheckNoclip(client);
}

// ------------------------------------------------------------------
// "Speedhack" tick-credit check (see comment near SPEEDHACK_* constants
// above). Tops up the credit balance by exactly the real time elapsed
// (plus a small buffer for normal jitter) and spends one credit per
// processed command; a balance that stays exhausted for many consecutive
// checks means commands are arriving faster than real time can explain.
static void Integrity_CheckSpeedhack(int client)
{
    float now = GetGameTime();
    float latencyMs = GetClientAvgLatency(client, NetFlow_Outgoing) * 1000.0;

    if (g_SpeedhackLastCheck[client] <= 0.0)
    {
        g_SpeedhackLastCheck[client] = now;
        g_SpeedhackPrevLatency[client] = latencyMs;
        g_SpeedhackCredit[client] = 0.0;
        return;
    }

    // Spend one credit for this processed command.
    g_SpeedhackCredit[client] -= 1.0;

    float elapsed = now - g_SpeedhackLastCheck[client];
    if (elapsed < SPEEDHACK_CHECK_INTERVAL) return;

    float tickInterval = GetTickInterval();
    if (tickInterval <= 0.0) tickInterval = 0.015;
    float refill = (elapsed / tickInterval) + SPEEDHACK_BUFFER_TICKS;
    g_SpeedhackCredit[client] += refill;
    if (g_SpeedhackCredit[client] > SPEEDHACK_BUFFER_TICKS) g_SpeedhackCredit[client] = SPEEDHACK_BUFFER_TICKS;

    g_SpeedhackLastCheck[client] = now;

    // Ping spiking is a legitimate reason for a burst of buffered
    // commands to land at once - only judge the balance while latency has
    // been stable since the last check.
    bool latencyStable = FloatAbs(g_SpeedhackPrevLatency[client] - latencyMs) <= SPEEDHACK_LATENCY_STABLE_MS;
    g_SpeedhackPrevLatency[client] = latencyMs;

    if (g_SpeedhackCredit[client] < 0.0 && latencyStable)
    {
        g_SpeedhackDeficitStreak[client]++;
        if (g_SpeedhackDeficitStreak[client] >= SPEEDHACK_DEFICIT_TRIGGER)
        {
            int idx = g_SpeedhackEventHead[client];
            g_SpeedhackEventTime[client][idx] = now;
            g_SpeedhackEventHead[client] = (idx + 1) % SPEEDHACK_EVENT_HISTORY;
            if (g_SpeedhackEventCount[client] < SPEEDHACK_EVENT_HISTORY) g_SpeedhackEventCount[client]++;

            // Structurally impossible under real time - near-certain evidence.
            Correlation_ReportEvent(client, CORR_DET_SPEEDHACK, 90);
            g_SpeedhackDeficitStreak[client] = 0; // one confirmed run = one event
        }
    }
    else
    {
        g_SpeedhackDeficitStreak[client] = 0;
    }
}

// ------------------------------------------------------------------
// "Noclip" position-trace check (see comment near NOCLIP_* constants
// above). Traces the straight line between last tick's position and this
// tick's; a legitimate client's own collision resolution can never
// produce a path that crosses solid geometry.
static void Integrity_CheckNoclip(int client)
{
    float pos[3];
    GetClientAbsOrigin(client, pos);

    if (!g_NoclipHasPrevPos[client])
    {
        g_NoclipPrevPos[client][0] = pos[0];
        g_NoclipPrevPos[client][1] = pos[1];
        g_NoclipPrevPos[client][2] = pos[2];
        g_NoclipHasPrevPos[client] = true;
        return;
    }

    float prev[3];
    prev[0] = g_NoclipPrevPos[client][0];
    prev[1] = g_NoclipPrevPos[client][1];
    prev[2] = g_NoclipPrevPos[client][2];
    g_NoclipPrevPos[client][0] = pos[0];
    g_NoclipPrevPos[client][1] = pos[1];
    g_NoclipPrevPos[client][2] = pos[2];

    float dist = GetVectorDistance(prev, pos);
    if (dist < NOCLIP_MIN_MOVE_UNITS) return;

    float tickInterval = GetTickInterval();
    if (tickInterval <= 0.0) tickInterval = 0.015;
    float speed = dist / tickInterval;
    if (speed > NOCLIP_MAX_JUDGE_SPEED) return; // too fast to be a normal collision-resolved step - could be knockback/pounce

    Handle trace = TR_TraceRayFilterEx(prev, pos, MASK_PLAYERSOLID, RayType_EndPoint, Integrity_NoclipTraceFilter, client);
    bool blocked = TR_DidHit(trace);
    delete trace;
    if (!blocked) return;

    int idx = g_NoclipEventHead[client];
    g_NoclipEventTime[client][idx] = GetGameTime();
    g_NoclipEventHead[client] = (idx + 1) % NOCLIP_EVENT_HISTORY;
    if (g_NoclipEventCount[client] < NOCLIP_EVENT_HISTORY) g_NoclipEventCount[client]++;

    // A path through solid geometry is structurally impossible for a
    // legitimately-moved client - near-certain evidence on its own.
    Correlation_ReportEvent(client, CORR_DET_NOCLIP, 90);
}

// Ignore the player's own entity (and other players/NPCs) so the trace
// only judges world/static geometry, not incidental player-vs-player
// collision along the path.
static bool Integrity_NoclipTraceFilter(int entity, int contentsMask, any data)
{
    if (entity == data) return false;
    if (entity >= 1 && entity <= MaxClients) return false;
    return true;
}

static float FMinI(float a, float b) { return a < b ? a : b; }

int Integrity_GetFakeAngleScore(int client)
{
    int total = g_FakeAngleEventCount[client];
    if (total < FAKEANGLE_MIN_SAMPLES) return 0;

    float now = GetGameTime();
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_FakeAngleEventTime[client][i] <= INTEGRITY_EVENT_EXPIRE_SECONDS) count++;
    }
    if (count < FAKEANGLE_MIN_SAMPLES) return 0;
    // Near-zero false positive rate by construction - weight heavily.
    return RoundFloat(FMinI(float(count - FAKEANGLE_MIN_SAMPLES) * 20.0 + 60.0, 100.0));
}

int Integrity_GetInvalidCmdScore(int client)
{
    int total = g_InvalidCmdEventCount[client];
    if (total < INVALIDCMD_MIN_SAMPLES) return 0;

    float now = GetGameTime();
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_InvalidCmdEventTime[client][i] <= INTEGRITY_EVENT_EXPIRE_SECONDS) count++;
    }
    if (count < INVALIDCMD_MIN_SAMPLES) return 0;
    return RoundFloat(FMinI(float(count - INVALIDCMD_MIN_SAMPLES) * 20.0 + 60.0, 100.0));
}

#define SPEEDHACK_MIN_SAMPLES 1
int Integrity_GetSpeedhackScore(int client)
{
    int total = g_SpeedhackEventCount[client];
    if (total < SPEEDHACK_MIN_SAMPLES) return 0;

    float now = GetGameTime();
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_SpeedhackEventTime[client][i] <= INTEGRITY_EVENT_EXPIRE_SECONDS) count++;
    }
    if (count < SPEEDHACK_MIN_SAMPLES) return 0;
    return RoundFloat(FMinI(float(count - SPEEDHACK_MIN_SAMPLES) * 20.0 + 70.0, 100.0));
}

#define NOCLIP_MIN_SAMPLES 1
int Integrity_GetNoclipScore(int client)
{
    int total = g_NoclipEventCount[client];
    if (total < NOCLIP_MIN_SAMPLES) return 0;

    float now = GetGameTime();
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_NoclipEventTime[client][i] <= INTEGRITY_EVENT_EXPIRE_SECONDS) count++;
    }
    if (count < NOCLIP_MIN_SAMPLES) return 0;
    return RoundFloat(FMinI(float(count - NOCLIP_MIN_SAMPLES) * 20.0 + 70.0, 100.0));
}

// Combined score for this module - any sub-check maxes it out.
int Integrity_GetScore(int client)
{
    int fa = Integrity_GetFakeAngleScore(client);
    int iu = Integrity_GetInvalidCmdScore(client);
    int sh = Integrity_GetSpeedhackScore(client);
    int nc = Integrity_GetNoclipScore(client);
    int best = fa;
    if (iu > best) best = iu;
    if (sh > best) best = sh;
    if (nc > best) best = nc;
    return best;
}
