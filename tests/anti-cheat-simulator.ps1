<#
Offline regression simulator for the anti-cheat decision pipeline.

It deliberately tests the policy after each detector has emitted a score:
score folding, weighted risk, correlation, evidence classification, and the
confirmation gate.  It does not pretend to emulate L4D2 engine hooks; those
need replay data from an actual server.
#>
[CmdletBinding()]
param(
    [string]$Scenarios = (Join-Path $PSScriptRoot 'scenarios.json'),
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $root 'anticheat_core.sp'
$correlationPath = Join-Path $root 'anticheat_correlation.sp'
$evidencePath = Join-Path $root 'anticheat_evidence.sp'

function Get-DefineNumber {
    param([string]$Source, [string]$Name)
    $match = [regex]::Match($Source, "(?m)^#define\s+$Name\s+([0-9]+(?:\.[0-9]+)?)")
    if (-not $match.Success) { throw "No se encontro #define $Name." }
    return [double]::Parse($match.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-Value {
    param($Object, [string]$Name, [double]$Default = 0)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return [double]$property.Value
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-Highest {
    param($Object, [string[]]$Names)
    $highest = 0.0
    foreach ($name in $Names) {
        $value = Get-Value $Object $name
        if ($value -gt $highest) { $highest = $value }
    }
    return $highest
}

function Get-Correlation {
    param($Events, [hashtable]$Policy)
    if ($null -eq $Events -or @($Events).Count -eq 0) {
        return @{ Multiplier = 1.0; Distinct = 0 }
    }

    $bestDistinct = 0
    $bestAverage = 0.0
    foreach ($anchor in @($Events)) {
        if ((Get-Value $anchor 'age') -gt $Policy.CorrelationLookback) { continue }
        $detectors = @{}
        $severityTotal = 0.0
        $count = 0
        foreach ($event in @($Events)) {
            if ([math]::Abs((Get-Value $event 'age') - (Get-Value $anchor 'age')) -gt $Policy.CorrelationWindow) { continue }
            $detector = [string]$event.detector
            $detectors[$detector] = $true
            $severityTotal += Get-Value $event 'severity'
            $count++
        }
        if ($detectors.Count -gt $bestDistinct) {
            $bestDistinct = $detectors.Count
            $bestAverage = if ($count -gt 0) { $severityTotal / $count } else { 0.0 }
        }
    }

    if ($bestDistinct -lt $Policy.CorrelationMinimum) {
        return @{ Multiplier = 1.0; Distinct = $bestDistinct }
    }
    $bonus = ($bestDistinct - $Policy.CorrelationMinimum + 1) * 0.15 * (0.5 + 0.5 * ($bestAverage / 100.0))
    return @{ Multiplier = [math]::Min(1.0 + $bonus, $Policy.CorrelationMaximum); Distinct = $bestDistinct }
}

$core = Get-Content -Raw -LiteralPath $corePath
$correlation = Get-Content -Raw -LiteralPath $correlationPath
$evidence = Get-Content -Raw -LiteralPath $evidencePath
$policy = @{
    AimWeight = Get-DefineNumber $core 'WEIGHT_AIM'
    BhopWeight = Get-DefineNumber $core 'WEIGHT_BHOP'
    IntegrityWeight = Get-DefineNumber $core 'WEIGHT_INTEGRITY'
    NoLerpWeight = Get-DefineNumber $core 'WEIGHT_NOLERP'
    OsacWeight = Get-DefineNumber $core 'WEIGHT_OSAC'
    MacroWeight = Get-DefineNumber $core 'WEIGHT_MACRO'
    NoteThreshold = Get-DefineNumber $core 'SCORE_THRESHOLD_NOTE'
    WarnThreshold = Get-DefineNumber $core 'SCORE_THRESHOLD_WARN'
    BanThreshold = Get-DefineNumber $core 'SCORE_THRESHOLD_BAN'
    StrongModuleThreshold = Get-DefineNumber $core 'STRONG_MODULE_THRESHOLD'
    BanConfirmations = Get-DefineNumber $core 'BAN_CONFIRMATIONS'
    LogicBreachThreshold = Get-DefineNumber $evidence 'EVIDENCE_LOGICBREACH_MIN_SCORE'
    CorrelationWindow = Get-DefineNumber $correlation 'CORR_CLUSTER_WINDOW'
    CorrelationLookback = Get-DefineNumber $correlation 'CORR_LOOKBACK_SECONDS'
    CorrelationMaximum = Get-DefineNumber $correlation 'CORR_MAX_MULTIPLIER'
    CorrelationMinimum = Get-DefineNumber $correlation 'CORR_MIN_DISTINCT_FOR_BONUS'
}

if ([math]::Abs(($policy.AimWeight + $policy.BhopWeight + $policy.IntegrityWeight + $policy.NoLerpWeight + $policy.OsacWeight + $policy.MacroWeight) - 1.0) -gt 0.00001) {
    throw 'Los pesos extraidos no suman 1.0.'
}

$suite = Get-Content -Raw -LiteralPath $Scenarios | ConvertFrom-Json
$failed = 0
$passed = 0

foreach ($scenario in @($suite.scenarios)) {
    $streak = 0
    $last = $null
    foreach ($evaluation in @($scenario.evaluations)) {
        $aim = Get-Highest $evaluation @('aim', 'targetAcq', 'aimVariance', 'shotDecision', 'aimDrift', 'tracking', 'aimHoneypot', 'klDivergence')
        $bhop = Get-Highest $evaluation @('bhop', 'bhop2', 'bhopVariance')
        $integrity = Get-Value $evaluation 'integrity'
        $noLerp = Get-Value $evaluation 'noLerp'
        $osac = Get-Value $evaluation 'osac'
        $macro = Get-Value $evaluation 'macro'
        $correlationResult = Get-Correlation (Get-PropertyValue $evaluation 'events') $policy
        $rawRisk = $aim * $policy.AimWeight + $bhop * $policy.BhopWeight + $integrity * $policy.IntegrityWeight + $noLerp * $policy.NoLerpWeight + $osac * $policy.OsacWeight + $macro * $policy.MacroWeight
        $risk = [math]::Min([math]::Round($rawRisk * $correlationResult.Multiplier, 0, [MidpointRounding]::AwayFromZero), 100)
        $worst = [math]::Max($aim, [math]::Max($bhop, [math]::Max($integrity, [math]::Max($noLerp, $osac))))
        $logicBreach = $integrity -ge $policy.LogicBreachThreshold -or $noLerp -ge $policy.LogicBreachThreshold -or $osac -ge $policy.LogicBreachThreshold
        if ($logicBreach) { $level = 'VIOLATION' }
        elseif ($correlationResult.Distinct -ge 2 -and $correlationResult.Multiplier -gt 1.0) { $level = 'CORRELATED' }
        elseif ($risk -ge $policy.NoteThreshold) { $level = 'STATISTICAL' }
        else { $level = 'INFO' }

        if ((Get-Value $evaluation 'unstable') -ne 0) {
            $streak = 0; $action = 'SKIPPED_UNSTABLE_CONNECTION'
        }
        elseif ($risk -lt $policy.BanThreshold) {
            $streak = 0
            $action = if ($risk -ge $policy.WarnThreshold) { 'WARN' } elseif ($risk -ge $policy.NoteThreshold) { 'NOTE' } else { 'NONE' }
        }
        elseif ($worst -lt $policy.StrongModuleThreshold) {
            $streak = 0; $action = 'NO_KICK_INSUFFICIENT_EVIDENCE'
        }
        else {
            $streak++
            $needed = if ($level -eq 'VIOLATION') { 1 } else { [int]$policy.BanConfirmations }
            $action = if ($streak -ge $needed) { 'KICK' } else { 'AWAITING_CONFIRMATION' }
        }
        $last = [pscustomobject]@{ Risk = [int]$risk; Level = $level; Action = $action; Streak = $streak; Aim = $aim; Bhop = $bhop; Correlation = $correlationResult.Multiplier }
    }

    $expected = $scenario.expected
    $ok = $last.Risk -eq [int]$expected.risk -and $last.Level -eq [string]$expected.level -and $last.Action -eq [string]$expected.action
    if ($ok) {
        $passed++
        if (-not $Quiet) { "PASS  {0,-32} risk={1} level={2} action={3}" -f $scenario.name, $last.Risk, $last.Level, $last.Action }
    } else {
        $failed++
        "FAIL  {0} expected risk={1}/level={2}/action={3}; got risk={4}/level={5}/action={6}" -f $scenario.name, $expected.risk, $expected.level, $expected.action, $last.Risk, $last.Level, $last.Action
    }
}

"`nResultado: $passed aprobados, $failed fallidos."
if ($failed -gt 0) { exit 1 }
