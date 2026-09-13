// anticheat_aim.sp - Aimbot detector for L4D2 Anti-Cheat, scoped to
// Special Infected headshots.
//
// Why this design: the server can never see the player's "real" mouse
// intent - it only ever sees the final view angle the client sends, so
// comparing crosshair-vs-target position cannot distinguish an aimbot that
// moves the visible crosshair from a genuinely precise human (both produce
// identical server-side data). What the server CAN observe is how the
// player's aim angle *changed* between ticks, and how consistent their
// accuracy is over time - both are things no human mouse hand replicates
// perfectly, aimbot or not.
//
// So this detector tracks view-angle samples every tick (like a generic
// snap/consistency aim detector), but only turns that into suspicion at
// the moment of a HEADSHOT on a SPECIAL INFECTED - the specific pattern
// requested: sudden snap immediately before/at a headshot, or unnaturally
// tight aim consistency sustained across several such headshots.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

#define HITGROUP_HEAD 1

// Per-tick view angle history, used to measure the angular snap that
// preceded a qualifying headshot.
#define ANGLE_HISTORY 8
float g_AngleYaw[MAXPLAYERS+1][ANGLE_HISTORY];
float g_AnglePitch[MAXPLAYERS+1][ANGLE_HISTORY];
float g_AngleTime[MAXPLAYERS+1][ANGLE_HISTORY];
bool  g_AngleFiring[MAXPLAYERS+1][ANGLE_HISTORY]; // IN_ATTACK state that tick - shares this ring's index/head
int   g_AngleHead[MAXPLAYERS+1];
int   g_AngleCount[MAXPLAYERS+1];

// Qualifying headshot events (on Special Infected only), used to judge
// sustained statistical consistency across several shots.
#define EVENT_HISTORY 32
#define EVENT_MIN_SAMPLES 5
float g_EventSnapDeg[MAXPLAYERS+1][EVENT_HISTORY]; // angular jump in the tick of the shot
int   g_EventHead[MAXPLAYERS+1];
int   g_EventCount[MAXPLAYERS+1];

// A snap must exceed this to be recorded as a candidate event. Real-world
// testing showed this cheat corrects gradually (small per-tick jumps of
// ~2-7 degrees), not a single large flick, so the threshold is low - the
// CONSISTENCY_MAX_STDDEV_DEG filter below is what actually separates a
// script's repeatable correction from a human's naturally erratic
// micro-adjustments while tracking a moving target.
#define SNAP_THRESHOLD_DEG 2.0
// For the "consistency" path: an unnaturally tight, repeatable snap size
// across many headshots (low spread) is what a human can't replicate.
#define CONSISTENCY_MAX_STDDEV_DEG 4.0

// Close-quarters combat produces legitimately sharp aim corrections (the
// target is right on top of you) - ignore shots under this distance so
// melee-range chaos doesn't get counted as evidence.
#define AIM_MIN_DISTANCE 200.0

// Each recorded event "expires" after this long - a player who cheated
// once and then plays clean shouldn't stay flagged forever.
#define EVENT_EXPIRE_SECONDS 600.0
float g_EventTime[MAXPLAYERS+1][EVENT_HISTORY];

