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

void Integrity_Init(int client)
{
    g_FakeAngleEventHead[client] = 0;
    g_FakeAngleEventCount[client] = 0;
    g_InvalidCmdEventHead[client] = 0;
    g_InvalidCmdEventCount[client] = 0;
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
    }

    // Invalid usercmd - negative sequence fields, or a buttons mask using
    // bits the real client never sets.
    if (cmdnum < 0 || tickcount < 0 || buttons >= INVALIDCMD_BUTTON_LIMIT)
    {
        int idx = g_InvalidCmdEventHead[client];
        g_InvalidCmdEventTime[client][idx] = GetGameTime();
        g_InvalidCmdEventHead[client] = (idx + 1) % INVALIDCMD_EVENT_HISTORY;
        if (g_InvalidCmdEventCount[client] < INVALIDCMD_EVENT_HISTORY) g_InvalidCmdEventCount[client]++;
    }
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

// Combined score for this module - either sub-check maxes it out.
int Integrity_GetScore(int client)
{
    int fa = Integrity_GetFakeAngleScore(client);
    int iu = Integrity_GetInvalidCmdScore(client);
    return fa > iu ? fa : iu;
}
