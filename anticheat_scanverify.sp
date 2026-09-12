// anticheat_scanverify.sp - Client-side scanner verification.
//
// Queries the backend (discord-bot/server.js) for whether a connecting
// player has a recent, clean run of the standalone C++ scanner
// (scanner/src/main.cpp) on file. This is an INFORMATIONAL signal for
// admins, not an automatic detector on its own - it never contributes to
// the Risk Score or the tiered evidence model. Reasons:
//
//   - Running the scanner is voluntary. A player who has simply never
//     run it is indistinguishable here from one avoiding it, and the
//     overwhelming majority of legitimate players will never have heard
//     of it - treating "not scanned" as suspicious would flag almost
//     everyone.
//   - The backend and HMAC signing raise the bar against a fabricated
//     report, but do not make this cryptographically unbreakable (see
//     the scanner project's own design notes) - it should never carry
//     enough weight on its own to kick/ban.
//
// What it DOES do: surfaces the scan status (never scanned / scanned
// clean / scanned with findings, and how long ago) to admins via the
// in-game menu and sm_ac_view, and posts an admin-only note to Discord
// when a connecting player's most recent scan had HIGH findings - that
// combination (known cheat traces on disk + currently joining the
// server) is worth a human look even though it's not, by itself,
// grounds for automatic action.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <ripext>

ConVar g_cvScanBackendURL;
ConVar g_cvScanVerifyEnabled;

enum ScanStatusState
{
    SCANSTATE_UNKNOWN = 0,  // haven't asked yet, or the query is still in flight
    SCANSTATE_NEVER_SCANNED,
    SCANSTATE_SCAN_CLEAN,
    SCANSTATE_SCAN_FLAGGED, // scanned, but had HIGH and/or SUSPICIOUS findings
    SCANSTATE_QUERY_FAILED  // backend unreachable/errored - not the same as "never scanned"
};

ScanStatusState g_ScanState[MAXPLAYERS+1];
int   g_ScanFindingsHigh[MAXPLAYERS+1];
int   g_ScanFindingsSuspicious[MAXPLAYERS+1];
int   g_ScanAgeSeconds[MAXPLAYERS+1];
bool  g_ScanIsFresh[MAXPLAYERS+1];

void ScanVerify_Init(int client)
{
    g_ScanState[client] = SCANSTATE_UNKNOWN;
    g_ScanFindingsHigh[client] = 0;
    g_ScanFindingsSuspicious[client] = 0;
    g_ScanAgeSeconds[client] = 0;
    g_ScanIsFresh[client] = false;
}

void ScanVerify_PluginStart()
{
    g_cvScanBackendURL = CreateConVar("sm_ac_scan_backend_url", "http://127.0.0.1:8787",
        "Base URL of the scanner backend (discord-bot/server.js). No trailing slash.", FCVAR_PROTECTED);
    g_cvScanVerifyEnabled = CreateConVar("sm_ac_scan_verify_enabled", "1",
        "Query the scanner backend on connect. 1 = On, 0 = Off.", FCVAR_NOTIFY);
}

// ------------------------------------------------------------------
// Called from OnClientPutInServer. Fires an async query - never blocks
// connection, and a failed/slow backend never prevents a player from
// joining (this is informational only, see file header).
void ScanVerify_QueryOnConnect(int client)
{
    if (!g_cvScanVerifyEnabled.BoolValue) return;
    if (IsFakeClient(client)) return;

    char steamId64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64)))
    {
        g_ScanState[client] = SCANSTATE_QUERY_FAILED;
        return;
    }

    char backendUrl[256];
    g_cvScanBackendURL.GetString(backendUrl, sizeof(backendUrl));
    if (strlen(backendUrl) < 8)
    {
        return; // not configured, silently skip - this feature is opt-in via the ConVar above
    }

    char url[300];
    FormatEx(url, sizeof(url), "%s/api/scan-status/%s", backendUrl, steamId64);

    // This route is read-only (it can't be used to inject a fake report),
    // so a simple shared-key header is enough here - see anticheat_core.sp
    // and the file header for why HMAC (used by the scanner's own POST) is
    // not practical to reproduce from plain SourcePawn. Must match
    // PLUGIN_SHARED_KEY in discord-bot/.env exactly.
    char pluginKey[128];
    GetScanPluginKey(pluginKey, sizeof(pluginKey));
    if (strlen(pluginKey) == 0)
    {
        LogError("[AntiCheat] sm_ac_scanner_plugin_key no está configurado - no se puede verificar el escaneo de %N.", client);
        g_ScanState[client] = SCANSTATE_QUERY_FAILED;
        return;
    }

    HTTPRequest req = new HTTPRequest(url);
    req.SetHeader("X-Plugin-Key", pluginKey);
    req.Get(OnScanStatusResponse, GetClientUserId(client));
}

