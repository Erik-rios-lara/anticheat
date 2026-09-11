// anticheat_evidence.sp - Tiered Evidence Model
//
// Everything downstream of the 5 detection modules used to collapse into
// a single 0-100 integer (totalRisk) and a handful of magic-number
// comparisons against it (>=15 note, >=35 warn, >=50 kick-candidate).
// That number mixes together things that are conceptually different:
//   - how strong the accumulated behavioral tendency is (Risk Score)
//   - how sure we are that tendency reflects real evidence, not noise
//     (Confidence - shaped mainly by the correlation engine and by
//     whether any single module is itself a "logic breach" style check)
//   - how serious the worst single piece of evidence is on its own
//     (Severity - a hard engine-limit violation is categorically
//     different from a slightly-too-consistent snap size, even if both
//     currently map to similar point values)
//   - how much of it there is (Evidence Count - one flagged instant vs a
//     sustained pattern across many)
//
// This module doesn't replace any detector's math. It classifies the
// OUTPUT of Timer_Score's existing calculation (module scores + risk +
// correlation multiplier) into one of four evidence levels, and exposes
// the four numbers above as a small, explicit struct instead of a single
// blended integer. anticheat_core.sp uses the resulting level to decide
// action instead of comparing totalRisk directly against magic numbers,
// but the underlying scoring pipeline (weights, correlation, per-module
// gating) is unchanged.

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>

// ------------------------------------------------------------------
// The four evidence levels (see file header for the intent behind each).
enum EvidenceLevel
{
    EVLEVEL_INFO = 0,          // unusual but not enough evidence - no action
    EVLEVEL_STATISTICAL,       // repeated anomalous pattern - risk accumulates slowly
    EVLEVEL_CORRELATED,        // multiple independent detectors agree - high admin priority
    EVLEVEL_VIOLATION          // engine-rule-incompatible state - can act immediately
};

static char g_EvLevelNames[][16] = { "INFO", "STATISTICAL", "CORRELATED", "VIOLATION" };

// Public accessor - g_EvLevelNames itself stays file-scoped so callers go
// through one stable entry point instead of touching the raw array.
void Evidence_LevelName(EvidenceLevel level, char[] buffer, int maxlen)
{
    strcopy(buffer, maxlen, g_EvLevelNames[level]);
}

// ------------------------------------------------------------------
// The four separated numbers, plus the classified level. Passed by
// reference out of Evidence_Classify() rather than returned as a single
// blended score.
enum struct EvidenceReport
{
    int RiskScore;         // 0-100, the existing weighted-sum x correlation value (unchanged math)
    float Confidence;      // 0.0-1.0, how much this evaluation should be trusted
    int Severity;          // 0-100, how serious the single worst piece of evidence is
    int EvidenceCount;     // how many distinct correlated detectors contributed (>=1)
    EvidenceLevel Level;   // the classification below
}

// ------------------------------------------------------------------
// Which modules are "logic breach" style: near-zero false-positive by
// construction because they check something structurally/physically
// impossible rather than a statistical behavior tendency. A hit on one of
// these is high-confidence even in isolation. This mirrors the intent
// already documented per-module (Integrity, NoLerp, and OSAC's BoneLock/
// SilentAim/SpinBot sub-detectors), made explicit here instead of
// implicit in each module's comments.
//
// aimScore and bhopScore mix a "logic breach" sub-detector (Aimlock,
// bhop gravity honeypot) with statistical ones (headshot consistency,
// jump ratio) inside the same 0-100 number, so they can't be classified
// as purely one or the other from the final score alone - they're
// treated as statistical-strength here, and it's the correlation engine
// (which sees the raw per-sub-detector events) that recovers the
// distinction when it matters.
#define EVIDENCE_LOGICBREACH_MIN_SCORE 60  // integrity/nolerp/osac score at/above this = logic-breach-strength hit

