using System;
using System.Security.Principal;
using L4D2AntiCheatScanner.Evidence;
using L4D2AntiCheatScanner.Logging;
using L4D2AntiCheatScanner.Modules;
using L4D2AntiCheatScanner.Report;

namespace L4D2AntiCheatScanner.Core
{
    public class Scanner
    {
        private ScanContext context;
        private RiskEngine riskEngine;

        public Scanner()
        {
            context = new ScanContext();
            riskEngine = new RiskEngine();
        }

        private void InitializeScan()
        {
            context.IsAdmin = CheckIfAdmin();
            if (context.IsAdmin)
            {
                ScanLogger.Info("Ejecutando con privilegios de Administrador.");
            }
            else
            {
                ScanLogger.Warning("Ejecutando SIN privilegios de Administrador. El escaneo de memoria y procesos estará limitado.");
            }

            ScanLogger.Info("Buscando instalación de Left 4 Dead 2...");
            context.GameDirectory = SteamLocator.FindLeft4Dead2();

            if (!string.IsNullOrEmpty(context.GameDirectory))
            {
                ScanLogger.Info($"Left 4 Dead 2 encontrado en: {context.GameDirectory}");
            }
            else
            {
                ScanLogger.Warning("Left 4 Dead 2 no se encontró automáticamente.");
            }
        }

        public void RunFastScan()
        {
            InitializeScan();
            ScanLogger.Info("Iniciando FAST SCAN...");

            // Módulos
            ProcessScanner.Scan(context, riskEngine);
            ModuleScanner.Scan(context, riskEngine);
            MemoryScanner.Scan(context, riskEngine);
            FileScanner.ScanCriticalLocations(context, riskEngine);
            PersistenceScanner.Scan(context, riskEngine);
            HashScanner.ScanHashes(context, riskEngine);

            ScanLogger.Info("Escaneo completado.");
            GenerateAndPrintReports();
        }

        public void RunGameScan()
        {
            InitializeScan();
            ScanLogger.Info("Iniciando GAME SCAN...");

            // Módulos
            ProcessScanner.Scan(context, riskEngine);
            ModuleScanner.Scan(context, riskEngine);
            MemoryScanner.Scan(context, riskEngine);
            FileScanner.ScanGameDirectory(context, riskEngine);
            FileScanner.ScanCriticalLocations(context, riskEngine);
            PersistenceScanner.Scan(context, riskEngine);
            HashScanner.ScanHashes(context, riskEngine);

            ScanLogger.Info("Escaneo completado.");
            GenerateAndPrintReports();
        }

        public void RunDeepScan()
        {
            InitializeScan();
            ScanLogger.Info("Iniciando DEEP SCAN...");

            // Módulos
            ProcessScanner.Scan(context, riskEngine);
            ModuleScanner.Scan(context, riskEngine);
            MemoryScanner.Scan(context, riskEngine);
            FileScanner.ScanGameDirectory(context, riskEngine);
            FileScanner.ScanCriticalLocations(context, riskEngine);
            PersistenceScanner.Scan(context, riskEngine);
            HashScanner.ScanHashes(context, riskEngine);

            ScanLogger.Info("Escaneo completado.");
            GenerateAndPrintReports();
        }

        private bool CheckIfAdmin()
        {
            try
            {
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                {
                    WindowsPrincipal principal = new WindowsPrincipal(identity);
                    return principal.IsInRole(WindowsBuiltInRole.Administrator);
                }
            }
            catch
            {
                return false;
            }
        }

        private void GenerateAndPrintReports()
        {
            var counts = riskEngine.GetCounts();
            var overallLevel = riskEngine.GetOverallRiskLevel();
            int totalScore = riskEngine.CalculateTotalScore();

            var reportData = new ReportData
            {
                Context = context,
                OverallRiskLevel = overallLevel,
                TotalScore = totalScore,
                SummaryCounts = counts,
                Findings = new System.Collections.Generic.List<Finding>(riskEngine.Findings)
            };

            string jsonPath = JsonReporter.GenerateReport(reportData);
            string htmlPath = HtmlReporter.GenerateReport(reportData);

            Console.WriteLine("");
            Console.WriteLine("==================================================");
            Console.WriteLine($"RESULTADO GENERAL: [{overallLevel}] (Score total: {totalScore})");
            Console.WriteLine("==================================================");
            Console.WriteLine("Resumen de Hallazgos:");
            Console.WriteLine($"  INFO       : {counts.info}");
            Console.WriteLine($"  SUSPICIOUS : {counts.suspicious}");
            Console.WriteLine($"  HIGH RISK  : {counts.highRisk}");
            Console.WriteLine($"  CRITICAL   : {counts.critical}");
            Console.WriteLine("==================================================");

            if (riskEngine.Findings.Count > 0)
            {
                Console.WriteLine("\nDetalle de Hallazgos:");
                foreach (var finding in riskEngine.Findings)
                {
                    Console.WriteLine($" - {finding}");
                }
            }
            else
            {
                Console.WriteLine("No se detectaron indicadores de riesgo.");
            }

            Console.WriteLine("");
            Console.WriteLine($"Reporte JSON generado en: {jsonPath}");
            Console.WriteLine($"Reporte HTML generado en: {htmlPath}");
            Console.WriteLine("");
        }
    }
}
