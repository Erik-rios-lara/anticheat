// anticheat_discord.sp - Discord Webhook Integration for L4D2 Anti-Cheat
// Uses the RIPExt extension to POST embeds to Discord.
// Configure the webhook URL via the ConVar: sm_ac_discord_webhook
//
// RIPExt is used instead of SteamWorks because SteamWorks' HTTP callbacks
// depend on the Steam client API's internal callback pump, which in many
// listen-server / dedicated-server configurations never completes - the
// request goes out but SteamWorks_SetHTTPCallbacks's callback never fires.
// RIPExt talks HTTP directly and does not have this problem.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <ripext>

ConVar g_cvWebhookURL;
ConVar g_cvDiscordEnabled;

#define COLOR_KICK    16711680
#define COLOR_WARN    16744192
#define COLOR_NOTE    16776960

void Discord_Init()
{
    // Keep secrets out of the plugin binary/source. Configure this in
    // cfg/sourcemod/anticheat.cfg on the server.
    g_cvWebhookURL = CreateConVar("sm_ac_discord_webhook", "", "Discord webhook URL", FCVAR_PROTECTED);
    g_cvDiscordEnabled = CreateConVar("sm_ac_discord_enabled", "1", "Enable Discord notifications. 1 = On, 0 = Off.", FCVAR_NOTIFY);
    AutoExecConfig(true, "anticheat");
}

void Discord_Post(const char[] jsonPayload)
{
    if (!g_cvDiscordEnabled.BoolValue) return;

    char webhookURL[1024];
    g_cvWebhookURL.GetString(webhookURL, sizeof(webhookURL));
    if (strlen(webhookURL) < 10)
    {
        LogToFile(LOG_FILE, "[Discord] Webhook is empty or invalid.");
        return;
    }

    JSONObject body = JSONObject.FromString(jsonPayload);
    if (body == null)
    {
        LogToFile(LOG_FILE, "[Discord] Failed to parse outgoing JSON payload.");
        return;
    }

    HTTPRequest request = new HTTPRequest(webhookURL);
    request.Post(body, Discord_OnResponse);
    delete body;
}

public void Discord_OnResponse(HTTPResponse response, any value)
{
    if (response.Status < HTTPStatus_OK || response.Status >= HTTPStatus_MultipleChoices)
    {
        LogToFile(LOG_FILE, "[Discord] HTTP Error - status=%d", response.Status);
    }
    else
    {
        LogToFile(LOG_FILE, "[Discord] Webhook delivered successfully (status=%d).", response.Status);
    }
}

static void JsonEscape(const char[] input, char[] output, int maxlen)
{
    int out = 0;
    for (int i = 0; input[i] != '\0' && out < maxlen - 1; i++)
    {
        char c = input[i];
        if ((c == '"' || c == '\\') && out < maxlen - 2)
        {
            output[out++] = '\\';
            output[out++] = c;
        }
        else if (c == '\n' && out < maxlen - 2)
        {
            output[out++] = '\\';
            output[out++] = 'n';
        }
        else if (c == '\r' && out < maxlen - 2)
        {
            output[out++] = '\\';
            output[out++] = 'r';
        }
        else if (c >= 32)
        {
            output[out++] = c;
        }
    }
    output[out] = '\0';
}