// ------------------------------------------------------------------
// "Angle Repeat" path (technique credited to the StAC-tf2 anti-cheat):
// a human aiming - even snapping onto a target in a panic - always has
// some residual mouse drift immediately before and after the snap. A
// script that jumps straight to the target and then holds perfectly still
// produces an isolated snap: near-zero noise, one large jump, near-zero
// noise again. This is harder to fake than a raw snap-size threshold,
// because a human deliberately adding "noise" around their shots to evade
// this either ruins their aim or reproduces the same detectable pattern.
//
// Runs every tick while the attack button is held, independent of the
// headshot/Special-Infected gating above - it has its own noise/snap
// thresholds that already reject normal tracking on their own.
#define REPEAT_NOISE_DEG 0.5   // below this counts as "held still"
#define REPEAT_SNAP_DEG  10.0  // above this counts as "a sudden jump"
#define REPEAT_MIN_SAMPLES 5
#define REPEAT_EVENT_HISTORY 32
float g_RepeatEventDeg[MAXPLAYERS+1][REPEAT_EVENT_HISTORY];
float g_RepeatEventTime[MAXPLAYERS+1][REPEAT_EVENT_HISTORY];
int   g_RepeatEventHead[MAXPLAYERS+1];
int   g_RepeatEventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
// "Cmdnum Spike" path (technique credited to StAC-tf2): some cheats fire
// a "perfect shot" by jumping the client's command_number ahead several
// values on the exact usercmd that pulls the trigger. This does not move
// the crosshair at all - it is a client-side trick that skips the bullet
// spread/recoil pattern the server would otherwise apply for that shot.
// It's a completely different signal from the angle-based paths above:
// no aim data is involved at all, only the sequence integrity of the
// commands the client is sending.
//
// A legitimate client's cmdnum always increases by exactly 1 each tick
// (barring choke, which the lag-check below already filters out). A jump
// of many values on the very tick a shot is fired is not something normal
// network jitter produces.
#define CMDSPIKE_THRESHOLD_SHOT   12   // jump this big on a firing tick = spike
#define CMDSPIKE_THRESHOLD_IDLE   32   // bigger allowance off a firing tick (spawn/loading jitter etc.)
#define CMDSPIKE_MIN_SAMPLES 3
#define CMDSPIKE_EVENT_HISTORY 32
int   g_CmdNumPrev[MAXPLAYERS+1];
int   g_CmdNumPrevPrev[MAXPLAYERS+1];
bool  g_CmdNumHasPrev[MAXPLAYERS+1];
float g_CmdSpikeEventTime[MAXPLAYERS+1][CMDSPIKE_EVENT_HISTORY];
int   g_CmdSpikeEventHead[MAXPLAYERS+1];
int   g_CmdSpikeEventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
// "Aimlock" path (technique credited to Little-Anti-Cheat / Lilac): rather
// than looking at a single snap, this watches the angle *converge* onto a
// Special Infected over several consecutive ticks. Legitimate tracking
// closes the gap gradually and proportionally - a human correcting their
// aim moves less as they get closer to on-target, but the ratio from tick
// to tick is noisy. A script that has locked onto the target collapses
// the remaining angle almost immediately (this tick's leftover angle to
// the target is a small fraction of the previous tick's) while ALSO still
// producing a big raw angle jump to get there - a human closing in that
// fast doesn't have a leftover angle worth collapsing in the first place.
// Sustaining that exact shape for a stretch of ticks is the tell.
#define AIMLOCK_CONVERGE_RATIO   0.10  // remaining angle-to-target drops to <=10% of previous sample's
#define AIMLOCK_MIN_JUMP_DEG     20.0  // ...while still moving at least this much between samples
// This check is sampled every 2nd game tick (perf), so each "hold" unit is
// ~2 ticks. 4 => ~8 ticks => ~0.25s sustained, still well short of any
// human tracking a moving target that smoothly.
#define AIMLOCK_HOLD_TICKS       4
#define AIMLOCK_MIN_SAMPLES 2
#define AIMLOCK_EVENT_HISTORY 16
int   g_AimlockHoldTicks[MAXPLAYERS+1];
float g_AimlockPrevDeltaDeg[MAXPLAYERS+1]; // angle-to-nearest-target left over on the previous tick
float g_AimlockEventTime[MAXPLAYERS+1][AIMLOCK_EVENT_HISTORY];
int   g_AimlockEventHead[MAXPLAYERS+1];
int   g_AimlockEventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
// "No-Recoil" path: firing any weapon kicks the view pitch upward tick by
// tick (recoil/punchangle) - even a player fighting the kick with the
// mouse leaves a jagged, imperfect trace because human correction is
// reactive (it lags a frame or two behind each kick, and overshoots or
// undershoots by varying amounts). A no-recoil cheat cancels the kick
// before it ever reaches the view angle the server sees, so the pitch
// stays essentially flat - within measurement noise - tick after tick
// for the entire length of a sustained burst. That flatness sustained for
// many consecutive firing ticks is not something a human's imperfect
// counter-correction reproduces; a real player's trace always has some
// ticks where the correction over- or under-shoots by more than the
// noise floor below.
//
// Gating on a long unbroken IN_ATTACK burst (not just "any 2 shots") is
// what keeps this from flagging semi-auto/low-recoil weapons (pistol,
// hunting rifle) - those rarely produce a burst this long in the first
// place, so they mostly never reach the point where this check judges
// anything.
#define NORECOIL_FLAT_DEG        0.15  // pitch delta below this counts as "did not rise" this tick
#define NORECOIL_MIN_BURST_TICKS 18    // ~0.6s of unbroken fire before judging flatness at all
#define NORECOIL_MIN_FLAT_RATIO  0.85  // this fraction of the judged burst must be flat
#define NORECOIL_EVENT_HISTORY 16
int   g_NoRecoilBurstTicks[MAXPLAYERS+1];   // consecutive IN_ATTACK ticks in the current burst
int   g_NoRecoilFlatTicks[MAXPLAYERS+1];    // of those, how many had a near-zero pitch delta
float g_NoRecoilPrevPitch[MAXPLAYERS+1];
bool  g_NoRecoilHasPrevPitch[MAXPLAYERS+1];
float g_NoRecoilEventTime[MAXPLAYERS+1][NORECOIL_EVENT_HISTORY];
int   g_NoRecoilEventHead[MAXPLAYERS+1];
int   g_NoRecoilEventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
// "Headshot Ratio" path: of all the shots a player lands on a Special
// Infected (body or head), what fraction are headshots? A human's ratio
// varies shot to shot - recoil, movement, panic - even a very good player
// mixes in body/limb hits over a long enough sample. A ratio pinned near
// 100% sustained across many landed shots is the signature of an aimbot
// silently correcting every shot to the head regardless of where the
// player's crosshair actually was (this is the OTHER half of that same
// cheat behavior - anticheat_osac.sp's SilentAim already catches the
// "aim visibly off-target yet the hit lands" side of it independently).
//
// Ring buffer stores just a bit per landed shot: was it a headshot.
#define HSRATIO_MIN_SHOTS   8      // need a real sample before judging a ratio at all
#define HSRATIO_SUSPECT     0.95   // sustained ratio at/above this is suspicious
#define HSRATIO_HISTORY 32
bool  g_HSRatioIsHead[MAXPLAYERS+1][HSRATIO_HISTORY];
float g_HSRatioTime[MAXPLAYERS+1][HSRATIO_HISTORY];
int   g_HSRatioHead[MAXPLAYERS+1];
int   g_HSRatioCount[MAXPLAYERS+1];
float g_HSRatioLastEventTime[MAXPLAYERS+1];

// ------------------------------------------------------------------
// "No-Spread" path: reconstructing the engine's exact per-shot spread
// from its RNG seed isn't feasible in pure SourcePawn (that RNG lives in
// the engine binary, not exposed through any include), so this measures
// the statistical fingerprint instead. Every hitscan weapon has real
// spread/inaccuracy that grows with movement and sustained fire - shot
// after shot at range, that spread scatters the actual impact point
// around the crosshair's intended line by a real, non-zero amount, and a
// human's own imperfect follow-up correction adds more scatter on top.
// A no-spread cheat (see e.g. SimpleRealistic/styles-cheat-csgo-source's
// NoSpread.cpp) cancels the engine's spread calculation before the shot
// leaves the client, so the impact lands dead-on the aimed line almost
// every time - the scatter that should be there just isn't. This tracks
// the angular error between the view and the actual impact point across
// many separate (non-burst) shots at real range and flags a sustained
// run where that error stays implausibly tight.
#define NOSPREAD_MIN_RANGE       300.0  // only judge shots with actual travel distance - spread barely matters up close
#define NOSPREAD_MAX_ERR_DEG       1.2  // impact error below this is "suspiciously clean" for a real weapon's spread
#define NOSPREAD_MIN_SHOTS          10  // separate shots needed before judging a run
#define NOSPREAD_TIGHT_RATIO      0.85  // this fraction of the run landing dead-clean is the tell
#define NOSPREAD_BURST_GAP_SEC     0.3  // shots closer together than this are spray continuation, not separate attempts
#define NOSPREAD_HISTORY 24
float g_NoSpreadErrDeg[MAXPLAYERS+1][NOSPREAD_HISTORY];
float g_NoSpreadTime[MAXPLAYERS+1][NOSPREAD_HISTORY];
int   g_NoSpreadHead[MAXPLAYERS+1];
int   g_NoSpreadCount[MAXPLAYERS+1];
float g_NoSpreadLastFireTime[MAXPLAYERS+1];
float g_NoSpreadLastEventTime[MAXPLAYERS+1];

