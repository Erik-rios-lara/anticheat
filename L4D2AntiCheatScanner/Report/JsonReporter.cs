using System;
using System.IO;
using System.Text.Json;
using L4D2AntiCheatScanner.Logging;

namespace L4D2AntiCheatScanner.Report
{
    public static class JsonReporter
    {
        public static string GenerateReport(ReportData data)
        {
            string reportsDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "reports");
            if (!Directory.Exists(reportsDir))
            {
                Directory.CreateDirectory(reportsDir);
            }

            string filename = $"report_{DateTime.Now:yyyyMMdd_HHmmss}.json";
            string filePath = Path.Combine(reportsDir, filename);

            try
            {
                var options = new JsonSerializerOptions { WriteIndented = true };
                string json = JsonSerializer.Serialize(data, options);
                File.WriteAllText(filePath, json);
                ScanLogger.Info($"Reporte JSON generado exitosamente en: {filePath}");
                return filePath;
            }
            catch (Exception ex)
            {
                ScanLogger.Error("Error al generar reporte JSON", ex);
                return string.Empty;
            }
        }
    }
}

