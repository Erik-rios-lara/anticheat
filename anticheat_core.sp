// anticheat_core.sp - entry point for the L4D2 anti-cheat system
// ---------------------------------------------------------------
// Registers hooks, dispatches data to the modular analyzers
// (aim, movement, fire, visibility), and runs a periodic scoring
// timer that combines all module scores and takes action.

#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

// Fired right before the anti-cheat kicks a player for confirmed high risk.
// Other plugins can hook this (via forward action:AntiCheat_OnCheatDetected(...)
// in their own code) and return Plugin_Handled to veto the kick - e.g. a
// separate allowlist plugin - without having to modify this code.
GlobalForward g_fwdOnCheatDetected;

// ------------------------------------------------------------------
// Constants & configuration
#define SCORE_INTERVAL        10.0   // seconds between risk evaluations (tier 0-2)
#define SCORE_TIMER_TICK       5.0   // timer fires this often; the interval gate
                                     // inside Timer_Score decides whether to act,
                                     // so tier 3 can evaluate at 5s and everyone
                                     // else stays at 10s without a second timer
#define SCORE_THRESHOLD_BAN   50     // risk >= this => auto-kick (see STRONG_MODULE_THRESHOLD below)
#define SCORE_THRESHOLD_WARN  35     // risk >= this => warn in chat
#define SCORE_THRESHOLD_NOTE  15     // risk >= this => note to admins
#define BAN_CONFIRMATIONS      3     // consecutive high-risk evaluations required
#define STRONG_MODULE_THRESHOLD 60   // a single module (Aim or Bhop) at/above this counts as sufficient evidence
#define LOG_FILE              "logs/anticheat/anticheat.log"

ConVar g_cvBanDuration;
ConVar g_cvAdminImmunity;

// Scoring weights (must sum to 1.0). Move, Fire, Recoil and WallHack
// detectors were removed. Integrity, NoLerp and OSAC are all near-zero
// false-positive by construction (each is a "logic breach" style check),
// so they carry real weight despite being small slices - when any of them
// fires at all, it's meaningful. Bhop2 is a second independent bhop
// detector; its score folds into the Bhop slot (max of the two) rather
// than getting its own weight.
#define WEIGHT_AIM        0.42
#define WEIGHT_BHOP        0.22
#define WEIGHT_INTEGRITY   0.11
#define WEIGHT_NOLERP      0.10
#define WEIGHT_OSAC        0.15

// ------------------------------------------------------------------
// Per-player data
bool   g_PlayerActive[MAXPLAYERS+1];
float  g_LastScoreTime[MAXPLAYERS+1];
Handle g_ScoreTimer[MAXPLAYERS+1];
int    g_HighRiskStreak[MAXPLAYERS+1];
float  g_LastDiscordBotAlert[MAXPLAYERS+1];
#define DISCORDBOT_ALERT_COOLDOWN 60.0

// ------------------------------------------------------------------
// Tiered detection - the cheap checks always run; the expensive
// target-relative ones (Aimlock, TriggerBot) only wake up once a player
// has already produced some evidence with the cheap checks. A clean
// player never pays for the heavy scans. The tier climbs fast on evidence
// and decays slowly (one level per DECAY window with no new evidence).
//
//  0  normal      - cheap checks only, zero per-tick target scans
//  1  watched     - Aimlock/TriggerBot sampled every 4th tick
//  2  suspicious  - Aimlock/TriggerBot sampled every 2nd tick
//  3  high        - Aimlock/TriggerBot every tick, risk evaluated 2x as often
int    g_SuspicionTier[MAXPLAYERS+1];
float  g_TierLastEvidence[MAXPLAYERS+1];   // last time this player produced any score
#define TIER_DECAY_SECONDS 120.0           // no new evidence for this long => drop one tier
#define TIER1_RISK 15
#define TIER2_RISK 30
#define TIER3_RISK 50
#define TIER2_MODULE 40
#define TIER3_MODULE 60

// ------------------------------------------------------------------
// Shared per-frame cache of live Special Infected. The aim/OSAC detectors
// each used to loop all client slots every tick to find the nearest
// Special; now it's built ONCE per game frame and both read it. This is
// the main hot-path optimization - during a horde with several Specials
// up and the player firing, those per-tick scans were the lag source.
int   g_SpecialCache[MAXPLAYERS+1];   // client indices of live Special Infected
int   g_SpecialCacheCount;
int   g_SpecialCacheFrame = -1;       // frame number this cache was built on