// ------------------------------------------------------------------
// "Psilent" path (technique credited to StAC-tf2, the strongest single
// detector in that project): a silent-aim cheat that snaps the view to
// the target for exactly the one tick it needs the server to register
// the hit, then snaps it straight back to where the player's mouse
// actually was - so the crosshair the player SEES never visibly moves.
// The tell is in the three-tick shape: angle[oldest] and angle[newest]
// match almost exactly, while angle[middle] jumped far away from both.
// A human's hand cannot produce that "there and immediately back to the
// exact same spot" shape - any real correction leaves the aim somewhere
// new, not restores it byte-for-byte.
#define PSILENT_RETURN_EPS_DEG   0.1   // frame A and frame C must match within this to count as "snapped back"
#define PSILENT_MIN_JUMP_DEG     5.0   // frame B must have moved at least this far from both neighbors
#define PSILENT_EVENT_HISTORY 16
float g_PsilentEventTime[MAXPLAYERS+1][PSILENT_EVENT_HISTORY];
int   g_PsilentEventHead[MAXPLAYERS+1];
int   g_PsilentEventCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
// "FOV Lock" path: many public aimbots (e.g. the reference implementation
// at github.com/Franc1sco/aimbot) select and snap onto whichever target
// enters a fixed angular radius around the crosshair - a circular "FOV"
// cone measured with a dot product against the view direction, checked
// every tick regardless of which direction the target is approaching
// from. The server can't see that cone directly, but it CAN see its
// fingerprint: every time the aim reacts with a real snap toward the
// nearest target, record how far off-target the aim was the instant
// before it reacted (the "entry radius"). A human's snap reacts at
// wildly different distances shot to shot - however close the target
// happened to be when they noticed it, mid-swing, out of the corner of
// their eye, already tracking loosely - so that distribution is wide. A
// fixed-FOV cheat reacts at (almost) the same entry radius every time,
// regardless of the direction the target came from, because that radius
// IS the cheat's configured trigger boundary. Low spread across many
// independent snaps, not any single snap's size, is what's damning here.
#define FOVLOCK_SNAP_MIN_DEG      8.0   // minimum aim-error jump to count as "the aim reacted"
#define FOVLOCK_ENTRY_MAX_DEG    60.0   // entry radii beyond this are too wide to be a tight cheat FOV - ignore as noise
#define FOVLOCK_MIN_SAMPLES       6     // need several independent snaps to judge a spread at all
#define FOVLOCK_MAX_STDDEV_DEG    2.5   // spread this tight across many samples is the tell
#define FOVLOCK_HISTORY 24
float g_FovLockEntryDeg[MAXPLAYERS+1][FOVLOCK_HISTORY]; // angle-to-target the instant before each confirmed snap
float g_FovLockEntryTime[MAXPLAYERS+1][FOVLOCK_HISTORY];
int   g_FovLockHead[MAXPLAYERS+1];
int   g_FovLockCount[MAXPLAYERS+1];
float g_FovLockLastEventTime[MAXPLAYERS+1];

// ------------------------------------------------------------------
// "Autoshoot" path (technique credited to Little-Anti-Cheat): a real
// mouse click physically depresses the button for more than a single
// server tick - even the fastest human click registers as IN_ATTACK held
// across at least 2-3 consecutive ticks at typical tickrates. A cheat
// that fires a shot programmatically (rather than through an actual
// button press) can pulse IN_ATTACK for exactly one tick and release it,
// which no human clicking a physical mouse button reproduces.
#define AUTOSHOOT_MAX_HOLD_TICKS  1    // held for this many ticks or fewer = suspicious
#define AUTOSHOOT_EVENT_HISTORY 16
float g_AutoshootEventTime[MAXPLAYERS+1][AUTOSHOOT_EVENT_HISTORY];
int   g_AutoshootEventHead[MAXPLAYERS+1];
int   g_AutoshootEventCount[MAXPLAYERS+1];
bool  g_AutoshootPrevFiring[MAXPLAYERS+1];
int   g_AutoshootHoldTicks[MAXPLAYERS+1];

void Aim_Init(int client)
{
    g_AngleHead[client] = 0;
    g_AngleCount[client] = 0;
    g_EventHead[client] = 0;
    g_EventCount[client] = 0;
    g_RepeatEventHead[client] = 0;
    g_RepeatEventCount[client] = 0;
    g_CmdNumHasPrev[client] = false;
    g_CmdSpikeEventHead[client] = 0;
    g_CmdSpikeEventCount[client] = 0;
    g_AimlockHoldTicks[client] = 0;
    g_AimlockEventHead[client] = 0;
    g_AimlockEventCount[client] = 0;
    g_AimlockPrevDeltaDeg[client] = -1.0;
    g_NoRecoilBurstTicks[client] = 0;
    g_NoRecoilFlatTicks[client] = 0;
    g_NoRecoilHasPrevPitch[client] = false;
    g_NoRecoilEventHead[client] = 0;
    g_NoRecoilEventCount[client] = 0;
    g_HSRatioHead[client] = 0;
    g_HSRatioCount[client] = 0;
    g_HSRatioLastEventTime[client] = 0.0;
    g_PsilentEventHead[client] = 0;
    g_PsilentEventCount[client] = 0;
    g_AutoshootEventHead[client] = 0;
    g_AutoshootEventCount[client] = 0;
    g_AutoshootPrevFiring[client] = false;
    g_AutoshootHoldTicks[client] = 0;
    g_FovLockHead[client] = 0;
    g_FovLockCount[client] = 0;
    g_FovLockLastEventTime[client] = 0.0;
    g_NoSpreadHead[client] = 0;
    g_NoSpreadCount[client] = 0;
    g_NoSpreadLastFireTime[client] = 0.0;
    g_NoSpreadLastEventTime[client] = 0.0;
}

// ------------------------------------------------------------------
// The CHEAP part of the per-tick aim work: keep the angle-history ring
// buffer and run the checks that are pure arithmetic on values already in
// hand (angle-repeat, cmdnum-spike). No per-client scans here.
void Aim_RecordAngleCheap(int client, const float angles[3], int buttons, int cmdnum)
{
    int idx = g_AngleHead[client];
    g_AngleYaw[client][idx]   = angles[0];
    g_AnglePitch[client][idx] = angles[1];
    g_AngleTime[client][idx]  = GetGameTime();
    g_AngleFiring[client][idx] = (buttons & IN_ATTACK) != 0;
    g_AngleHead[client] = (idx + 1) % ANGLE_HISTORY;
    if (g_AngleCount[client] < ANGLE_HISTORY) g_AngleCount[client]++;

    if (buttons & IN_ATTACK) Aim_CheckAngleRepeat(client);
    Aim_CheckCmdnumSpike(client, cmdnum, (buttons & IN_ATTACK) != 0);
    Aim_CheckNoRecoil(client, (buttons & IN_ATTACK) != 0);
    Aim_CheckPsilent(client);
    Aim_CheckAutoshoot(client, (buttons & IN_ATTACK) != 0);
}

