using System;

namespace L4D2AntiCheatScanner.Evidence
{
    public class Finding
    {
        public EvidenceLevel Level { get; set; }
        public string Category { get; set; }
        public string Description { get; set; }
        public int PID { get; set; }
        public string ProcessName { get; set; }
        public string FilePath { get; set; }
        public int ScoreAmount { get; set; } // Puntos que aporta este hallazgo
        public DateTime Timestamp { get; set; }

        public Finding()
        {
            Timestamp = DateTime.Now;
        }

        public override string ToString()
        {
            string processInfo = PID > 0 ? $" [PID: {PID} | {ProcessName}]" : "";
            return $"[{Level}] {Category}:{processInfo} {Description} (Score: +{ScoreAmount})";
        }
    }
}