// Rebuild the cache if it's stale (not already done this frame).
void AC_RefreshSpecialCache()
{
    int frame = GetGameTickCount();
    if (frame == g_SpecialCacheFrame) return;
    g_SpecialCacheFrame = frame;

    g_SpecialCacheCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (GetClientTeam(i) != 3) continue;
        if (!IsPlayerAlive(i)) continue;
        int zc = GetEntProp(i, Prop_Send, "m_zombieClass");
        if (zc < 1 || zc > 8) continue;
        g_SpecialCache[g_SpecialCacheCount++] = i;
    }
}


// ------------------------------------------------------------------
// Include sub-modules directly
#include "anticheat_correlation.sp"
#include "anticheat_evidence.sp"
#include "anticheat_aim.sp"
#include "anticheat_targetacq.sp"
#include "anticheat_variance.sp"
#include "anticheat_shotdecision.sp"
#include "anticheat_bhop.sp"
#include "anticheat_bhop2.sp"
#include "anticheat_integrity.sp"
#include "anticheat_nolerp.sp"
#include "anticheat_osac.sp"
#include "anticheat_discord.sp"
#include "anticheat_menu.sp"
#include "anticheat_banlog.sp"
#include "anticheat_discordbot.sp"

// ------------------------------------------------------------------
// Helper: log to file
static void AC_Log(const char[] fmt, any ...)
{
    char buffer[512];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogToFile(LOG_FILE, "%s", buffer);
}

// Helper: chat message to admins only (flag 'generic' or higher). Regular
// players never see anti-cheat suspicion/warning chatter - it's noise to
// them and it tips off a cheater. Detections still go to the log, Discord,
// and the in-game admin menu.
void AC_NotifyAdmins(const char[] fmt, any ...)
{
    char buffer[512];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        if (!CheckCommandAccess(i, "sm_ac_view", ADMFLAG_GENERIC, false)) continue;
        PrintToChat(i, "%s", buffer);
    }
}

static bool AC_ConnectionUnstable(int client)
{
    // Do not interpret delayed/choked commands as cheating evidence.
    return GetClientAvgLoss(client, NetFlow_Incoming) > 0.20
        || GetClientAvgChoke(client, NetFlow_Incoming) > 0.30
        || GetClientAvgLatency(client, NetFlow_Incoming) > 0.50;
}

// ------------------------------------------------------------------
// Plugin entry point
public void OnPluginStart()
{
    LoadTranslations("common.phrases");

    // LogToFile does not create intermediate directories; without this the
    // log path silently fails to write and error responses (including
    // Discord HTTP failures) are lost.
    char logDir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, logDir, sizeof(logDir), "logs/anticheat");
    if (!DirExists(logDir)) CreateDirectory(logDir, 511);

    g_fwdOnCheatDetected = new GlobalForward("AntiCheat_OnCheatDetected", ET_Event, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell);

    RegAdminCmd("sm_ac_view",     Command_ViewPlayer, ADMFLAG_GENERIC, "View anti-cheat data for a player");
    RegAdminCmd("sm_ac_reload",   Command_Reload,     ADMFLAG_GENERIC, "Reload anti-cheat modules");
    RegAdminCmd("sm_ac_clearlog", Command_ClearLog,   ADMFLAG_GENERIC, "Clear anti-cheat log file");
    RegAdminCmd("sm_testdiscord", Command_TestDiscord, ADMFLAG_GENERIC, "Test Discord Webhook");
    RegAdminCmd("sm_ac_banhistory", Command_BanHistory, ADMFLAG_BAN, "Send recent ban history to Discord");
    RegAdminCmd("sm_acbh", Command_BanHistory, ADMFLAG_BAN, "Send recent ban history to Discord");
    // Short aliases for daily administration.
    RegAdminCmd("sm_acv", Command_ViewPlayer,  ADMFLAG_GENERIC, "View anti-cheat data: sm_acv <player>");
    RegAdminCmd("sm_acr", Command_Reload,      ADMFLAG_GENERIC, "Reload anti-cheat modules");
    RegAdminCmd("sm_acc", Command_ClearLog,    ADMFLAG_GENERIC, "Clear anti-cheat log");
    RegAdminCmd("sm_act", Command_TestDiscord, ADMFLAG_GENERIC, "Test Discord webhook");
    // Direct command names are also registered for chat-trigger setups that
    // do not automatically prepend the sm_ prefix.
    RegAdminCmd("act", Command_TestDiscord, ADMFLAG_GENERIC, "Test Discord webhook");
    RegAdminCmd("acv", Command_ViewPlayer, ADMFLAG_GENERIC, "View anti-cheat data: acv <player>");
    RegAdminCmd("acr", Command_Reload, ADMFLAG_GENERIC, "Reload anti-cheat modules");
    RegAdminCmd("acc", Command_ClearLog, ADMFLAG_GENERIC, "Clear anti-cheat log");

    g_cvBanDuration = CreateConVar("sm_ac_ban_duration", "60", "Auto-ban duration in minutes (0 = permanent)", FCVAR_NOTIFY);
    g_cvAdminImmunity = CreateConVar("sm_ac_admin_immunity", "1", "Protect admins from auto-bans (1=Yes, 0=No)", FCVAR_NOTIFY);
    Discord_Init();
    Menu_Init();
    DiscordBot_Init();

    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    HookEvent("round_start",  Event_RoundStart,  EventHookMode_Post);
    HookEvent("round_end",    Event_RoundEnd,    EventHookMode_Post);

    // TraceAttack must be hooked on the VICTIM entity, not the attacker -
    // that's how SDKHooks exposes this callback on L4D2. Special Infected
    // occupy a client slot (even when AI-controlled), so hook every
    // Infected-team client already in game; player_spawn re-hooks them
    // whenever they respawn as a (possibly different) infected class.
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 3)
            SDKHook(i, SDKHook_TraceAttack, Hook_TraceAttack);
    }

    AC_Log("[AntiCheat] Plugin started - version 2.0");
    PrintToServer("[AntiCheat] Core plugin loaded - hooks registered.");

    // Initialize players already in the server (handles plugin reloads)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            g_PlayerActive[i] = true;
            g_HighRiskStreak[i] = 0;
            g_SuspicionTier[i] = 0;
            g_TierLastEvidence[i] = GetGameTime();
            g_LastScoreTime[i] = GetGameTime();
            Aim_Init(i);
            Bhop_Init(i);
            Bhop2_Init(i);
            Integrity_Init(i);
            NoLerp_Init(i);
            OSAC_Init(i);
            Correlation_Init(i);
            TargetAcq_Init(i);
            Variance_Init(i);
            ShotDecision_Init(i);
            g_ScoreTimer[i] = CreateTimer(SCORE_TIMER_TICK, Timer_Score, i, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        }
    }
}