static void OnScanStatusResponse(HTTPResponse response, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client)) return; // disconnected before the response arrived

    if (response.Status != HTTPStatus_OK)
    {
        g_ScanState[client] = SCANSTATE_QUERY_FAILED;
        return;
    }

    JSONObject data = view_as<JSONObject>(response.Data);
    if (data == null)
    {
        g_ScanState[client] = SCANSTATE_QUERY_FAILED;
        return;
    }

    bool scanned = data.GetBool("scanned");
    if (!scanned)
    {
        g_ScanState[client] = SCANSTATE_NEVER_SCANNED;
        delete data;
        return;
    }

    int findingsHigh = data.GetInt("findingsHigh");
    int findingsSuspicious = data.GetInt("findingsSuspicious");
    bool fresh = data.GetBool("fresh");
    int ageSeconds = data.GetInt("ageSeconds");
    delete data;

    g_ScanFindingsHigh[client] = findingsHigh;
    g_ScanFindingsSuspicious[client] = findingsSuspicious;
    g_ScanAgeSeconds[client] = ageSeconds;
    g_ScanIsFresh[client] = fresh;
    g_ScanState[client] = (findingsHigh > 0 || findingsSuspicious > 0) ? SCANSTATE_SCAN_FLAGGED : SCANSTATE_SCAN_CLEAN;

    // A connecting player whose most recent scan found known cheat
    // traces is worth an admin's attention even though this module never
    // acts on it automatically - see file header for why.
    if (findingsHigh > 0)
    {
        char playerName[MAX_NAME_LENGTH];
        GetClientName(client, playerName, sizeof(playerName));
        AC_NotifyAdmins("[AntiCheat] %N tiene un escaneo de PC previo con %d hallazgo(s) de severidad ALTA (hace %d s). Revisar con sm_ac_view.",
                          client, findingsHigh, ageSeconds);
    }
}

// ------------------------------------------------------------------
// Human-readable one-liner for the menu / sm_ac_view.
void ScanVerify_Describe(int client, char[] buffer, int maxlen)
{
    switch (g_ScanState[client])
    {
        case SCANSTATE_UNKNOWN:
            strcopy(buffer, maxlen, "consultando...");
        case SCANSTATE_NEVER_SCANNED:
            strcopy(buffer, maxlen, "nunca escaneado (voluntario, no es sospechoso por sí solo)");
        case SCANSTATE_QUERY_FAILED:
            strcopy(buffer, maxlen, "no se pudo verificar (backend no disponible)");
        case SCANSTATE_SCAN_CLEAN:
            FormatEx(buffer, maxlen, "limpio (hace %d s, %s)", g_ScanAgeSeconds[client],
                      g_ScanIsFresh[client] ? "reciente" : "antiguo");
        case SCANSTATE_SCAN_FLAGGED:
            FormatEx(buffer, maxlen, "%d ALTO / %d sospechoso (hace %d s, %s)",
                      g_ScanFindingsHigh[client], g_ScanFindingsSuspicious[client], g_ScanAgeSeconds[client],
                      g_ScanIsFresh[client] ? "reciente" : "antiguo");
        default:
            strcopy(buffer, maxlen, "desconocido");
    }
}

// ------------------------------------------------------------------
static ConVar g_cvScanPluginKey;

static void GetScanPluginKey(char[] buffer, int maxlen)
{
    if (g_cvScanPluginKey == null)
    {
        g_cvScanPluginKey = CreateConVar("sm_ac_scanner_plugin_key", "",
            "Must match PLUGIN_SHARED_KEY in discord-bot/.env exactly.", FCVAR_PROTECTED);
    }
    g_cvScanPluginKey.GetString(buffer, maxlen);
}
