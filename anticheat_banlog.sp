// anticheat_banlog.sp - Ban history recorder + Discord export for L4D2 Anti-Cheat
//
// SourceMod's native ban storage (banned_user.cfg / banned_ip.cfg) only
// keeps a SteamID and a duration - no name, no reason, no admin, no
// timestamp. That's not enough for a useful Discord report, so this module
// hooks OnBanClient (fired for every ban, regardless of source: this
// anti-cheat, sm_ban, voteban, or any other plugin) and keeps its own
// structured history in a local file, plus a Discord export command.
//
// Only bans applied AFTER this module is installed are recorded - there is
// no way to recover rich detail for bans that happened before it existed.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <ripext>

#define BANLOG_FILE "logs/anticheat/banlog.log"
#define BANLOG_MAX_DISCORD_ENTRIES 15

public Action OnBanClient(int client, int time, int flags, const char[] reason,
                          const char[] kick_message, const char[] command, any source)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Continue;

    char playerName[MAX_NAME_LENGTH];
    GetClientName(client, playerName, sizeof(playerName));

    char steamId[32];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

    char adminName[MAX_NAME_LENGTH];
    int adminIndex = view_as<int>(source);
    if (adminIndex > 0 && adminIndex <= MaxClients && IsClientInGame(adminIndex))
        GetClientName(adminIndex, adminName, sizeof(adminName));
    else
        strcopy(adminName, sizeof(adminName), StrEqual(command, "anticheat") ? "AntiCheat (auto)" : "Console/Unknown");

    char durationStr[32];
    if (time <= 0) strcopy(durationStr, sizeof(durationStr), "permanente");
    else FormatEx(durationStr, sizeof(durationStr), "%d min", time);

    char timestamp[64];
    FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S");

    // Pipe-delimited so it's easy to parse back for the Discord export.
    // Reason may not contain '|' - strip it defensively.
    char safeReason[256];
    strcopy(safeReason, sizeof(safeReason), reason);
    ReplaceString(safeReason, sizeof(safeReason), "|", "/");

    char line[512];
    FormatEx(line, sizeof(line), "%s|%s|%s|%s|%s|%s",
             timestamp, playerName, steamId, durationStr, adminName, safeReason);

    LogToFile(BANLOG_FILE, "%s", line);

    return Plugin_Continue;
}

// ------------------------------------------------------------------
// Fired for every RemoveBan() call (sm_unban and similar), regardless of
// which plugin triggered it. The target may no longer be connected, so we
// only have the identity string (SteamID or IP) - not a client index.
public Action OnRemoveBan(const char[] identity, int flags, const char[] command, any source)
{
    char adminName[MAX_NAME_LENGTH];
    int adminIndex = view_as<int>(source);
    if (adminIndex > 0 && adminIndex <= MaxClients && IsClientInGame(adminIndex))
        GetClientName(adminIndex, adminName, sizeof(adminName));
    else
        strcopy(adminName, sizeof(adminName), "Console/Unknown");

    char timestamp[64];
    FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S");

    char safeIdentity[64], safeAdmin[MAX_NAME_LENGTH];
    JsonEscapeSimple(identity, safeIdentity, sizeof(safeIdentity));
    JsonEscapeSimple(adminName, safeAdmin, sizeof(safeAdmin));

    LogToFile(BANLOG_FILE, "%s|UNBAN|%s|-|%s|-", timestamp, identity, adminName);

    char json[512];
    FormatEx(json, sizeof(json),
        "{\"embeds\":[{\"title\":\"[AntiCheat] Ban removido\",\"color\":3447003,\"fields\":[{\"name\":\"Identidad\",\"value\":\"%s\",\"inline\":true},{\"name\":\"Admin\",\"value\":\"%s\",\"inline\":true}],\"footer\":{\"text\":\"L4D2 AntiCheat\"}}]}",
        safeIdentity, safeAdmin);

    Discord_Post(json);
    return Plugin_Continue;
}

