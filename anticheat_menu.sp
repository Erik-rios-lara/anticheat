// anticheat_menu.sp - Interactive Admin Menu for L4D2 Anti-Cheat
#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <adminmenu>

TopMenu g_AdminTopMenu;

int g_MenuTarget[MAXPLAYERS+1];
int g_MenuListMap[MAXPLAYERS+1][11];

void Menu_Init()
{
    RegAdminCmd("sm_ac", Command_ACMenu, ADMFLAG_GENERIC, "Mostrar comandos cortos del AntiCheat");
    RegAdminCmd("sm_anticheat", Command_ACMenu, ADMFLAG_GENERIC, "Mostrar comandos del AntiCheat");
    // sm_admin is left to adminmenu.smx so the full native admin menu
    // (Kick/Ban/Slay/Votes/etc. from every plugin) stays available.
    // The anti-cheat menu is reachable via sm_ac / !admin chat trigger,
    // and is also added as a category inside the native menu below.

    // Support both load orders: adminmenu may already be running when this
    // plugin starts, so do not rely only on the ready forward.
    if (LibraryExists("adminmenu"))
    {
        TopMenu topmenu = GetAdminTopMenu();
        if (topmenu != null) OnAdminMenuReady(topmenu);
    }
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (client <= 0 || !IsClientInGame(client)) return Plugin_Continue;
    if (!CheckCommandAccess(client, "sm_admin", ADMFLAG_GENERIC, true)) return Plugin_Continue;

    char text[64];
    strcopy(text, sizeof(text), sArgs);
    StripQuotes(text);
    TrimString(text);

    if (StrEqual(text, "!admin", false) || StrEqual(text, "/admin", false))
    {
        Menu_ShowCommandList(client);
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

public void OnAdminMenuReady(Handle aTopMenu)
{
    TopMenu topmenu = TopMenu.FromHandle(aTopMenu);
    if (topmenu == g_AdminTopMenu) return;
    g_AdminTopMenu = topmenu;

    TopMenuObject playerCommands = topmenu.FindCategory(ADMINMENU_PLAYERCOMMANDS);
    if (playerCommands != INVALID_TOPMENUOBJECT)
    {
        topmenu.AddItem("ac_players", AdminMenu_AntiCheat, playerCommands,
            "sm_ac", ADMFLAG_GENERIC, "Anti-Cheat: jugadores");
    }

    TopMenuObject serverCommands = topmenu.FindCategory(ADMINMENU_SERVERCOMMANDS);
    if (serverCommands != INVALID_TOPMENUOBJECT)
    {
        topmenu.AddItem("ac_testdiscord", AdminMenu_AntiCheat, serverCommands,
            "sm_act", ADMFLAG_GENERIC, "Anti-Cheat: probar Discord");
        topmenu.AddItem("ac_reload", AdminMenu_AntiCheat, serverCommands,
            "sm_acr", ADMFLAG_GENERIC, "Anti-Cheat: recargar");
        topmenu.AddItem("ac_clearlog", AdminMenu_AntiCheat, serverCommands,
            "sm_acc", ADMFLAG_GENERIC, "Anti-Cheat: limpiar log");
    }
}

public void AdminMenu_AntiCheat(TopMenu topmenu, TopMenuAction action,
                                TopMenuObject topobj, int param,
                                char[] buffer, int maxlength)
{
    if (action == TopMenuAction_DisplayOption)
    {
        char info[64];
        topmenu.GetInfoString(topobj, info, sizeof(info));
        strcopy(buffer, maxlength, info);
    }
    else if (action == TopMenuAction_SelectOption)
    {
        char item[64];
        topmenu.GetInfoString(topobj, item, sizeof(item));
        if (StrContains(item, "jugadores") != -1)
            Menu_ShowPlayerList(param);
        else if (StrContains(item, "Discord") != -1)
            FakeClientCommand(param, "sm_act");
        else if (StrContains(item, "recargar") != -1)
            FakeClientCommand(param, "sm_acr");
        else if (StrContains(item, "limpiar") != -1)
            FakeClientCommand(param, "sm_acc");
    }
}

public Action Command_ACMenu(int client, int args)
{
    if (client == 0)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && !IsFakeClient(i))
            {
                client = i;
                break;
            }
        }
    }
    
    if (client == 0)
    {
        PrintToServer("[AntiCheat] No se encontro un jugador activo.");
        return Plugin_Handled;
    }

    Menu_ShowCommandList(client);
    return Plugin_Handled;
}

