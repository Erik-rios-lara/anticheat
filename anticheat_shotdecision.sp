// anticheat_shotdecision.sp - Shot Decision Analysis
//
// TargetAcq measures how long it took to get ON target. OSAC's TriggerBot
// measures the instant a crossing became a shot. Neither correlates the
// full decision chain against the CONTEXT of the shot - what weapon was
// held, how far the target was, whether it landed on the head - and asks
// whether that context changes the player's timing the way it changes a
// human's.
//
// A human's shot-decision timing is not a single number: it depends on
// weapon (a hitscan SMG spray "decision" looks nothing like lining up a
// single precise rifle shot), range (closer targets are both easier to
// hit and more urgent, both push timing down; far targets need more
// careful aim, pushing timing up), and whether the shot is a headshot
// attempt versus body-shot suppression. A script's target-lock-and-fire
// logic typically does not model any of that - it converges and fires on
// a similar schedule regardless of what weapon is equipped or how far
// the target is.
//
// This module doesn't re-measure acquisition itself - it reads the
// closed TargetAcq session for "time from acquisition-open to shot" and
// combines it with the shot's own context (weapon class, range, hitgroup)
// at the moment TraceAttack fires. Each qualifying shot becomes one
// record; scoring looks at whether decision timing stays suspiciously
// FLAT across genuinely different contexts (different weapon classes,
// different range bands) rather than varying the way human timing does.
//
// Like Variance Profiling, no single shot is evidence - only a
// cross-context pattern across enough independent shots.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

// ------------------------------------------------------------------
// Weapon classes, grouped by the kind of shot-decision dynamic a human
// naturally produces with them - not exact weapon identity. Precision
// weapons (hunting rifle, sniper, deagle) reward a deliberate, slower
// decision; spray/hitscan-fast weapons (SMGs, pistols, shotguns at close
// range) reward a fast, reflexive one. A human's timing genuinely differs
// between these classes; conflating them would hide the very difference
// this module looks for.
enum ShotWeaponClass
{
    SHOTCLASS_UNKNOWN = 0,
    SHOTCLASS_PRECISION,   // hunting_rifle, sniper_*, deagle - deliberate aim rewarded
    SHOTCLASS_RAPID        // everything else hitscan (pistols, SMGs, rifles, shotguns)
};

#define SD_RANGE_CLOSE   300.0   // <= this = close band
#define SD_RANGE_FAR     700.0   // >= this = far band (between = mid band)

// One qualifying shot's context + decision time.
enum struct SD_ShotRecord
{
    float DecisionTimeMs;   // acquisition-open to shot, from TargetAcq's session data
    ShotWeaponClass WeaponClass;
    int RangeBand;           // 0 close, 1 mid, 2 far
    bool WasHeadshot;
    float RecordedAt;
}

#define SD_HISTORY 24
#define SD_MIN_SHOTS_PER_BUCKET 4   // need at least this many shots in 2+ distinct buckets to compare
#define SD_MIN_BUCKETS 2            // need at least this many distinct (weapon class, range band) buckets populated
#define SD_HISTORY_EXPIRE_SECONDS 900.0

SD_ShotRecord g_SD_History[MAXPLAYERS+1][SD_HISTORY];
int           g_SD_HistoryHead[MAXPLAYERS+1];
int           g_SD_HistoryCount[MAXPLAYERS+1];

// ------------------------------------------------------------------
void ShotDecision_Init(int client)
{
    g_SD_HistoryHead[client] = 0;
    g_SD_HistoryCount[client] = 0;
}

static float SD_FMin(float a, float b) { return a < b ? a : b; }

static ShotWeaponClass SD_ClassifyWeapon(int client)
{
    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon <= 0 || !IsValidEntity(weapon)) return SHOTCLASS_UNKNOWN;

    char classname[64];
    GetEntityClassname(weapon, classname, sizeof(classname));

    if (StrContains(classname, "hunting_rifle", false) != -1
        || StrContains(classname, "sniper", false) != -1
        || StrContains(classname, "scout", false) != -1
        || StrContains(classname, "military_sniper", false) != -1
        || StrContains(classname, "desert_rifle", false) != -1
        || StrContains(classname, "deagle", false) != -1
        || StrContains(classname, "magnum", false) != -1)
    {
        return SHOTCLASS_PRECISION;
    }

    return SHOTCLASS_RAPID;
}

static int SD_RangeBand(float dist)
{
    if (dist <= SD_RANGE_CLOSE) return 0;
    if (dist >= SD_RANGE_FAR) return 2;
    return 1;
}