// ------------------------------------------------------------------
public void OnClientPutInServer(int client)
{
    if (client <= 0 || client > MaxClients) return;
    if (IsFakeClient(client)) return;

    g_PlayerActive[client] = true;
    g_HighRiskStreak[client] = 0;
    g_SuspicionTier[client] = 0;
    g_TierLastEvidence[client] = GetGameTime();
    g_LastScoreTime[client] = GetGameTime();

    g_ScoreTimer[client] = CreateTimer(SCORE_TIMER_TICK, Timer_Score, client, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    

    Aim_Init(client);
    Bhop_Init(client);
    Bhop2_Init(client);
    Integrity_Init(client);
    NoLerp_Init(client);
    OSAC_Init(client);
    Correlation_Init(client);
    TargetAcq_Init(client);
    Variance_Init(client);
    ShotDecision_Init(client);

    AC_Log("[AntiCheat] Player %N (%d) connected", client, client);
}

// ------------------------------------------------------------------
public void OnClientDisconnect(int client)
{
    g_PlayerActive[client] = false;
    g_HighRiskStreak[client] = 0;
    g_SuspicionTier[client] = 0;

    if (g_ScoreTimer[client] != null)
    {
        KillTimer(g_ScoreTimer[client]);
        g_ScoreTimer[client] = null;
    }
    NoLerp_Shutdown(client);

    Bhop_Init(client);
    AC_Log("[AntiCheat] Player %N disconnected", client);
}

// ------------------------------------------------------------------
// Per-tick hook: captures bhop timing every frame
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse,
                             float vel[3], float angles[3],
                             int &weapon, int &subtype,
                             int &cmdnum, int &tickcount, int &seed,
                             int mouse[2])
{
    if (GetClientTeam(client) != 2) return Plugin_Continue;
    if (!g_PlayerActive[client]) return Plugin_Continue;

    // --- Cheap checks: always run, every tick. No per-client scans, just
    // arithmetic on values already in hand. ---
    Aim_RecordAngleCheap(client, angles, buttons, cmdnum);
    Bhop_RecordTick(client, buttons, angles);
    Bhop2_RecordTick(client, buttons);
    Integrity_RecordTick(client, angles, buttons, cmdnum, tickcount);
    OSAC_RecordTick(client, angles);
    Variance_RecordBhopTick(client, buttons); // cheap, no per-client scan - profiles jump timing distribution

    // --- Expensive target-relative checks (Aimlock, TriggerBot, Target
    // Acquisition): only for players the cheap checks have already
    // flagged (tier >= 1). A clean player never triggers the per-frame
    // Special-Infected scan at all. ---
    int tier = g_SuspicionTier[client];
    if (tier >= 1)
    {
        AC_RefreshSpecialCache();
        if (g_SpecialCacheCount > 0)
        {
            // Sample rate by tier: tier1 every 4th tick, tier2 every 2nd,
            // tier3 every tick.
            int mask = (tier >= 3) ? 0 : ((tier == 2) ? 1 : 3);
            if ((GetGameTickCount() & mask) == 0)
            {
                Aim_CheckAimlockThrottled(client, angles);
                if (buttons & IN_ATTACK) Aim_RunTriggerCheck(client);
            }

            // Target Acquisition needs every tick of a session's
            // trajectory to measure timing/monotonicity correctly - it
            // is not throttled like the two checks above, but it is
            // still gated behind tier >= 1, so a clean player never pays
            // for it either.
            TargetAcq_RecordTick(client, angles, (buttons & IN_ATTACK) != 0);

            // Angular velocity variance profiling - same per-encounter
            // trajectory requirement as Target Acquisition, so it shares
            // the same lack of throttling and the same tier gate.
            Variance_RecordAimTick(client, angles);
        }
    }

    return Plugin_Continue;
}

