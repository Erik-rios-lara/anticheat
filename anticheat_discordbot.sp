// anticheat_discordbot.sp - Interactive Discord bot bridge for L4D2 AntiCheat
//
// Communicates with a separate Node.js Discord bot (discord-bot/bot.js)
// entirely through shared JSON files on disk - no RCON, no open network
// port on the game server. Two folders under
// addons/sourcemod/data/anticheat_ipc/:
//
//   pending_alerts/   this plugin writes one JSON file per detection; the
//                      bot reads it, posts it to Discord with buttons, and
//                      deletes the file.
//   pending_actions/  the bot writes one JSON file when an admin presses a
//                      button (Kick / Ban 1h / Ban permanent); this plugin
//                      polls the folder, executes the action, and deletes
//                      the file.
//
// NOTE: after adding/changing this timer, a plain "sm plugins unload" +
// "sm plugins load" is not enough to make it fire reliably - SourceMod can
// leave a hot-reloaded timer un-hooked from the engine tick even though
// CreateTimer() returns a valid handle. A full game restart (or a
// changelevel) always works. This is a SourceMod hot-reload quirk, not a
// bug in this code.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <ripext>

#define IPC_POLL_INTERVAL 3.0

void DiscordBot_Init()
{
    char alertsPath[PLATFORM_MAX_PATH], actionsPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, alertsPath, sizeof(alertsPath), "data/anticheat_ipc/pending_alerts");
    BuildPath(Path_SM, actionsPath, sizeof(actionsPath), "data/anticheat_ipc/pending_actions");

    if (!DirExists(alertsPath))  CreateDirectory(alertsPath, 511);
    if (!DirExists(actionsPath)) CreateDirectory(actionsPath, 511);

    CreateTimer(IPC_POLL_INTERVAL, Timer_PollActions, _, TIMER_REPEAT);
}

// ------------------------------------------------------------------
// Called from the risk timer whenever a detection needs the bot's
// interactive alert (kick/ban buttons), instead of - or in addition to -
// the plain webhook alert.
void DiscordBot_SendAlert(int client, int aimScore, int bhopScore, int integrityScore, int noLerpScore, int osacScore, int totalRisk)
{
    char playerName[MAX_NAME_LENGTH];
    GetClientName(client, playerName, sizeof(playerName));

    char steamId[32];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

    JSONObject alert = new JSONObject();
    alert.SetString("playerName", playerName);
    alert.SetString("steamId", steamId);
    alert.SetInt("aimScore", aimScore);
    alert.SetInt("bhopScore", bhopScore);
    alert.SetInt("integrityScore", integrityScore);
    alert.SetInt("noLerpScore", noLerpScore);
    alert.SetInt("osacScore", osacScore);
    alert.SetInt("totalRisk", totalRisk);

    char fileName[64];
    FormatEx(fileName, sizeof(fileName), "%d_%d.json", GetTime(), client);

    char fullPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, fullPath, sizeof(fullPath), "data/anticheat_ipc/pending_alerts/%s", fileName);

    alert.ToFile(fullPath);
    delete alert;
}

// ------------------------------------------------------------------
// Polls pending_actions/ for admin decisions made via Discord buttons.
public Action Timer_PollActions(Handle timer)
{
    char actionsDir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, actionsDir, sizeof(actionsDir), "data/anticheat_ipc/pending_actions");

    DirectoryListing dir = OpenDirectory(actionsDir);
    if (dir == null) return Plugin_Continue;

    char fileName[128];
    FileType type;
    while (dir.GetNext(fileName, sizeof(fileName), type))
    {
        if (type != FileType_File) continue;
        if (StrContains(fileName, ".json") == -1) continue;

        char fullPath[PLATFORM_MAX_PATH];
        BuildPath(Path_SM, fullPath, sizeof(fullPath), "data/anticheat_ipc/pending_actions/%s", fileName);

        JSONObject action = JSONObject.FromFile(fullPath);
        if (action != null)
        {
            ProcessDiscordAction(action);
            delete action;
        }
        DeleteFile(fullPath);
    }
    delete dir;

    return Plugin_Continue;
}

static void ProcessDiscordAction(JSONObject action)
{
    char actionType[16];
    action.GetString("type", actionType, sizeof(actionType));

    char steamId[32];
    action.GetString("steamId", steamId, sizeof(steamId));

    char requestedBy[128];
    action.GetString("requestedBy", requestedBy, sizeof(requestedBy));

    int target = FindClientBySteamId(steamId);
    if (target <= 0)
    {
        LogToFile("logs/anticheat/anticheat.log",
                  "[DiscordBot] Accion '%s' para SteamID %s ignorada: jugador ya no esta conectado.",
                  actionType, steamId);
        return;
    }

    char playerName[MAX_NAME_LENGTH];
    GetClientName(target, playerName, sizeof(playerName));

    if (StrEqual(actionType, "KICK"))
    {
        LogToFile("logs/anticheat/anticheat.log",
                  "[DiscordBot] %s expulsado por %s via Discord.", playerName, requestedBy);
        KickClient(target, "Expulsado por un administrador via Discord.");
    }
    else if (StrEqual(actionType, "BAN"))
    {
        int minutes = action.GetInt("minutes");
        LogToFile("logs/anticheat/anticheat.log",
                  "[DiscordBot] %s baneado (%d min) por %s via Discord.", playerName, minutes, requestedBy);
        BanClient(target, minutes, BANFLAG_AUTO,
                  "Baneado por un administrador via Discord.",
                  "Baneado por un administrador via Discord.",
                  "discordbot");
    }
}

// ------------------------------------------------------------------
static int FindClientBySteamId(const char[] steamId)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;

        char id[32];
        GetClientAuthId(i, AuthId_Steam2, id, sizeof(id));
        if (StrEqual(id, steamId, false)) return i;
    }
    return -1;
}