// ------------------------------------------------------------------
// "Cmdnum Spike" check (see comment near CMDSPIKE_* constants above).
// Compares this tick's cmdnum against the previous one; a jump far bigger
// than 1 that lands on a firing tick is the signature of a no-spread/
// perfect-shot cheat skipping ahead in the command sequence.
static void Aim_CheckCmdnumSpike(int client, int cmdnum, bool firing)
{
    if (!g_CmdNumHasPrev[client])
    {
        g_CmdNumPrevPrev[client] = cmdnum;
        g_CmdNumPrev[client] = cmdnum;
        g_CmdNumHasPrev[client] = true;
        return;
    }

    int spike = g_CmdNumPrev[client] - g_CmdNumPrevPrev[client];
    int threshold = firing ? CMDSPIKE_THRESHOLD_SHOT : CMDSPIKE_THRESHOLD_IDLE;

    if (spike >= threshold || spike <= -threshold)
    {
        int idx = g_CmdSpikeEventHead[client];
        g_CmdSpikeEventTime[client][idx] = GetGameTime();
        g_CmdSpikeEventHead[client] = (idx + 1) % CMDSPIKE_EVENT_HISTORY;
        if (g_CmdSpikeEventCount[client] < CMDSPIKE_EVENT_HISTORY) g_CmdSpikeEventCount[client]++;

        // Severity: how far past the threshold the spike went, capped at 100.
        int absSpike = spike < 0 ? -spike : spike;
        int severity = 50 + (absSpike - threshold) * 2;
        Correlation_ReportEvent(client, CORR_DET_AIM_CMDSPIKE, severity);
    }

    g_CmdNumPrevPrev[client] = g_CmdNumPrev[client];
    g_CmdNumPrev[client] = cmdnum;
}

static float NormalizeAngleDiff(float diff)
{
    if (diff > 180.0) return 360.0 - diff;
    return diff;
}

// ------------------------------------------------------------------
// "Angle Repeat" check (see comment near REPEAT_* constants above).
// Looks at the 4 deltas across the last 5 recorded ticks and flags an
// isolated snap: noise, JUMP, noise, noise (or the jump one slot earlier).
static void Aim_CheckAngleRepeat(int client)
{
    if (g_AngleCount[client] < 5) return;

    int head = g_AngleHead[client];
    float d[4];
    for (int i = 0; i < 4; i++)
    {
        int idxA = (head - 1 - i + ANGLE_HISTORY) % ANGLE_HISTORY;
        int idxB = (head - 2 - i + ANGLE_HISTORY) % ANGLE_HISTORY;

        float dYaw = FAbs(g_AngleYaw[client][idxA] - g_AngleYaw[client][idxB]);
        float dPitch = FAbs(g_AnglePitch[client][idxA] - g_AnglePitch[client][idxB]);
        dYaw = NormalizeAngleDiff(dYaw);
        // d[0] is the most recent delta, d[3] the oldest of the 4.
        d[i] = SquareRoot(dYaw*dYaw + dPitch*dPitch);
    }

    // d[3],d[2],d[1],d[0] in chronological order. Match either "jump in the
    // middle-early slot" or "jump in the middle-late slot", both flanked by
    // near-zero noise - a snap that arrives out of nowhere and is followed
    // by dead stillness, exactly what a script's target-lock produces and a
    // human's continuous mouse drift does not.
    bool isNoise0 = d[3] > 0.0 && d[3] < REPEAT_NOISE_DEG;
    bool isNoise2 = d[1] > 0.0 && d[1] < REPEAT_NOISE_DEG;
    bool isNoise3 = d[0] > 0.0 && d[0] < REPEAT_NOISE_DEG;
    bool isNoise1 = d[2] > 0.0 && d[2] < REPEAT_NOISE_DEG;

    float jumpDeg = 0.0;
    if (isNoise0 && d[2] > REPEAT_SNAP_DEG && isNoise2 && isNoise3)
    {
        jumpDeg = d[2];
    }
    else if (isNoise0 && isNoise1 && d[1] > REPEAT_SNAP_DEG && isNoise3)
    {
        jumpDeg = d[1];
    }
    else
    {
        return;
    }

    int idx = g_RepeatEventHead[client];
    g_RepeatEventDeg[client][idx] = jumpDeg;
    g_RepeatEventTime[client][idx] = GetGameTime();
    g_RepeatEventHead[client] = (idx + 1) % REPEAT_EVENT_HISTORY;
    if (g_RepeatEventCount[client] < REPEAT_EVENT_HISTORY) g_RepeatEventCount[client]++;

    // Severity: how far past the "sudden jump" threshold this snap was.
    Correlation_ReportEvent(client, CORR_DET_AIM_REPEAT, RoundFloat(40.0 + jumpDeg));
}

// ------------------------------------------------------------------
// "Psilent" check (see comment near PSILENT_* constants above). Looks at
// 3 consecutive recorded ticks: the oldest (A), the middle (B), and the
// newest (C). Flags when A and C match almost exactly while B jumped far
// from both - the "snap to target, snap back to the same spot" shape a
// psilent cheat leaves and a human's hand does not.
static void Aim_CheckPsilent(int client)
{
    if (g_AngleCount[client] < 3) return;

    int head = g_AngleHead[client];
    int idxC = (head - 1 + ANGLE_HISTORY) % ANGLE_HISTORY; // newest
    int idxB = (head - 2 + ANGLE_HISTORY) % ANGLE_HISTORY; // middle
    int idxA = (head - 3 + ANGLE_HISTORY) % ANGLE_HISTORY; // oldest

    float dYawAC = NormalizeAngleDiff(FAbs(g_AngleYaw[client][idxA] - g_AngleYaw[client][idxC]));
    float dPitchAC = FAbs(g_AnglePitch[client][idxA] - g_AnglePitch[client][idxC]);
    float returnDeg = SquareRoot(dYawAC*dYawAC + dPitchAC*dPitchAC);
    if (returnDeg >= PSILENT_RETURN_EPS_DEG) return; // did not snap back to (almost) the same spot

    float dYawAB = NormalizeAngleDiff(FAbs(g_AngleYaw[client][idxA] - g_AngleYaw[client][idxB]));
    float dPitchAB = FAbs(g_AnglePitch[client][idxA] - g_AnglePitch[client][idxB]);
    float jumpDeg = SquareRoot(dYawAB*dYawAB + dPitchAB*dPitchAB);
    if (jumpDeg < PSILENT_MIN_JUMP_DEG) return; // no real jump in the middle frame, nothing to explain

    // The middle frame must be the one that actually fired - otherwise
    // this is just a normal flick-and-settle with no shot involved.
    if (!g_AngleFiring[client][idxB]) return;

    int idx = g_PsilentEventHead[client];
    g_PsilentEventTime[client][idx] = GetGameTime();
    g_PsilentEventHead[client] = (idx + 1) % PSILENT_EVENT_HISTORY;
    if (g_PsilentEventCount[client] < PSILENT_EVENT_HISTORY) g_PsilentEventCount[client]++;

    // Severity: how far the middle-frame jump was, on top of a fixed high
    // base - a confirmed snap-and-return-to-the-exact-spot is strong
    // evidence by construction, not something that scales gently.
    Correlation_ReportEvent(client, CORR_DET_AIM_PSILENT, RoundFloat(60.0 + jumpDeg));
}