// ------------------------------------------------------------------
// SDKHook: TraceAttack - fires before damage is applied, carries the
// hitgroup (headshot detection) that OnTakeDamage does not expose.
public Action Hook_TraceAttack(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
    if (victim <= 0 || !IsValidEntity(victim)) return Plugin_Continue;
    if (victim == attacker) return Plugin_Continue;
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return Plugin_Continue;
    if (GetClientTeam(attacker) != 2) return Plugin_Continue;
    if (!g_PlayerActive[attacker]) return Plugin_Continue;
    Aim_RecordShot(attacker, victim, hitgroup);

    float attackerAngles[3];
    GetClientEyeAngles(attacker, attackerAngles);
    OSAC_RecordShot(attacker, victim, hitgroup, attackerAngles);

    // Shot Decision Analysis: correlate this shot's context (weapon,
    // range) against the acquisition time TargetAcq measured for the
    // session that led to it, if any.
    float attackerPos[3], victimPos[3];
    GetClientAbsOrigin(attacker, attackerPos);
    GetClientAbsOrigin(victim, victimPos);
    float range = GetVectorDistance(attackerPos, victimPos);
    float decisionTimeMs = TargetAcq_GetRecentDecisionTimeMs(attacker, victim);
    ShotDecision_RecordShot(attacker, victim, hitgroup, decisionTimeMs, range);

    return Plugin_Continue;
}