// ------------------------------------------------------------------
// Classify one risk evaluation. `moduleScores`/`moduleIsLogicBreach` let
// the caller mark which of the per-module scores come from
// near-certain-by-construction checks (Integrity, NoLerp, OSAC) versus
// primarily-statistical ones (Aim, Bhop) - see comment above.
void Evidence_Classify(
    int totalRisk,              // already weight-summed AND correlation-multiplied (unchanged pipeline output)
    float correlationMultiplier,
    int correlationDistinctCount, // Correlation_GetMultiplier's underlying distinct-detector count for this evaluation
    const int moduleScores[5],   // aim, bhop, integrity, nolerp, osac - in that fixed order
    EvidenceReport report)
{
    report.RiskScore = totalRisk;

    // --- Evidence count ---
    // At minimum, "1" (something produced a nonzero score at all). The
    // correlation engine's distinct-detector count is a direct, already
    // computed measure of how many independent sources agree - use it
    // when it's more than the trivial 1.
    report.EvidenceCount = (correlationDistinctCount > 1) ? correlationDistinctCount : 1;

    // --- Severity ---
    // The worst single module score this evaluation, unmultiplied. This
    // deliberately does NOT include the correlation bonus - severity asks
    // "how bad is the worst individual piece of evidence", not "how
    // amplified is the combined picture" (that's Confidence's job).
    int worst = 0;
    for (int i = 0; i < 5; i++)
    {
        if (moduleScores[i] > worst) worst = moduleScores[i];
    }
    report.Severity = worst;

    // --- Confidence ---
    // Starts from how strong the worst module is (a 90/100 module score
    // is more trustworthy on its own than a 20/100 one), then gets
    // boosted by two independent signals of "this isn't noise":
    //   1. Correlation - multiple distinct detectors agreeing in a tight
    //      window is exactly the kind of cross-confirmation that turns
    //      suspicion into confidence.
    //   2. Logic-breach modules (Integrity, NoLerp, OSAC) hitting hard -
    //      these check structurally-impossible states, so a high score
    //      there is trustworthy even without correlation.
    float baseConfidence = float(worst) / 100.0;

    float corrBoost = (correlationMultiplier - 1.0) / 0.6; // correlation ranges 1.0-1.6 -> 0.0-1.0
    if (corrBoost < 0.0) corrBoost = 0.0;
    if (corrBoost > 1.0) corrBoost = 1.0;

    bool logicBreachHit =
           moduleScores[2] >= EVIDENCE_LOGICBREACH_MIN_SCORE  // integrity
        || moduleScores[3] >= EVIDENCE_LOGICBREACH_MIN_SCORE  // nolerp
        || moduleScores[4] >= EVIDENCE_LOGICBREACH_MIN_SCORE; // osac

    float confidence = baseConfidence;
    confidence += corrBoost * 0.25;
    if (logicBreachHit) confidence += 0.20;
    if (confidence > 1.0) confidence = 1.0;
    report.Confidence = confidence;

    // --- Level classification ---
    // VIOLATION: a logic-breach module fired hard on its own. These are
    // near-certain by construction (Fake Angles, Invalid Usercmd, NoLerp,
    // BoneLock, SilentAim, SpinBot) - the kind of state a legitimate
    // client structurally cannot produce. Correlation isn't required.
    if (logicBreachHit && worst >= EVIDENCE_LOGICBREACH_MIN_SCORE)
    {
        report.Level = EVLEVEL_VIOLATION;
        return;
    }

    // CORRELATED: multiple independent detectors agreed within the
    // correlation engine's tight time window. This is the "target enters
    // -> snap -> acquisition -> shot -> impact" chain the design calls
    // for - stronger than any single statistical score, even a high one.
    if (correlationDistinctCount >= 2 && correlationMultiplier > 1.0)
    {
        report.Level = EVLEVEL_CORRELATED;
        return;
    }

    // STATISTICAL: a real, repeated anomalous pattern from one or more
    // primarily-statistical modules (Aim, Bhop), but without independent
    // corroboration yet. Worth accumulating risk over time, not worth
    // acting on from a single evaluation.
    if (totalRisk >= SCORE_THRESHOLD_NOTE)
    {
        report.Level = EVLEVEL_STATISTICAL;
        return;
    }

    // INFO: below the notice threshold - unusual at most, not evidence.
    report.Level = EVLEVEL_INFO;
}

// ------------------------------------------------------------------
// Human-readable one-liner for logs: "VIOLATION risk=82 conf=0.95 sev=90 evid=1"
void Evidence_Describe(const EvidenceReport report, char[] buffer, int maxlen)
{
    FormatEx(buffer, maxlen, "%s risk=%d conf=%.2f sev=%d evid=%d",
             g_EvLevelNames[report.Level], report.RiskScore, report.Confidence,
             report.Severity, report.EvidenceCount);
}