// ------------------------------------------------------------------
// "Autoshoot" check (see comment near AUTOSHOOT_* constants above). Walks
// IN_ATTACK's rising/falling edge every tick; if it drops again after
// AUTOSHOOT_MAX_HOLD_TICKS or fewer ticks held, the click was too short
// for a human finger on a physical button.
static void Aim_CheckAutoshoot(int client, bool firing)
{
    if (firing)
    {
        g_AutoshootHoldTicks[client]++;
        g_AutoshootPrevFiring[client] = true;
        return;
    }

    if (!g_AutoshootPrevFiring[client]) return; // wasn't firing last tick either - nothing just ended

    int heldTicks = g_AutoshootHoldTicks[client];
    g_AutoshootHoldTicks[client] = 0;
    g_AutoshootPrevFiring[client] = false;

    if (heldTicks < 1 || heldTicks > AUTOSHOOT_MAX_HOLD_TICKS) return;

    int idx = g_AutoshootEventHead[client];
    g_AutoshootEventTime[client][idx] = GetGameTime();
    g_AutoshootEventHead[client] = (idx + 1) % AUTOSHOOT_EVENT_HISTORY;
    if (g_AutoshootEventCount[client] < AUTOSHOOT_EVENT_HISTORY) g_AutoshootEventCount[client]++;

    Correlation_ReportEvent(client, CORR_DET_AIM_AUTOSHOOT, 55);
}

// ------------------------------------------------------------------
// "No-Recoil" check (see comment near NORECOIL_* constants above). Tracks
// how many consecutive IN_ATTACK ticks pass with essentially zero pitch
// movement once the burst is long enough to judge, and flags a burst that
// stayed flat almost the entire time.
static void Aim_CheckNoRecoil(int client, bool firing)
{
    if (!firing)
    {
        g_NoRecoilBurstTicks[client] = 0;
        g_NoRecoilFlatTicks[client] = 0;
        g_NoRecoilHasPrevPitch[client] = false;
        return;
    }

    float eyeAngles[3];
    GetClientEyeAngles(client, eyeAngles);
    float pitch = eyeAngles[0]; // GetClientEyeAngles: [0]=pitch, [1]=yaw, unambiguous regardless of this file's own angle-buffer convention

    if (!g_NoRecoilHasPrevPitch[client])
    {
        g_NoRecoilPrevPitch[client] = pitch;
        g_NoRecoilHasPrevPitch[client] = true;
        g_NoRecoilBurstTicks[client] = 1;
        g_NoRecoilFlatTicks[client] = 0;
        return;
    }

    float dPitch = FAbs(pitch - g_NoRecoilPrevPitch[client]);
    g_NoRecoilPrevPitch[client] = pitch;
    g_NoRecoilBurstTicks[client]++;
    if (dPitch < NORECOIL_FLAT_DEG) g_NoRecoilFlatTicks[client]++;

    if (g_NoRecoilBurstTicks[client] < NORECOIL_MIN_BURST_TICKS) return;

    float flatRatio = float(g_NoRecoilFlatTicks[client]) / float(g_NoRecoilBurstTicks[client]);
    if (flatRatio < NORECOIL_MIN_FLAT_RATIO) return;

    int idx = g_NoRecoilEventHead[client];
    g_NoRecoilEventTime[client][idx] = GetGameTime();
    g_NoRecoilEventHead[client] = (idx + 1) % NORECOIL_EVENT_HISTORY;
    if (g_NoRecoilEventCount[client] < NORECOIL_EVENT_HISTORY) g_NoRecoilEventCount[client]++;

    // Severity: how far past the flat-ratio floor this burst was, plus a
    // bonus for a longer sustained burst (harder to fake by luck).
    int severity = RoundFloat(40.0 + (flatRatio - NORECOIL_MIN_FLAT_RATIO) * 200.0 + float(g_NoRecoilBurstTicks[client] - NORECOIL_MIN_BURST_TICKS));
    Correlation_ReportEvent(client, CORR_DET_AIM_NORECOIL, severity);

    // One confirmed flat burst = one event; keep judging the rest of this
    // same burst fresh instead of re-firing every tick while it continues.
    g_NoRecoilBurstTicks[client] = 0;
    g_NoRecoilFlatTicks[client] = 0;
}

// ------------------------------------------------------------------
// Angle (in degrees) between the client's current view direction and the
// straight line to a target's eye position - i.e. how far off-target the
// crosshair currently is. Returns -1.0 if there is no valid nearest
// Special Infected in front of the client to measure against.
static float Aim_GetAngleToNearestTarget(int client, const float viewAngles[3])
{
    float eyePos[3];
    GetClientEyePosition(client, eyePos);

    float bestDist = 99999999.0;
    float bestDeg = -1.0;

    // Iterate the shared per-frame Special Infected cache (built once in
    // OnPlayerRunCmd) instead of scanning all client slots here.
    for (int c = 0; c < g_SpecialCacheCount; c++)
    {
        int i = g_SpecialCache[c];
        if (!IsClientInGame(i)) continue;

        float targetPos[3];
        GetClientEyePosition(i, targetPos);

        float dist = GetVectorDistance(eyePos, targetPos);
        if (dist >= bestDist) continue;
        // Same close-quarters exemption used elsewhere - melee range
        // produces legitimately erratic tracking.
        if (dist < AIM_MIN_DISTANCE) continue;

        float toTarget[3];
        MakeVectorFromPoints(eyePos, targetPos, toTarget);
        float wanted[3];
        GetVectorAngles(toTarget, wanted);

        float dYaw = FAbs(viewAngles[1] - wanted[1]);
        dYaw = NormalizeAngleDiff(dYaw);
        float dPitch = FAbs(viewAngles[0] - wanted[0]);
        float deg = SquareRoot(dYaw*dYaw + dPitch*dPitch);

        bestDist = dist;
        bestDeg = deg;
    }

    return bestDeg;
}

