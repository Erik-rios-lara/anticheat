using System;
using System.IO;
using System.Text;
using L4D2AntiCheatScanner.Logging;

namespace L4D2AntiCheatScanner.Report
{
    public static class HtmlReporter
    {
        public static string GenerateReport(ReportData data)
        {
            string reportsDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "reports");
            if (!Directory.Exists(reportsDir))
            {
                Directory.CreateDirectory(reportsDir);
            }

            string filename = $"report_{DateTime.Now:yyyyMMdd_HHmmss}.html";
            string filePath = Path.Combine(reportsDir, filename);

            try
            {
                var sb = new StringBuilder();
                sb.AppendLine("<!DOCTYPE html>");
                sb.AppendLine("<html lang=\"es\">");
                sb.AppendLine("<head>");
                sb.AppendLine("  <meta charset=\"UTF-8\">");
                sb.AppendLine("  <title>L4D2 Anti-Cheat Scanner Report</title>");
                sb.AppendLine("  <style>");
                sb.AppendLine("    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #121212; color: #e0e0e0; margin: 0; padding: 20px; }");
                sb.AppendLine("    .container { max-width: 900px; margin: auto; background: #1e1e1e; padding: 25px; border-radius: 8px; box-shadow: 0 4px 15px rgba(0,0,0,0.5); }");
                sb.AppendLine("    h1 { color: #ffffff; border-bottom: 2px solid #333; padding-bottom: 10px; }");
                sb.AppendLine("    .disclaimer { background: #332b00; border-left: 4px solid #ffcc00; padding: 12px; margin-bottom: 20px; font-size: 0.9em; }");
                sb.AppendLine("    .badge { padding: 5px 12px; border-radius: 4px; font-weight: bold; display: inline-block; }");
                sb.AppendLine("    .CRITICAL { background: #721c24; color: #f8d7da; }");
                sb.AppendLine("    .HIGH_RISK { background: #856404; color: #fff3cd; }");
                sb.AppendLine("    .SUSPICIOUS { background: #383d41; color: #e2e3e5; }");
                sb.AppendLine("    .INFO { background: #155724; color: #d4edda; }");
                sb.AppendLine("    table { width: 100%; border-collapse: collapse; margin-top: 15px; }");
                sb.AppendLine("    th, td { text-align: left; padding: 10px; border-bottom: 1px solid #333; }");
                sb.AppendLine("    th { background: #252526; }");
                sb.AppendLine("  </style>");
                sb.AppendLine("</head>");
                sb.AppendLine("<body>");
                sb.AppendLine("  <div class=\"container\">");
                sb.AppendLine($"    <h1>{data.Title}</h1>");
                sb.AppendLine($"    <div class=\"disclaimer\">⚠️ <strong>Aviso Importante:</strong> {data.Disclaimer}</div>");
                sb.AppendLine($"    <p><strong>Fecha de Generación:</strong> {data.GeneratedAt:yyyy-MM-dd HH:mm:ss}</p>");
                sb.AppendLine($"    <p><strong>Ruta L4D2:</strong> {data.Context.GameDirectory}</p>");
                sb.AppendLine($"    <h2>Nivel de Riesgo Global: <span class=\"badge {data.OverallRiskLevel}\">{data.OverallRiskLevel}</span> (Puntuación: {data.TotalScore})</h2>");

                sb.AppendLine("    <h3>Resumen de Hallazgos</h3>");
                sb.AppendLine("    <ul>");
                sb.AppendLine($"      <li><strong>INFO:</strong> {data.SummaryCounts.info}</li>");
                sb.AppendLine($"      <li><strong>SUSPICIOUS:</strong> {data.SummaryCounts.suspicious}</li>");
                sb.AppendLine($"      <li><strong>HIGH RISK:</strong> {data.SummaryCounts.highRisk}</li>");
                sb.AppendLine($"      <li><strong>CRITICAL:</strong> {data.SummaryCounts.critical}</li>");
                sb.AppendLine("    </ul>");

                sb.AppendLine("    <h3>Detalle de Evidencias Técnicas</h3>");
                sb.AppendLine("    <table>");
                sb.AppendLine("      <thead><tr><th>Nivel</th><th>Categoría</th><th>Detalle / Evidencia</th><th>Puntos</th></tr></thead>");
                sb.AppendLine("      <tbody>");

                foreach (var f in data.Findings)
                {
                    sb.AppendLine($"        <tr>");
                    sb.AppendLine($"          <td><span class=\"badge {f.Level}\">{f.Level}</span></td>");
                    sb.AppendLine($"          <td>{f.Category}</td>");
                    sb.AppendLine($"          <td>{f.Description}</td>");
                    sb.AppendLine($"          <td>+{f.ScoreAmount}</td>");
                    sb.AppendLine($"        </tr>");
                }

                sb.AppendLine("      </tbody>");
                sb.AppendLine("    </table>");
                sb.AppendLine("  </div>");
                sb.AppendLine("</body>");
                sb.AppendLine("</html>");

                File.WriteAllText(filePath, sb.ToString());
                ScanLogger.Info($"Reporte HTML generado exitosamente en: {filePath}");
                return filePath;
            }
            catch (Exception ex)
            {
                ScanLogger.Error("Error al generar reporte HTML", ex);
                return string.Empty;
            }
        }
    }
}