void Discord_SendRiskAlert(int client, int aimScore, int bhopScore, int integrityScore, int noLerpScore, int osacScore, int totalRisk, const char[] action)
{
    // Only confirmed auto-kicks/bans (and failed attempts, worth surfacing
    // on their own) go to Discord - WARN/NOTE alerts still show in server
    // chat and the log file, but would otherwise flood the channel every
    // 10 seconds while a suspicious player stays connected.
    if (!StrEqual(action, "KICK") && !StrEqual(action, "BAN") && !StrEqual(action, "BAN_FAILED")) return;

    char playerName[MAX_NAME_LENGTH];
    GetClientName(client, playerName, sizeof(playerName));

    char steamId[32];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

    char ip[32];
    GetClientIP(client, ip, sizeof(ip));

    char safeAction[32], safeName[MAX_NAME_LENGTH], safeSteamId[32], safeIp[32];
    JsonEscape(action, safeAction, sizeof(safeAction));
    JsonEscape(playerName, safeName, sizeof(safeName));
    JsonEscape(steamId, safeSteamId, sizeof(safeSteamId));
    JsonEscape(ip, safeIp, sizeof(safeIp));

    int color = COLOR_NOTE;
    if (StrEqual(action, "KICK") || StrEqual(action, "BAN")) color = COLOR_KICK;
    else if (StrEqual(action, "WARN") || StrEqual(action, "BAN_FAILED")) color = COLOR_WARN;

    char json[2048];
    FormatEx(json, sizeof(json),
        "{\"embeds\":[{\"title\":\"[AntiCheat] %s Alert\",\"color\":%d,\"fields\":[{\"name\":\"Player\",\"value\":\"%s\",\"inline\":true},{\"name\":\"SteamID\",\"value\":\"%s\",\"inline\":true},{\"name\":\"IP\",\"value\":\"%s\",\"inline\":true},{\"name\":\"Aim\",\"value\":\"%d\",\"inline\":true},{\"name\":\"Bhop\",\"value\":\"%d\",\"inline\":true},{\"name\":\"Integrity\",\"value\":\"%d\",\"inline\":true},{\"name\":\"NoLerp\",\"value\":\"%d\",\"inline\":true},{\"name\":\"OSAC\",\"value\":\"%d\",\"inline\":true},{\"name\":\"Risk Score\",\"value\":\"**%d / 100**\",\"inline\":true}],\"footer\":{\"text\":\"L4D2 AntiCheat\"}}]}",
        safeAction, color, safeName, safeSteamId, safeIp, aimScore, bhopScore, integrityScore, noLerpScore, osacScore, totalRisk
    );

    Discord_Post(json);
}

void Discord_SendAdminQuery(int admin, int target, int aimScore, int bhopScore, int integrityScore, int noLerpScore, int osacScore, int totalRisk)
{
    char adminName[MAX_NAME_LENGTH];
    GetClientName(admin, adminName, sizeof(adminName));

    char playerName[MAX_NAME_LENGTH];
    GetClientName(target, playerName, sizeof(playerName));

    char steamId[32];
    GetClientAuthId(target, AuthId_Steam2, steamId, sizeof(steamId));

    char safeAdminName[MAX_NAME_LENGTH], safePlayerName[MAX_NAME_LENGTH], safeSteamId[32];
    JsonEscape(adminName, safeAdminName, sizeof(safeAdminName));
    JsonEscape(playerName, safePlayerName, sizeof(safePlayerName));
    JsonEscape(steamId, safeSteamId, sizeof(safeSteamId));

    char json[2048];
    FormatEx(json, sizeof(json),
        "{\"embeds\":[{\"title\":\"[AntiCheat] Admin %s inspected %s\",\"color\":3447003,\"fields\":[{\"name\":\"Player\",\"value\":\"%s\",\"inline\":true},{\"name\":\"SteamID\",\"value\":\"%s\",\"inline\":true},{\"name\":\"Aim\",\"value\":\"%d\",\"inline\":true},{\"name\":\"Bhop\",\"value\":\"%d\",\"inline\":true},{\"name\":\"Integrity\",\"value\":\"%d\",\"inline\":true},{\"name\":\"NoLerp\",\"value\":\"%d\",\"inline\":true},{\"name\":\"OSAC\",\"value\":\"%d\",\"inline\":true},{\"name\":\"Risk Score\",\"value\":\"**%d / 100**\",\"inline\":true}],\"footer\":{\"text\":\"L4D2 AntiCheat\"}}]}",
        safeAdminName, safePlayerName, safePlayerName, safeSteamId, aimScore, bhopScore, integrityScore, noLerpScore, osacScore, totalRisk
    );

    Discord_Post(json);
}