// ------------------------------------------------------------------
// Called from Hook_TraceAttack (survivor headshot-eligible hitgroup
// context already filtered by the caller isn't required - we record
// every qualifying hit and classify headshot ourselves) when a shot
// lands on a Special Infected AND a TargetAcq session for that same
// target was open (so we have a real acquisition-to-shot time, not a
// guess). `decisionTimeMs` < 0 means no matching open session - skip.
void ShotDecision_RecordShot(int attacker, int victim, int hitgroup, float decisionTimeMs, float rangeUnits)
{
    #pragma unused victim // already resolved by the caller via TargetAcq_GetRecentDecisionTimeMs; kept in the signature for API clarity
    if (decisionTimeMs < 0.0) return; // no acquisition context to correlate against

    SD_ShotRecord rec;
    rec.DecisionTimeMs = decisionTimeMs;
    rec.WeaponClass = SD_ClassifyWeapon(attacker);
    rec.RangeBand = SD_RangeBand(rangeUnits);
    rec.WasHeadshot = (hitgroup == 1); // HITGROUP_HEAD, kept as a literal to avoid a cross-file #define dependency
    rec.RecordedAt = GetGameTime();

    int idx = g_SD_HistoryHead[attacker];
    g_SD_History[attacker][idx] = rec;
    g_SD_HistoryHead[attacker] = (idx + 1) % SD_HISTORY;
    if (g_SD_HistoryCount[attacker] < SD_HISTORY) g_SD_HistoryCount[attacker]++;

    int score = ShotDecision_GetScore(attacker);
    if (score > 0) Correlation_ReportEvent(attacker, CORR_DET_SHOTDECISION, score);
}

// ------------------------------------------------------------------
// Bucket key: weapon class x range band (2 x 3 = 6 possible buckets).
static int SD_BucketKey(ShotWeaponClass wc, int rangeBand)
{
    return (view_as<int>(wc) * 3) + rangeBand;
}

// ------------------------------------------------------------------
// Score: bucket shots by (weapon class, range band) - contexts a human
// genuinely handles differently - and compare mean decision time ACROSS
// buckets. Human timing should shift meaningfully between "close range
// SMG spray" and "far precision rifle shot"; if a player's mean decision
// time stays essentially flat across genuinely different buckets despite
// having enough samples in each, that flatness itself is the signature
// of a script that doesn't model context at all.
int ShotDecision_GetScore(int client)
{
    int total = g_SD_HistoryCount[client];
    if (total < SD_MIN_SHOTS_PER_BUCKET * SD_MIN_BUCKETS) return 0;

    float now = GetGameTime();

    // Up to 6 buckets (2 weapon classes x 3 range bands). Accumulate
    // sum/count per bucket in fixed-size arrays rather than a dynamic
    // structure - the key space is small and known.
    float bucketSum[6];
    int bucketCount[6];

    for (int i = 0; i < total; i++)
    {
        if (now - g_SD_History[client][i].RecordedAt > SD_HISTORY_EXPIRE_SECONDS) continue;
        if (g_SD_History[client][i].WeaponClass == SHOTCLASS_UNKNOWN) continue;

        int key = SD_BucketKey(g_SD_History[client][i].WeaponClass, g_SD_History[client][i].RangeBand);
        bucketSum[key] += g_SD_History[client][i].DecisionTimeMs;
        bucketCount[key]++;
    }

    // Collect the qualifying bucket means (buckets with enough samples).
    float means[6];
    int populatedBuckets = 0;
    float grandSum = 0.0;
    int grandCount = 0;

    for (int k = 0; k < 6; k++)
    {
        if (bucketCount[k] < SD_MIN_SHOTS_PER_BUCKET) continue;
        means[populatedBuckets] = bucketSum[k] / float(bucketCount[k]);
        populatedBuckets++;
        grandSum += bucketSum[k];
        grandCount += bucketCount[k];
    }

    if (populatedBuckets < SD_MIN_BUCKETS) return 0; // not enough distinct contexts to compare

    float grandMean = grandSum / float(grandCount);

    // Variance OF THE BUCKET MEANS around the grand mean - this measures
    // how much decision timing shifts between genuinely different
    // contexts, which is exactly what should NOT be flat for a human.
    float varSum = 0.0;
    for (int b = 0; b < populatedBuckets; b++)
    {
        float d = means[b] - grandMean;
        varSum += d * d;
    }
    float varBetweenBuckets = varSum / float(populatedBuckets);
    float stddevBetweenBuckets = SquareRoot(varBetweenBuckets);

    // Coefficient of variation of the between-bucket means relative to
    // the grand mean - scale-independent, same reasoning as the other
    // variance-profiling modules. Humans typically shift decision timing
    // by well over 20-30% between a close rapid-fire shot and a far
    // precision one; a context-blind script stays far flatter than that.
    float cov = (grandMean > 1.0) ? (stddevBetweenBuckets / grandMean) : 1.0;

    if (cov >= 0.20) return 0; // human range - timing genuinely differs by context

    return RoundFloat(SD_FMin((0.20 - cov) / 0.18 * 100.0, 100.0));
}
