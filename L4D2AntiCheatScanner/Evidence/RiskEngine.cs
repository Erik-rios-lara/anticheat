using System;
using System.Collections.Generic;
using System.Linq;

namespace L4D2AntiCheatScanner.Evidence
{
    public class RiskEngine
    {
        private readonly List<Finding> findings = new List<Finding>();

        public void AddFinding(Finding finding)
        {
            findings.Add(finding);
        }

        public IReadOnlyList<Finding> Findings => findings.AsReadOnly();

        public int CalculateTotalScore()
        {
            return findings.Sum(f => f.ScoreAmount);
        }

        public EvidenceLevel GetOverallRiskLevel()
        {
            int score = CalculateTotalScore();

            if (score >= 90 || findings.Any(f => f.Level == EvidenceLevel.CRITICAL))
                return EvidenceLevel.CRITICAL;
            if (score >= 60 || findings.Any(f => f.Level == EvidenceLevel.HIGH_RISK))
                return EvidenceLevel.HIGH_RISK;
            if (score >= 20 || findings.Any(f => f.Level == EvidenceLevel.SUSPICIOUS))
                return EvidenceLevel.SUSPICIOUS;

            return EvidenceLevel.INFO;
        }

        public (int info, int suspicious, int highRisk, int critical) GetCounts()
        {
            int info = findings.Count(f => f.Level == EvidenceLevel.INFO);
            int suspicious = findings.Count(f => f.Level == EvidenceLevel.SUSPICIOUS);
            int highRisk = findings.Count(f => f.Level == EvidenceLevel.HIGH_RISK);
            int critical = findings.Count(f => f.Level == EvidenceLevel.CRITICAL);

            return (info, suspicious, highRisk, critical);
        }
    }
}