void Menu_ShowCommandList(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return;
    CancelClientMenu(client);
    Menu menu = new Menu(Menu_CommandListHandler);
    menu.SetTitle("Menu de Admin:");
    menu.AddItem("players", "Comandos de jugador");
    menu.AddItem("server", "Comandos de servidor");
    menu.AddItem("votes", "Comandos de votacion");
    menu.ExitButton = true;
    if (!menu.Display(client, 30))
    {
        LogError("[AntiCheat] No se pudo mostrar el menu al cliente %d.", client);
        delete menu;
    }
}

public int Menu_CommandListHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(param2, info, sizeof(info));
        if (StrEqual(info, "players")) Menu_ShowPlayerCommands(client);
        else if (StrEqual(info, "server")) Menu_ShowServerCommands(client);
        else if (StrEqual(info, "votes")) Menu_ShowVoteCommands(client);
    }
    else if (action == MenuAction_End) delete menu;
    return 0;
}

void Menu_ShowPlayerCommands(int client)
{
    Panel panel = new Panel();
    panel.SetTitle("Comandos de Jugador:");
    panel.DrawText(" ");
    panel.DrawText("sm_acv <jugador> - Ver riesgo");
    panel.DrawText("Desde la lista tambien puedes:");
    panel.DrawText("Kick, ban 1 hora o ban permanente");
    panel.DrawText(" ");
    panel.CurrentKey = 1;
    panel.DrawItem("Abrir lista de jugadores");
    panel.CurrentKey = 0;
    panel.DrawItem("Volver");
    panel.Send(client, Menu_PlayerCommandsHandler, 30);
    delete panel;
}

public int Menu_PlayerCommandsHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        if (param2 == 1) Menu_ShowPlayerList(client);
        else if (param2 == 0) Menu_ShowCommandList(client);
    }
    return 0;
}

void Menu_ShowServerCommands(int client)
{
    Panel panel = new Panel();
    panel.SetTitle("Comandos de Servidor:");
    panel.DrawText(" ");
    panel.CurrentKey = 1;
    panel.DrawItem("Probar Discord  (sm_act)");
    panel.CurrentKey = 2;
    panel.DrawItem("Recargar modulos (sm_acr)");
    panel.CurrentKey = 3;
    panel.DrawItem("Limpiar log     (sm_acc)");
    panel.CurrentKey = 0;
    panel.DrawItem("Volver");
    panel.Send(client, Menu_ServerCommandsHandler, 30);
    delete panel;
}

public int Menu_ServerCommandsHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        if (param2 == 1) Command_TestDiscord(client, 0);
        else if (param2 == 2) Command_Reload(client, 0);
        else if (param2 == 3) Command_ClearLog(client, 0);
        else if (param2 == 0) Menu_ShowCommandList(client);
    }
    return 0;
}

void Menu_ShowVoteCommands(int client)
{
    Panel panel = new Panel();
    panel.SetTitle("Comandos de Votacion:");
    panel.DrawText(" ");
    panel.DrawText("Este anti-cheat no tiene");
    panel.DrawText("comandos de votacion activos.");
    panel.DrawText(" ");
    panel.DrawText("Los baneos requieren autorizacion");
    panel.DrawText("del admin desde la lista.");
    panel.CurrentKey = 0;
    panel.DrawItem("Volver");
    panel.Send(client, Menu_VoteCommandsHandler, 30);
    delete panel;
}

