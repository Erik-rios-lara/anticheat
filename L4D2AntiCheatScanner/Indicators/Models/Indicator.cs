namespace L4D2AntiCheatScanner.Indicators.Models
{
    public class Indicator
    {
        public string Hash { get; set; } = "";
        public string Type { get; set; } = "file"; // dll, exe, file
        public string Name { get; set; } = "";
        public string Severity { get; set; } = "high"; // low, medium, high, critical
        public string Description { get; set; } = "";
    }
}