// ------------------------------------------------------------------
// Periodic scoring timer
public Action Timer_Score(Handle timer, any client)
{
    if (!g_PlayerActive[client] || !IsClientInGame(client))
    {
        if (g_ScoreTimer[client] == timer) g_ScoreTimer[client] = null;
        return Plugin_Stop;
    }
    if (!IsClientAuthorized(client))
    {
        g_HighRiskStreak[client] = 0;
        g_LastScoreTime[client] = GetGameTime();
        return Plugin_Continue;
    }

    float now = GetGameTime();
    // Tier 3 players are re-evaluated twice as often (5s vs 10s) so a
    // confirmed cheater gets to the kick threshold faster.
    float interval = (g_SuspicionTier[client] >= 3) ? (SCORE_INTERVAL * 0.5) : SCORE_INTERVAL;
    if (now - g_LastScoreTime[client] < interval) return Plugin_Continue;
    if (AC_ConnectionUnstable(client))
    {
        g_HighRiskStreak[client] = 0;
        g_LastScoreTime[client] = now;
        AC_Log("[Risk] %N evaluation skipped because connection is unstable.", client);
        return Plugin_Continue;
    }

    int aimScore    = Aim_GetScore(client);
    int targetAcqScore = TargetAcq_GetScore(client);
    if (targetAcqScore > aimScore) aimScore = targetAcqScore; // independent aim-side signal, take the worst
    int aimVarScore = Variance_GetAimScore(client);
    if (aimVarScore > aimScore) aimScore = aimVarScore; // per-player angular-velocity consistency profile
    int shotDecisionScore = ShotDecision_GetScore(client);
    if (shotDecisionScore > aimScore) aimScore = shotDecisionScore; // context-blind shot timing profile
    int bhopScore   = Bhop_GetScore(client);
    int bhop2Score  = Bhop2_GetScore(client);
    if (bhop2Score > bhopScore) bhopScore = bhop2Score; // two independent bhop detectors, take the worst
    int bhopVarScore = Variance_GetBhopScore(client);
    if (bhopVarScore > bhopScore) bhopScore = bhopVarScore; // per-player jump-timing consistency profile
    int integrityScore = Integrity_GetScore(client);
    int noLerpScore = NoLerp_GetScore(client);
    int osacScore   = OSAC_GetScore(client);

    float risk = float(aimScore) * WEIGHT_AIM
               + float(bhopScore) * WEIGHT_BHOP
               + float(integrityScore) * WEIGHT_INTEGRITY
               + float(noLerpScore) * WEIGHT_NOLERP
               + float(osacScore) * WEIGHT_OSAC;

    // --- Cross-Detector Correlation ---
    // The weighted sum above treats "one module mildly suspicious" and
    // "several independent modules firing in the same instant" as
    // differing only by magnitude. Correlation_GetMultiplier() looks at
    // the raw events each detector already reported (see
    // Correlation_ReportEvent call sites) and returns >1.0 only when
    // multiple DISTINCT detectors clustered within a short window - i.e.
    // when this isn't one noisy module, but a chain like snap -> perfect
    // acquisition -> shot -> clean impact lighting up several modules at
    // once. It amplifies existing risk; it cannot manufacture risk out of
    // an all-zero baseline (1.0x on 0 is still 0).
    float corrMult = Correlation_GetMultiplier(client);
    risk *= corrMult;

    int totalRisk = RoundFloat(risk);
    if (totalRisk > 100) totalRisk = 100;

    // --- Tiered Evidence Model ---
    // Classify this evaluation's output into one of four evidence levels
    // (INFO / STATISTICAL / CORRELATED / VIOLATION), and separate the
    // blended totalRisk into its four underlying dimensions: RiskScore,
    // Confidence, Severity, EvidenceCount. This doesn't change any
    // module's math or the totalRisk value itself - it classifies the
    // SAME numbers the action logic below already uses, so an admin (or
    // this code) can reason about WHY a risk value means what it means
    // instead of comparing a single blended integer against magic
    // thresholds with no further context.
    int corrDistinct;
    corrMult = Correlation_GetMultiplierEx(client, corrDistinct); // re-derive with the distinct count exposed
    int moduleScoresForEvidence[5];
    moduleScoresForEvidence[0] = aimScore;
    moduleScoresForEvidence[1] = bhopScore;
    moduleScoresForEvidence[2] = integrityScore;
    moduleScoresForEvidence[3] = noLerpScore;
    moduleScoresForEvidence[4] = osacScore;

    EvidenceReport evidence;
    Evidence_Classify(totalRisk, corrMult, corrDistinct, moduleScoresForEvidence, evidence);

    // Only log/print evaluations that clear the admin-notice threshold.
    // Below that, no module has produced real evidence yet - it's just
    // partial tendencies (a jump ratio creeping up, a couple of angle
    // samples) that never amount to anything and were drowning the log in
    // noise every 5-10 seconds for every player, every game.
    if (totalRisk >= SCORE_THRESHOLD_NOTE)
    {
        char evDesc[128];
        Evidence_Describe(evidence, evDesc, sizeof(evDesc));

        AC_Log("[Risk] %N - Aim:%d Bhop:%d Integrity:%d NoLerp:%d OSAC:%d => Risk %d (tier %d, corr x%.2f) [%s]",
               client, aimScore, bhopScore, integrityScore, noLerpScore, osacScore, totalRisk, g_SuspicionTier[client], corrMult, evDesc);
        PrintToServer("[AntiCheat] Client %N - Aim:%d Bhop:%d Integrity:%d NoLerp:%d OSAC:%d => Risk:%d (tier %d, corr x%.2f) [%s]",
                      client, aimScore, bhopScore, integrityScore, noLerpScore, osacScore, totalRisk, g_SuspicionTier[client], corrMult, evDesc);

        if (corrMult > 1.0)
        {
            char corrDesc[256];
            if (Correlation_DescribeBestCluster(client, corrDesc, sizeof(corrDesc)))
            {
                AC_Log("[Correlation] %N - %s", client, corrDesc);
            }
        }
    }

    // --- Update suspicion tier ---
    // The tier decides which expensive per-tick checks run (see
    // OnPlayerRunCmd). It climbs immediately when evidence appears and
    // decays one level per TIER_DECAY_SECONDS of no new evidence.
    int maxModule = aimScore;
    if (bhopScore > maxModule) maxModule = bhopScore;
    if (integrityScore > maxModule) maxModule = integrityScore;
    if (noLerpScore > maxModule) maxModule = noLerpScore;
    if (osacScore > maxModule) maxModule = osacScore;

    int wantTier = 0;
    if (totalRisk >= TIER1_RISK || maxModule >= TIER1_RISK) wantTier = 1;
    if (totalRisk >= TIER2_RISK || maxModule >= TIER2_MODULE) wantTier = 2;
    if (totalRisk >= TIER3_RISK || maxModule >= TIER3_MODULE) wantTier = 3;

    if (wantTier > g_SuspicionTier[client])
    {
        g_SuspicionTier[client] = wantTier;
        g_TierLastEvidence[client] = now;
        AC_Log("[Tier] %N raised to tier %d.", client, wantTier);
    }
    else if (wantTier >= g_SuspicionTier[client])
    {
        // Still producing evidence at the current tier - refresh the clock.
        g_TierLastEvidence[client] = now;
    }
    else if (g_SuspicionTier[client] > 0 && now - g_TierLastEvidence[client] >= TIER_DECAY_SECONDS)
    {
        g_SuspicionTier[client]--;
        g_TierLastEvidence[client] = now;
        AC_Log("[Tier] %N decayed to tier %d (clean for %.0fs).", client, g_SuspicionTier[client], TIER_DECAY_SECONDS);
    }

    // Interactive Discord alert (Kick/Ban buttons) for anyone showing real
    // evidence. Cooldown per player so a sustained detection doesn't spam a
    // new message every 10 seconds while the player stays connected.
    if (totalRisk >= SCORE_THRESHOLD_NOTE
        && now - g_LastDiscordBotAlert[client] >= DISCORDBOT_ALERT_COOLDOWN)
    {
        DiscordBot_SendAlert(client, aimScore, bhopScore, integrityScore, noLerpScore, osacScore, totalRisk);
        g_LastDiscordBotAlert[client] = now;
    }

    // NOTE: on a LISTEN server (not dedicated), SourceMod's core hardcodes
    // client index 1 (almost always the host) to always pass
    // CheckCommandAccess, regardless of admins_simple.ini. This means the
    // listen-server host is unbannable by this check no matter what - it is
    // not a bug in this plugin. On a real dedicated server this rule does
    // not apply and immunity works exactly as configured.
    bool isImmune = false;
    if (g_cvAdminImmunity.BoolValue && CheckCommandAccess(client, "sm_ac_immunity", ADMFLAG_GENERIC, true))
    {
        isImmune = true;
    }

    if (totalRisk >= SCORE_THRESHOLD_BAN)
    {
        // Player is already being kicked/disconnected - don't double-process
        // (e.g. a race between two consecutive timer ticks).
        if (IsClientInKickQueue(client))
        {
            g_LastScoreTime[client] = now;
            return Plugin_Continue;
        }

        int moduleScores[5];
        moduleScores[0] = aimScore;
        moduleScores[1] = bhopScore;
        moduleScores[2] = integrityScore;
        moduleScores[3] = noLerpScore;
        moduleScores[4] = osacScore;
        bool hasStrongModule = false;
        for (int i = 0; i < sizeof(moduleScores); i++)
        {
            if (moduleScores[i] >= STRONG_MODULE_THRESHOLD) hasStrongModule = true;
        }

        // Each module's own internal gating already requires sustained,
        // specific evidence before it produces any score at all, so one
        // module at STRONG_MODULE_THRESHOLD is sufficient on its own.
        if (!hasStrongModule)
        {
            g_HighRiskStreak[client] = 0;
            AC_Log("[ACTION] %N risk %d ignored for auto-kick: insufficient independent evidence.", client, totalRisk);
            g_LastScoreTime[client] = now;
            return Plugin_Continue;
        }

        g_HighRiskStreak[client]++;
        // VIOLATION-level evidence (a logic-breach module - Integrity,
        // NoLerp, or OSAC's BoneLock/SilentAim/SpinBot - firing hard on
        // its own) is near-certain by construction: it's a state a
        // legitimate client structurally cannot produce, not a repeatable
        // behavioral tendency that could be a run of bad luck. Requiring
        // it to persist across 3 separate 5-10s evaluations only delays
        // an already-confirmed case. STATISTICAL and CORRELATED evidence
        // still require the full confirmation streak, unchanged.
        int confirmationsNeeded = (evidence.Level == EVLEVEL_VIOLATION) ? 1 : BAN_CONFIRMATIONS;
        if (g_HighRiskStreak[client] < confirmationsNeeded)
        {
            char evLevelName[16];
            Evidence_LevelName(evidence.Level, evLevelName, sizeof(evLevelName));
            AC_Log("[ACTION] %N high risk %d; confirmation %d/%d (%s)", client, totalRisk, g_HighRiskStreak[client], confirmationsNeeded, evLevelName);
            g_LastScoreTime[client] = now;
            return Plugin_Continue;
        }

        if (isImmune)
        {
            AC_Log("[IMMUNITY] Admin %N bypassed auto-kick (risk %d).", client, totalRisk);
        }
        else
        {
            // Give other plugins (e.g. a separate allowlist) a chance to
            // veto this specific kick without having to modify this file.
            Action result = Plugin_Continue;
            Call_StartForward(g_fwdOnCheatDetected);
            Call_PushCell(client);
            Call_PushCell(totalRisk);
            Call_PushCell(aimScore);
            Call_PushCell(0); // whScore - WallHack module removed, kept for signature stability
            Call_PushCell(bhopScore);
            Call_Finish(result);

            if (result == Plugin_Handled || result == Plugin_Stop)
            {
                AC_Log("[ACTION] %N risk %d kick vetoed by another plugin.", client, totalRisk);
                g_HighRiskStreak[client] = 0;
                g_LastScoreTime[client] = now;
                return Plugin_Continue;
            }

            char playerName[MAX_NAME_LENGTH];
            GetClientName(client, playerName, sizeof(playerName));
            AC_Log("[ACTION] *** KICKING %s (risk %d) ***", playerName, totalRisk);
            AC_NotifyAdmins("[AntiCheat] %N expulsado por riesgo muy alto (%d).", client, totalRisk);
            KickClient(client, "Expulsado por comportamiento sospechoso (AntiCheat).");
            Discord_SendRiskAlert(client, aimScore, bhopScore, integrityScore, noLerpScore, osacScore, totalRisk, "KICK");
            g_ScoreTimer[client] = null;
            return Plugin_Stop;
        }
    }
    else if (totalRisk >= SCORE_THRESHOLD_WARN)
    {
        g_HighRiskStreak[client] = 0;
        if (isImmune)
        {
            AC_Log("[IMMUNITY] Admin %N bypassed auto-warn (risk %d).", client, totalRisk);
        }
        else
        {
            AC_Log("[ACTION] %N muestra comportamiento MUY sospechoso (%d).", client, totalRisk);
        }
    }
    else if (totalRisk >= SCORE_THRESHOLD_NOTE)
    {
        g_HighRiskStreak[client] = 0;
        AC_Log("[ACTION] %N muestra comportamiento sospechoso (%d).", client, totalRisk);
    }
    else
    {
        g_HighRiskStreak[client] = 0;
    }

    g_LastScoreTime[client] = now;
    return Plugin_Continue;
}