public int Menu_VoteCommandsHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select && param2 == 0)
        Menu_ShowCommandList(client);
    return 0;
}

static int Menu_CalcRisk(int target)
{
    int a  = Aim_GetScore(target);
    int ta = TargetAcq_GetScore(target);
    if (ta > a) a = ta;
    int bh = Bhop_GetScore(target);
    int b2 = Bhop2_GetScore(target);
    if (b2 > bh) bh = b2;
    int ig = Integrity_GetScore(target);
    int nl = NoLerp_GetScore(target);
    int oc = OSAC_GetScore(target);
    float riskF = float(a) * WEIGHT_AIM
                + float(bh)* WEIGHT_BHOP
                + float(ig)* WEIGHT_INTEGRITY
                + float(nl)* WEIGHT_NOLERP
                + float(oc)* WEIGHT_OSAC;
    riskF *= Correlation_GetMultiplier(target);
    int risk = RoundFloat(riskF);
    return (risk > 100) ? 100 : risk;
}

void Menu_ShowPlayerList(int client)
{
    Panel panel = new Panel();
    panel.SetTitle("[AntiCheat] Jugadores activos:");
    panel.DrawText(" ");

    int itemCount = 1;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !g_PlayerActive[i]) continue;

        int risk = Menu_CalcRisk(i);
        char indicator[8];
        if      (risk >= SCORE_THRESHOLD_BAN) strcopy(indicator, sizeof(indicator), "[!!]");
        else if (risk >= SCORE_THRESHOLD_WARN) strcopy(indicator, sizeof(indicator), "[! ]");
        else if (risk >= SCORE_THRESHOLD_NOTE) strcopy(indicator, sizeof(indicator), "[~ ]");
        else                                   strcopy(indicator, sizeof(indicator), "[OK]");

        char playerName[MAX_NAME_LENGTH];
        GetClientName(i, playerName, sizeof(playerName));

        char display[96];
        FormatEx(display, sizeof(display), "%s %s (Rsg: %d)", indicator, playerName, risk);

        panel.DrawItem(display);
        g_MenuListMap[client][itemCount] = i;
        itemCount++;
        
        if (itemCount >= 9) break; 
    }

    if (itemCount == 1)
    {
        panel.DrawItem("(No hay jugadores activos)");
    }

    panel.DrawText(" ");
    panel.CurrentKey = 10;
    panel.DrawItem("Cerrar");

    panel.Send(client, Menu_PlayerListHandler, 30);
    delete panel;
}

public int Menu_PlayerListHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        if (param2 == 10) return 0;
        int target = g_MenuListMap[client][param2];
        if (target > 0 && target <= MaxClients && IsClientInGame(target))
        {
            Menu_ShowPlayerDetail(client, target);
        }
    }
    return 0;
}