// Throttled entry point (called every 2nd tick from OnPlayerRunCmd).
void Aim_CheckAimlockThrottled(int client, const float angles[3])
{
    Aim_CheckAimlock(client, angles);
}

// TriggerBot entry point - reuses this module's angle-history ring buffer
// (no separate buffer in the OSAC module). Called every 2nd tick while
// IN_ATTACK is held.
void Aim_RunTriggerCheck(int client)
{
    OSAC_CheckTrigger(client, g_AngleYaw[client], g_AnglePitch[client],
                      g_AngleTime[client], g_AngleHead[client],
                      ANGLE_HISTORY, g_AngleCount[client]);
}

// ------------------------------------------------------------------
// "FOV Lock" check (see comment near FOVLOCK_* constants above). Records
// the angle-to-target the instant before a real snap toward it, then
// judges whether that "entry radius" is suspiciously consistent across
// many independent snaps - the signature of a fixed circular aimbot FOV
// rather than a human noticing targets at wildly varying distances.
static void Aim_CheckFovLock(int client, float prevDeg, float deltaDeg)
{
    float snapSize = prevDeg - deltaDeg; // how much closer to on-target this tick landed
    if (snapSize < FOVLOCK_SNAP_MIN_DEG) return;          // not a real snap, just normal tracking noise
    if (prevDeg > FOVLOCK_ENTRY_MAX_DEG) return;           // target was already too far out to be a tight cheat FOV

    int idx = g_FovLockHead[client];
    g_FovLockEntryDeg[client][idx] = prevDeg;
    g_FovLockEntryTime[client][idx] = GetGameTime();
    g_FovLockHead[client] = (idx + 1) % FOVLOCK_HISTORY;
    if (g_FovLockCount[client] < FOVLOCK_HISTORY) g_FovLockCount[client]++;

    int total = g_FovLockCount[client];
    if (total < FOVLOCK_MIN_SAMPLES) return;

    float now = GetGameTime();
    float sum = 0.0;
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_FovLockEntryTime[client][i] > EVENT_EXPIRE_SECONDS) continue;
        sum += g_FovLockEntryDeg[client][i];
        count++;
    }
    if (count < FOVLOCK_MIN_SAMPLES) return;
    float avg = sum / float(count);

    float varSum = 0.0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_FovLockEntryTime[client][i] > EVENT_EXPIRE_SECONDS) continue;
        float d = g_FovLockEntryDeg[client][i] - avg;
        varSum += d * d;
    }
    float stddev = SquareRoot(varSum / float(count));
    if (stddev >= FOVLOCK_MAX_STDDEV_DEG) return; // entry radius varies too much - looks human

    if (now - g_FovLockLastEventTime[client] < 3.0) return; // don't re-fire every single qualifying snap
    g_FovLockLastEventTime[client] = now;

    // Severity: tighter spread and a longer confirmed sample are both
    // stronger evidence of a fixed trigger radius.
    int severity = RoundFloat(45.0 + (FOVLOCK_MAX_STDDEV_DEG - stddev) * 15.0 + float(count - FOVLOCK_MIN_SAMPLES) * 2.0);
    Correlation_ReportEvent(client, CORR_DET_AIM_FOVLOCK, severity);
}

// ------------------------------------------------------------------
// "Aimlock" check (see comment near AIMLOCK_* constants above). Compares
// how much leftover angle-to-target remains this tick versus last tick.
static void Aim_CheckAimlock(int client, const float angles[3])
{
    float deltaDeg = Aim_GetAngleToNearestTarget(client, angles);

    if (deltaDeg < 0.0)
    {
        // No valid target in range right now - can't judge convergence.
        g_AimlockPrevDeltaDeg[client] = -1.0;
        g_AimlockHoldTicks[client] = 0;
        return;
    }

    float prevDeg = g_AimlockPrevDeltaDeg[client];
    g_AimlockPrevDeltaDeg[client] = deltaDeg;

    if (prevDeg < 0.0) return; // first sample since acquiring a target, nothing to compare yet

    Aim_CheckFovLock(client, prevDeg, deltaDeg);

    bool converging = (prevDeg > 1.0) && (deltaDeg <= prevDeg * AIMLOCK_CONVERGE_RATIO);
    bool bigJump = FAbs(prevDeg - deltaDeg) >= AIMLOCK_MIN_JUMP_DEG;

    if (converging && bigJump)
    {
        g_AimlockHoldTicks[client]++;
        if (g_AimlockHoldTicks[client] >= AIMLOCK_HOLD_TICKS)
        {
            int idx = g_AimlockEventHead[client];
            g_AimlockEventTime[client][idx] = GetGameTime();
            g_AimlockEventHead[client] = (idx + 1) % AIMLOCK_EVENT_HISTORY;
            if (g_AimlockEventCount[client] < AIMLOCK_EVENT_HISTORY) g_AimlockEventCount[client]++;

            // A confirmed sustained lock is strong on its own - fixed high severity.
            Correlation_ReportEvent(client, CORR_DET_AIM_AIMLOCK, 75);
            // Reset the hold so a single sustained lock doesn't count as
            // dozens of events - each confirmed lock-on is one event.
            g_AimlockHoldTicks[client] = 0;
        }
    }
    else
    {
        g_AimlockHoldTicks[client] = 0;
    }
}

// ------------------------------------------------------------------
static bool IsSpecialInfected(int victim)
{
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim)) return false;
    if (GetClientTeam(victim) != 3) return false; // 3 = Infected team

    int zclass = GetEntProp(victim, Prop_Send, "m_zombieClass");
    return (zclass >= 1 && zclass <= 8); // Smoker..Tank (7 = Witch included)
}

static float FAbs(float v) { return v < 0.0 ? -v : v; }

// ------------------------------------------------------------------
// "Headshot Ratio" recorder - every shot landed on a Special Infected
// (any hitgroup), not just headshots, so the ratio has a real denominator.
static void Aim_RecordHeadshotRatioSample(int attacker, bool isHead)
{
    int idx = g_HSRatioHead[attacker];
    g_HSRatioIsHead[attacker][idx] = isHead;
    g_HSRatioTime[attacker][idx] = GetGameTime();
    g_HSRatioHead[attacker] = (idx + 1) % HSRATIO_HISTORY;
    if (g_HSRatioCount[attacker] < HSRATIO_HISTORY) g_HSRatioCount[attacker]++;

    // Report to correlation once there's enough sample to judge, at most
    // once every few seconds (a burst of headshots landing in the same
    // instant shouldn't count as many independent correlation events).
    int total = g_HSRatioCount[attacker];
    if (total < HSRATIO_MIN_SHOTS) return;

    float now = GetGameTime();
    int heads = 0;
    for (int i = 0; i < total; i++)
    {
        if (g_HSRatioIsHead[attacker][i]) heads++;
    }
    float ratio = float(heads) / float(total);
    if (ratio < HSRATIO_SUSPECT) return;
    if (now - g_HSRatioLastEventTime[attacker] < 3.0) return;

    g_HSRatioLastEventTime[attacker] = now;
    int severity = RoundFloat(40.0 + (ratio - HSRATIO_SUSPECT) * 1000.0 + float(total - HSRATIO_MIN_SHOTS));
    Correlation_ReportEvent(attacker, CORR_DET_AIM_HSRATIO, severity);
}

