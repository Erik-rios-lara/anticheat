// anticheat_nolerp.sp - NoLerp detector for L4D2 Anti-Cheat
// (technique credited to Lilac / Little-Anti-Cheat)
//
// Some cheats set the client's interpolation ("lerp") delay to 0ms, or to
// a value below what the server's update rate can even produce, to shave
// the interpolation buffer off their perceived aim - the crosshair reacts
// to the very latest position data with no smoothing at all, which makes
// snap/flick aimbots noticeably more accurate. This is a client ConVar
// (cl_interp / cl_interp_ratio), so the server can just ask for it - no
// tick-by-tick behavior analysis needed, and essentially zero false
// positives once the "physically possible minimum" is computed correctly.
//
// minimum possible lerp = cl_interp_ratio / cl_updaterate, clamped to
// whatever cl_interp itself floors it at. If the server enforces
// sv_client_min_interp_ratio (or equivalent), the true floor is even
// simpler - but we compute it generically so this isn't tied to one cvar
// set that a future game update could rename.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>

#define NOLERP_CHECK_INTERVAL 5.0
#define NOLERP_MIN_SAMPLES 3
#define NOLERP_EVENT_HISTORY 16
#define NOLERP_EVENT_EXPIRE_SECONDS 600.0

// Below this, a computed "minimum possible lerp" is treated as noise/not
// meaningful rather than a real floor to compare against - avoids false
// positives from odd server configs where updaterate is unset or huge.
#define NOLERP_MIN_FLOOR_SECONDS 0.005

// Give a 5% buffer under the computed floor before calling it suspicious -
// float rounding on the client's reported cvars shouldn't false-positive
// someone running the legitimate minimum.
#define NOLERP_TOLERANCE 0.95

float g_NoLerpEventTime[MAXPLAYERS+1][NOLERP_EVENT_HISTORY];
int   g_NoLerpEventHead[MAXPLAYERS+1];
int   g_NoLerpEventCount[MAXPLAYERS+1];
Handle g_NoLerpTimer[MAXPLAYERS+1];

// QueryClientConVar only carries a single `any` through its callback, so
// the interp/interp_ratio/updaterate chain is threaded through these
// per-client scratch fields instead of passed as call data.
float g_NoLerpScratchInterp[MAXPLAYERS+1];
float g_NoLerpScratchInterpRatio[MAXPLAYERS+1];

void NoLerp_Init(int client)
{
    g_NoLerpEventHead[client] = 0;
    g_NoLerpEventCount[client] = 0;

    if (g_NoLerpTimer[client] != null)
    {
        KillTimer(g_NoLerpTimer[client]);
        g_NoLerpTimer[client] = null;
    }
    if (IsClientInGame(client) && !IsFakeClient(client))
    {
        g_NoLerpTimer[client] = CreateTimer(NOLERP_CHECK_INTERVAL, Timer_CheckNoLerp, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}

void NoLerp_Shutdown(int client)
{
    if (g_NoLerpTimer[client] != null)
    {
        KillTimer(g_NoLerpTimer[client]);
        g_NoLerpTimer[client] = null;
    }
}

static Action Timer_CheckNoLerp(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Continue;
    }

    QueryClientConVar(client, "cl_interp", ConVar_OnInterp, client);
    return Plugin_Continue;
}

static void ConVar_OnInterp(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] value)
{
    if (result != ConVarQuery_Okay || !IsClientInGame(client)) return;

    g_NoLerpScratchInterp[client] = StringToFloat(value);
    QueryClientConVar(client, "cl_interp_ratio", ConVar_OnInterpRatio, client);
}

static void ConVar_OnInterpRatio(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] value)
{
    if (result != ConVarQuery_Okay || !IsClientInGame(client)) return;

    g_NoLerpScratchInterpRatio[client] = StringToFloat(value);
    QueryClientConVar(client, "cl_updaterate", ConVar_OnUpdateRate, client);
}

static void ConVar_OnUpdateRate(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] value)
{
    if (result != ConVarQuery_Okay || !IsClientInGame(client)) return;

    float interp = g_NoLerpScratchInterp[client];
    float interpRatio = g_NoLerpScratchInterpRatio[client];
    float updateRate = StringToFloat(value);

    if (updateRate <= 0.0 || interpRatio <= 0.0) return; // can't compute a floor, skip this round

    float minLerpPossible = interpRatio / updateRate;
    if (minLerpPossible < NOLERP_MIN_FLOOR_SECONDS) return; // degenerate server config, not meaningful

    if (interp > 0.0 && interp < minLerpPossible * NOLERP_TOLERANCE)
    {
        int idx = g_NoLerpEventHead[client];
        g_NoLerpEventTime[client][idx] = GetGameTime();
        g_NoLerpEventHead[client] = (idx + 1) % NOLERP_EVENT_HISTORY;
        if (g_NoLerpEventCount[client] < NOLERP_EVENT_HISTORY) g_NoLerpEventCount[client]++;

        // Configuration read, not behavior - near-certain by construction.
        Correlation_ReportEvent(client, CORR_DET_NOLERP, 85);
    }
}

static float FMinNL(float a, float b) { return a < b ? a : b; }

int NoLerp_GetScore(int client)
{
    int total = g_NoLerpEventCount[client];
    if (total < NOLERP_MIN_SAMPLES) return 0;

    float now = GetGameTime();
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_NoLerpEventTime[client][i] <= NOLERP_EVENT_EXPIRE_SECONDS) count++;
    }
    if (count < NOLERP_MIN_SAMPLES) return 0;

    // Near-zero false positive rate by construction (it's just reading a
    // cvar against a computed physical floor) - weight heavily as soon as
    // it's confirmed across a few checks, so a one-off query glitch alone
    // can't trigger it.
    return RoundFloat(FMinNL(float(count - NOLERP_MIN_SAMPLES) * 20.0 + 70.0, 100.0));
}
