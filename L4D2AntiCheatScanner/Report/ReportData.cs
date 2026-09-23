using System;
using System.Collections.Generic;
using L4D2AntiCheatScanner.Core;
using L4D2AntiCheatScanner.Evidence;

namespace L4D2AntiCheatScanner.Report
{
    public class ReportData
    {
        public string Title { get; set; } = "L4D2 Anti-Cheat Scanner Report";
        public string Disclaimer { get; set; } = "Este resultado es una detección heurística y no constituye una prueba absoluta de cheating.";
        public DateTime GeneratedAt { get; set; } = DateTime.Now;
        public ScanContext Context { get; set; } = new ScanContext();
        public EvidenceLevel OverallRiskLevel { get; set; }
        public int TotalScore { get; set; }
        public (int info, int suspicious, int highRisk, int critical) SummaryCounts { get; set; }
        public List<Finding> Findings { get; set; } = new List<Finding>();
    }
}