void Menu_ShowPlayerDetail(int client, int target)
{
    g_MenuTarget[client] = target;
    int a  = Aim_GetScore(target);
    int taScore = TargetAcq_GetScore(target);
    if (taScore > a) a = taScore;
    int bh = Bhop_GetScore(target);
    int b2 = Bhop2_GetScore(target);
    if (b2 > bh) bh = b2;
    int ig = Integrity_GetScore(target);
    int nl = NoLerp_GetScore(target);
    int oc = OSAC_GetScore(target);
    int risk = Menu_CalcRisk(target);

    char playerName[MAX_NAME_LENGTH], steamId[32];
    GetClientName(target, playerName, sizeof(playerName));
    GetClientAuthId(target, AuthId_Steam2, steamId, sizeof(steamId));

    Panel panel = new Panel();
    char title[96];
    FormatEx(title, sizeof(title), "[AntiCheat] %s", playerName);
    panel.SetTitle(title);

    char line[72];
    FormatEx(line, sizeof(line), "SteamID: %s", steamId);
    panel.DrawText(line);
    FormatEx(line, sizeof(line), "Riesgo total: %d / 100  (vigilancia: nivel %d)", risk, g_SuspicionTier[target]);
    panel.DrawText(line);
    panel.DrawText("------------------------");
    FormatEx(line, sizeof(line), "Aim:       %3d", a);  panel.DrawText(line);
    FormatEx(line, sizeof(line), "Bhop:      %3d", bh); panel.DrawText(line);
    FormatEx(line, sizeof(line), "Integrity: %3d", ig); panel.DrawText(line);
    FormatEx(line, sizeof(line), "NoLerp:    %3d", nl); panel.DrawText(line);
    FormatEx(line, sizeof(line), "OSAC:      %3d", oc); panel.DrawText(line);

    int moduleScoresMenu[5];
    moduleScoresMenu[0] = a; moduleScoresMenu[1] = bh; moduleScoresMenu[2] = ig;
    moduleScoresMenu[3] = nl; moduleScoresMenu[4] = oc;
    int menuCorrDistinct;
    float menuCorrMult = Correlation_GetMultiplierEx(target, menuCorrDistinct);
    EvidenceReport menuEvidence;
    Evidence_Classify(risk, menuCorrMult, menuCorrDistinct, moduleScoresMenu, menuEvidence);
    char evDesc[64];
    Evidence_Describe(menuEvidence, evDesc, sizeof(evDesc));
    FormatEx(line, sizeof(line), "Evidencia: %s", evDesc);
    panel.DrawText(line);

    char corrDesc[64];
    if (Correlation_DescribeBestCluster(target, corrDesc, sizeof(corrDesc)))
    {
        FormatEx(line, sizeof(line), "Correlacion: %s", corrDesc);
        panel.DrawText(line);
    }
    panel.DrawText("------------------------");

    panel.CurrentKey = 1;
    panel.DrawItem("Expulsar (Kick)");
    panel.DrawItem("Banear 1 hora");
    panel.DrawItem("Banear permanente");
    panel.DrawItem("Volver a la lista");
    panel.DrawItem("Cerrar");

    panel.Send(client, Menu_PlayerDetailHandler, 30);
    delete panel;
}

public int Menu_PlayerDetailHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        int target = g_MenuTarget[client];
        if (!IsClientInGame(target))
        {
            PrintToChat(client, "[AntiCheat] El jugador ya no esta en el servidor.");
            return 0;
        }

        char name[MAX_NAME_LENGTH];
        GetClientName(target, name, sizeof(name));

        switch (param2)
        {
            case 1:
            {
                if (!CheckCommandAccess(client, "sm_kick", ADMFLAG_GENERIC, true))
                { PrintToChat(client, "[AntiCheat] No tienes permisos."); return 0; }
                PrintToChat(client, "[AntiCheat] Expulsaste a %s.", name);
                KickClient(target, "[AntiCheat] Expulsado por un administrador.");
            }
            case 2:
            {
                if (!CheckCommandAccess(client, "sm_ban", ADMFLAG_GENERIC, true))
                { PrintToChat(client, "[AntiCheat] No tienes permisos."); return 0; }
                PrintToChat(client, "[AntiCheat] Baneaste a %s por 1 hora.", name);
                BanClient(target, 60, BANFLAG_AUTO, "Baneado por comportamiento sospechoso.", "Ban 1 hora", "anticheat");
            }
            case 3:
            {
                if (!CheckCommandAccess(client, "sm_ban", ADMFLAG_GENERIC, true))
                { PrintToChat(client, "[AntiCheat] No tienes permisos."); return 0; }
                PrintToChat(client, "[AntiCheat] Baneaste PERMANENTEMENTE a %s.", name);
                BanClient(target, 0, BANFLAG_AUTO, "Baneado permanentemente.", "Ban permanente", "anticheat");
            }
            case 4: Menu_ShowPlayerList(client);
            case 5: return 0;
        }
    }
    return 0;
}