// ------------------------------------------------------------------
// "No-Spread" recorder (see comment near NOSPREAD_* constants above).
// Only judges the FIRST shot of a burst at real range - a spray's later
// shots have their own separate accuracy-decay statistics and would
// muddy a clean read on baseline spread.
static void Aim_RecordNoSpreadSample(int attacker, int victim, const float attackerAngles[3])
{
    float now = GetGameTime();
    bool firstOfBurst = (now - g_NoSpreadLastFireTime[attacker]) > NOSPREAD_BURST_GAP_SEC;
    g_NoSpreadLastFireTime[attacker] = now;
    if (!firstOfBurst) return;

    float eyePos[3], victimPos[3];
    GetClientEyePosition(attacker, eyePos);
    GetClientAbsOrigin(victim, victimPos);
    victimPos[2] += 32.0; // torso-ish reference point, same convention as OSAC

    float range = GetVectorDistance(eyePos, victimPos);
    if (range < NOSPREAD_MIN_RANGE) return;

    float toTarget[3];
    MakeVectorFromPoints(eyePos, victimPos, toTarget);
    float wanted[3];
    GetVectorAngles(toTarget, wanted);

    float dYaw = NormalizeAngleDiff(FAbs(attackerAngles[1] - wanted[1]));
    float dPitch = FAbs(attackerAngles[0] - wanted[0]);
    float errDeg = SquareRoot(dYaw*dYaw + dPitch*dPitch);

    int idx = g_NoSpreadHead[attacker];
    g_NoSpreadErrDeg[attacker][idx] = errDeg;
    g_NoSpreadTime[attacker][idx] = now;
    g_NoSpreadHead[attacker] = (idx + 1) % NOSPREAD_HISTORY;
    if (g_NoSpreadCount[attacker] < NOSPREAD_HISTORY) g_NoSpreadCount[attacker]++;

    int total = g_NoSpreadCount[attacker];
    if (total < NOSPREAD_MIN_SHOTS) return;

    int tight = 0;
    int counted = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_NoSpreadTime[attacker][i] > EVENT_EXPIRE_SECONDS) continue;
        counted++;
        if (g_NoSpreadErrDeg[attacker][i] <= NOSPREAD_MAX_ERR_DEG) tight++;
    }
    if (counted < NOSPREAD_MIN_SHOTS) return;

    float tightRatio = float(tight) / float(counted);
    if (tightRatio < NOSPREAD_TIGHT_RATIO) return;
    if (now - g_NoSpreadLastEventTime[attacker] < 3.0) return;

    g_NoSpreadLastEventTime[attacker] = now;
    int severity = RoundFloat(45.0 + (tightRatio - NOSPREAD_TIGHT_RATIO) / (1.0 - NOSPREAD_TIGHT_RATIO) * 45.0 + float(counted - NOSPREAD_MIN_SHOTS));
    Correlation_ReportEvent(attacker, CORR_DET_AIM_NOSPREAD, severity);
}

// ------------------------------------------------------------------
// Called from Hook_TraceAttack for every shot that lands on a Special
// Infected (any hitgroup) - feeds the Headshot Ratio and No-Spread paths.
// The snap/flick logic below only ever acted on headshots, kept as-is
// for that subset.
void Aim_RecordShot(int attacker, int victim, int hitgroup, const float attackerAngles[3])
{
    if (!IsSpecialInfected(victim)) return;
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return;

    Aim_RecordHeadshotRatioSample(attacker, hitgroup == HITGROUP_HEAD);
    Aim_RecordNoSpreadSample(attacker, victim, attackerAngles);

    if (hitgroup != HITGROUP_HEAD) return;

    // Close-quarters shots produce legitimately sharp corrections - skip them.
    float posAttacker[3], posVictim[3];
    GetClientAbsOrigin(attacker, posAttacker);
    GetClientAbsOrigin(victim, posVictim);
    if (GetVectorDistance(posAttacker, posVictim) < AIM_MIN_DISTANCE) return;

    int count = g_AngleCount[attacker];
    if (count < 2) return;

    // Angular jump between the two most recent recorded ticks - the snap
    // that happened right at/just before this shot landed.
    int head = g_AngleHead[attacker];
    int idxCurr = (head - 1 + ANGLE_HISTORY) % ANGLE_HISTORY;
    int idxPrev = (head - 2 + ANGLE_HISTORY) % ANGLE_HISTORY;

    float dt = g_AngleTime[attacker][idxCurr] - g_AngleTime[attacker][idxPrev];
    if (dt <= 0.0 || dt > GetTickInterval() * 2.0) return; // not consecutive ticks

    float dYaw = FAbs(g_AngleYaw[attacker][idxCurr] - g_AngleYaw[attacker][idxPrev]);
    float dPitch = FAbs(g_AnglePitch[attacker][idxCurr] - g_AnglePitch[attacker][idxPrev]);
    if (dYaw > 180.0) dYaw = 360.0 - dYaw;
    float snapDeg = SquareRoot(dYaw*dYaw + dPitch*dPitch);

    if (snapDeg < SNAP_THRESHOLD_DEG) return; // no sudden flick, nothing to record

    int idx = g_EventHead[attacker];
    g_EventSnapDeg[attacker][idx] = snapDeg;
    g_EventTime[attacker][idx] = GetGameTime();
    g_EventHead[attacker] = (idx + 1) % EVENT_HISTORY;
    if (g_EventCount[attacker] < EVENT_HISTORY) g_EventCount[attacker]++;

    // Severity: how far past the base snap threshold this headshot's flick was.
    Correlation_ReportEvent(attacker, CORR_DET_AIM_SNAP, RoundFloat(40.0 + snapDeg * 3.0));
}

// Note: Snap+Consistency, Angle Repeat, Cmdnum Spike, Aimlock and
// No-Recoil above still run and still report to Correlation_ReportEvent
// for cross-detector correlation value, but (per project decision) no
// longer compute their own contribution to this module's aimbot score -
// Headshot Ratio below is the only thing Aim_GetScore consults now.
#define NORECOIL_MIN_EVENTS 2