static void JsonEscapeSimple(const char[] input, char[] output, int maxlen)
{
    int out = 0;
    for (int i = 0; input[i] != '\0' && out < maxlen - 2; i++)
    {
        char c = input[i];
        if (c == '"' || c == '\\')
        {
            output[out++] = '\\';
            output[out++] = c;
        }
        else if (c >= 32)
        {
            output[out++] = c;
        }
    }
    output[out] = '\0';
}

// ------------------------------------------------------------------
// Reads the ban log file and sends up to BANLOG_MAX_DISCORD_ENTRIES of the
// most recent entries to Discord as a single embed.
public Action Command_BanHistory(int client, int args)
{
    char logPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, logPath, sizeof(logPath), "../../%s", BANLOG_FILE);

    File file = OpenFile(logPath, "r");
    if (file == null)
    {
        ReplyToCommand(client, "[AntiCheat] Aun no hay baneos registrados.");
        return Plugin_Handled;
    }

    // Read every line into a temporary array so we can take the most recent N.
    ArrayList lines = new ArrayList(ByteCountToCells(512));
    char buffer[512];
    while (!file.EndOfFile() && file.ReadLine(buffer, sizeof(buffer)))
    {
        int len = strlen(buffer);
        while (len > 0 && (buffer[len-1] == '\n' || buffer[len-1] == '\r'))
            buffer[--len] = '\0';
        if (len > 0) lines.PushString(buffer);
    }
    delete file;

    int total = lines.Length;
    if (total == 0)
    {
        delete lines;
        ReplyToCommand(client, "[AntiCheat] Aun no hay baneos registrados.");
        return Plugin_Handled;
    }

    int start = total > BANLOG_MAX_DISCORD_ENTRIES ? total - BANLOG_MAX_DISCORD_ENTRIES : 0;
    int shown = total - start;

    ReplyToCommand(client, "[AntiCheat] Enviando %d de %d baneos registrados a Discord...", shown, total);

    char fields[4096];
    fields[0] = '\0';
    int pos = 0;

    for (int i = start; i < total; i++)
    {
        char entry[512];
        lines.GetString(i, entry, sizeof(entry));

        char parts[6][256];
        ExplodeStringSafe(entry, "|", parts, 6, sizeof(parts[]));

        char fieldJson[700];
        FormatEx(fieldJson, sizeof(fieldJson),
            "%s{\"name\":\"%s - %s\",\"value\":\"SteamID: %s\\nDuracion: %s | Admin: %s\\nRazon: %s\",\"inline\":false}",
            (pos == 0 ? "" : ","), parts[1], parts[0], parts[2], parts[3], parts[4], parts[5]);

        int fieldLen = strlen(fieldJson);
        if (pos + fieldLen >= sizeof(fields) - 1) break;
        StrCat(fields, sizeof(fields), fieldJson);
        pos += fieldLen;
    }

    delete lines;

    char json[6000];
    FormatEx(json, sizeof(json),
        "{\"embeds\":[{\"title\":\"[AntiCheat] Historial de Baneos (ultimos %d de %d)\",\"color\":16711680,\"fields\":[%s],\"footer\":{\"text\":\"L4D2 AntiCheat\"}}]}",
        shown, total, fields);

    Discord_Post(json);
    return Plugin_Handled;
}

// Minimal fixed-count string split; SourceMod's ExplodeString needs an
// ArrayList, this avoids the allocation for a small, known field count.
static void ExplodeStringSafe(const char[] input, const char[] sep, char output[6][256], int maxParts, int maxLen)
{
    for (int i = 0; i < maxParts; i++) output[i][0] = '\0';

    int part = 0, outPos = 0;
    for (int i = 0; input[i] != '\0' && part < maxParts; i++)
    {
        if (input[i] == sep[0])
        {
            output[part][outPos] = '\0';
            part++;
            outPos = 0;
            continue;
        }
        if (outPos < maxLen - 1)
        {
            output[part][outPos++] = input[i];
        }
    }
    if (part < maxParts) output[part][outPos] = '\0';
}