// ------------------------------------------------------------------
// Admin commands
public Action Command_ViewPlayer(int client, int args)
{
    if (args < 1) { ReplyToCommand(client, "Usage: sm_ac_view <#userid|name>"); return Plugin_Handled; }
    char target[64];
    GetCmdArg(1, target, sizeof(target));
    int targetId = FindTarget(client, target, true, false);
    if (targetId <= 0) return Plugin_Handled;
    if (!g_PlayerActive[targetId]) { ReplyToCommand(client, "[AntiCheat] Player not active."); return Plugin_Handled; }

    int a = Aim_GetScore(targetId);
    int ta = TargetAcq_GetScore(targetId);
    if (ta > a) a = ta;
    int bh = Bhop_GetScore(targetId);
    int b2 = Bhop2_GetScore(targetId);
    if (b2 > bh) bh = b2;
    int ig = Integrity_GetScore(targetId);
    int nl = NoLerp_GetScore(targetId);
    int oc = OSAC_GetScore(targetId);
    float risk = float(a)*WEIGHT_AIM + float(bh)*WEIGHT_BHOP + float(ig)*WEIGHT_INTEGRITY + float(nl)*WEIGHT_NOLERP + float(oc)*WEIGHT_OSAC;
    int corrDistinct;
    float corrMult = Correlation_GetMultiplierEx(targetId, corrDistinct);
    risk *= corrMult;
    int totalRisk = RoundFloat(risk);
    if (totalRisk > 100) totalRisk = 100;
    ReplyToCommand(client, "[AntiCheat] %N - Aim:%d Bhop:%d Integrity:%d NoLerp:%d OSAC:%d => Risk:%d (corr x%.2f)", targetId, a, bh, ig, nl, oc, totalRisk, corrMult);

    int moduleScoresView[5];
    moduleScoresView[0] = a; moduleScoresView[1] = bh; moduleScoresView[2] = ig;
    moduleScoresView[3] = nl; moduleScoresView[4] = oc;
    EvidenceReport viewEvidence;
    Evidence_Classify(totalRisk, corrMult, corrDistinct, moduleScoresView, viewEvidence);
    char evDesc[128];
    Evidence_Describe(viewEvidence, evDesc, sizeof(evDesc));
    ReplyToCommand(client, "[AntiCheat] Evidencia: %s", evDesc);

    char corrDesc[256];
    if (Correlation_DescribeBestCluster(targetId, corrDesc, sizeof(corrDesc)))
    {
        ReplyToCommand(client, "[AntiCheat] Correlacion: %s", corrDesc);
    }

    Discord_SendAdminQuery(client, targetId, a, bh, ig, nl, oc, totalRisk);
    return Plugin_Handled;
}