// "Headshot Ratio" - sustained near-100% headshot rate against
// Special Infected across a real sample of landed shots (see
// Aim_RecordHeadshotRatioSample comment above). This is the module's ONLY
// contribution to Aim_GetScore - the other paths above (Snap, Angle
// Repeat, Cmdnum Spike, Aimlock, No-Recoil) still run and still feed the
// Correlation engine for their own cross-detector value, but no longer
// count toward this module's own aimbot score. The complementary pattern
// - crosshair visibly off-target yet the shot still lands - is
// anticheat_osac.sp's SilentAim, a separate module already scored on its
// own and combined into totalRisk independently.
static int Aim_GetHeadshotRatioScore(int client)
{
    int total = g_HSRatioCount[client];
    if (total < HSRATIO_MIN_SHOTS) return 0;

    float now = GetGameTime();
    int heads = 0;
    int counted = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_HSRatioTime[client][i] > EVENT_EXPIRE_SECONDS) continue;
        counted++;
        if (g_HSRatioIsHead[client][i]) heads++;
    }
    if (counted < HSRATIO_MIN_SHOTS) return 0;

    float ratio = float(heads) / float(counted);
    if (ratio < HSRATIO_SUSPECT) return 0;

    float score = 40.0 + (ratio - HSRATIO_SUSPECT) * 1000.0 + float(counted - HSRATIO_MIN_SHOTS) * 2.0;
    if (score > 100.0) score = 100.0;
    return RoundFloat(score);
}

static float FMax(float a, float b) { return a > b ? a : b; }
static float FMin(float a, float b) { return a < b ? a : b; }

// "Psilent" - 1-tick snap-to-target-and-back on a firing tick (see
// Aim_CheckPsilent comment above). Each confirmed occurrence is already
// near-certain by construction (a human cannot restore the exact prior
// angle after a real correction), so even a single recent event scores
// meaningfully; repeats push it to the cap fast.
#define PSILENT_MIN_EVENTS 1
static int Aim_GetPsilentScore(int client)
{
    int total = g_PsilentEventCount[client];
    if (total < PSILENT_MIN_EVENTS) return 0;

    float now = GetGameTime();
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_PsilentEventTime[client][i] <= EVENT_EXPIRE_SECONDS) count++;
    }
    if (count < PSILENT_MIN_EVENTS) return 0;

    float score = FMin(60.0 + float(count - PSILENT_MIN_EVENTS) * 20.0, 100.0);
    return RoundFloat(score);
}

// "Autoshoot" - IN_ATTACK held for fewer ticks than a physical click can
// produce (see Aim_CheckAutoshoot comment above). A single occurrence can
// be a genuinely fast tap or a network artifact, so this path needs a
// repeated pattern before it counts as evidence.
#define AUTOSHOOT_MIN_EVENTS 3
static int Aim_GetAutoshootScore(int client)
{
    int total = g_AutoshootEventCount[client];
    if (total < AUTOSHOOT_MIN_EVENTS) return 0;

    float now = GetGameTime();
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_AutoshootEventTime[client][i] <= EVENT_EXPIRE_SECONDS) count++;
    }
    if (count < AUTOSHOOT_MIN_EVENTS) return 0;

    float score = FMin(float(count - AUTOSHOOT_MIN_EVENTS) * 12.0 + 45.0, 100.0);
    return RoundFloat(score);
}

// "FOV Lock" - the aim reacts (snaps) at a suspiciously consistent entry
// radius across many independent encounters, regardless of the target's
// approach direction (see Aim_CheckFovLock comment above). Correlation_
// ReportEvent already gates this on a tight stddev before ever firing, so
// a single confirmed report is already a judged pattern, not a raw
// sample - unlike the other paths, one event here is meaningful evidence.
#define FOVLOCK_MIN_EVENTS 1
static int Aim_GetFovLockScore(int client)
{
    int total = g_FovLockCount[client];
    if (total < FOVLOCK_MIN_SAMPLES) return 0;

    float now = GetGameTime();
    float sum = 0.0;
    int count = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_FovLockEntryTime[client][i] > EVENT_EXPIRE_SECONDS) continue;
        sum += g_FovLockEntryDeg[client][i];
        count++;
    }
    if (count < FOVLOCK_MIN_SAMPLES) return 0;
    float avg = sum / float(count);

    float varSum = 0.0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_FovLockEntryTime[client][i] > EVENT_EXPIRE_SECONDS) continue;
        float d = g_FovLockEntryDeg[client][i] - avg;
        varSum += d * d;
    }
    float stddev = SquareRoot(varSum / float(count));
    if (stddev >= FOVLOCK_MAX_STDDEV_DEG) return 0;

    float score = 45.0 + (FOVLOCK_MAX_STDDEV_DEG - stddev) * 15.0 + float(count - FOVLOCK_MIN_SAMPLES) * 2.0;
    if (score > 100.0) score = 100.0;
    return RoundFloat(score);
}

// "No-Spread" - impact error stays implausibly tight across many separate
// shots at range (see Aim_RecordNoSpreadSample comment above). Correlation_
// ReportEvent for this path is already gated on a tight ratio across a
// real sample, so a confirmed recent report is judged evidence.
static int Aim_GetNoSpreadScore(int client)
{
    int total = g_NoSpreadCount[client];
    if (total < NOSPREAD_MIN_SHOTS) return 0;

    float now = GetGameTime();
    int tight = 0;
    int counted = 0;
    for (int i = 0; i < total; i++)
    {
        if (now - g_NoSpreadTime[client][i] > EVENT_EXPIRE_SECONDS) continue;
        counted++;
        if (g_NoSpreadErrDeg[client][i] <= NOSPREAD_MAX_ERR_DEG) tight++;
    }
    if (counted < NOSPREAD_MIN_SHOTS) return 0;

    float tightRatio = float(tight) / float(counted);
    if (tightRatio < NOSPREAD_TIGHT_RATIO) return 0;

    float score = 45.0 + (tightRatio - NOSPREAD_TIGHT_RATIO) / (1.0 - NOSPREAD_TIGHT_RATIO) * 45.0 + float(counted - NOSPREAD_MIN_SHOTS);
    if (score > 100.0) score = 100.0;
    return RoundFloat(score);
}

int Aim_GetScore(int client)
{
    float best = FMax(float(Aim_GetHeadshotRatioScore(client)), float(Aim_GetPsilentScore(client)));
    best = FMax(best, float(Aim_GetAutoshootScore(client)));
    best = FMax(best, float(Aim_GetFovLockScore(client)));
    best = FMax(best, float(Aim_GetNoSpreadScore(client)));
    return RoundFloat(best);
}