public Action Command_Reload(int client, int args)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !g_PlayerActive[i]) continue;
        Aim_Init(i);
        Bhop_Init(i);
        Bhop2_Init(i);
        Integrity_Init(i);
        OSAC_Init(i);
        Correlation_Init(i);
        TargetAcq_Init(i);
        Variance_Init(i);
        ShotDecision_Init(i);
        g_HighRiskStreak[i] = 0;
        g_SuspicionTier[i] = 0;
        g_TierLastEvidence[i] = GetGameTime();
        g_LastScoreTime[i] = GetGameTime();
    }
    AC_Log("[AntiCheat] Detection modules reloaded by admin.");
    ReplyToCommand(client, "[AntiCheat] Modulos recargados correctamente.");
    return Plugin_Handled;
}
public Action Command_ClearLog(int client, int args)
{
    // LogToFile writes relative to the game root (left4dead2/), not
    // addons/sourcemod/ - BuildPath(Path_SM, ...) resolves the wrong file.
    char logPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, logPath, sizeof(logPath), "../../%s", LOG_FILE);
    DeleteFile(logPath);
    ReplyToCommand(client, "[AntiCheat] Log cleared.");
    return Plugin_Handled;
}

// ------------------------------------------------------------------
// Event hooks
public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) return Plugin_Continue;

    // Re-hook TraceAttack on every spawn: Special Infected (human or
    // AI-controlled - both occupy a client slot) get a fresh entity index
    // each time they respawn as a new infected class, so the hook must be
    // re-applied every time, not just once on connect.
    if (GetClientTeam(client) == 3)
    {
        SDKHook(client, SDKHook_TraceAttack, Hook_TraceAttack);
    }

    // The timer is created once on connect. Do not create one per spawn.
    return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return Plugin_Continue;
    if (victim < 1 || victim > MaxClients) return Plugin_Continue;
    if (GetClientTeam(attacker) != 2) return Plugin_Continue;
    if (!g_PlayerActive[attacker]) return Plugin_Continue;

    bool headshot = event.GetBool("headshot");
    OSAC_NoteKill(attacker, victim, headshot);
    return Plugin_Continue;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && g_PlayerActive[i])
        { Aim_Init(i); Bhop_Init(i); Bhop2_Init(i); Integrity_Init(i); OSAC_Init(i); TargetAcq_Init(i); Variance_Init(i); ShotDecision_Init(i); }
    }
    PrintToServer("[AntiCheat] Round start - module data reset.");
    return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) { return Plugin_Continue; }
public Action Command_TestDiscord(int client, int args)
{
    // ReplyToCommand (not PrintToChat) so this also works when run from the
    // server console, where client is 0 - PrintToChat requires a real player.
    ReplyToCommand(client, "[AntiCheat] Sending Test payload to Discord...");
    char json[512] = "{\"embeds\":[{\"title\":\"[AntiCheat] Test Webhook\",\"color\":16776960,\"description\":\"Prueba de conexion exitosa.\"}]}";

    char webhookURL[1024];
    g_cvWebhookURL.GetString(webhookURL, sizeof(webhookURL));

    if (strlen(webhookURL) < 10)
    {
        ReplyToCommand(client, "Error: configura sm_ac_discord_webhook en cfg/sourcemod/anticheat.cfg.");
        return Plugin_Handled;
    }

    Discord_Post(json);
    ReplyToCommand(client, "Request sent.");
    return Plugin_Handled;
}

// ------------------------------------------------------------------
public void OnPluginEnd()
{
    // Restore gravity for anyone currently caught in the bhop honeypot.
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && !IsFakeClient(i)) Bhop_Init(i);
}
