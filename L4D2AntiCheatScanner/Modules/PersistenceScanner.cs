using System;
using System.IO;
using Microsoft.Win32;
using L4D2AntiCheatScanner.Core;
using L4D2AntiCheatScanner.Evidence;
using L4D2AntiCheatScanner.Logging;

namespace L4D2AntiCheatScanner.Modules
{
    public static class PersistenceScanner
    {
        public static void Scan(ScanContext context, RiskEngine riskEngine)
        {
            ScanLogger.Info("Escaneando mecanísmos de persistencia en el sistema (Solo lectura)...");

            // 1. Escaneo de registro Run (HKCU y HKLM)
            ScanRegistryRunKey(Registry.CurrentUser, @"Software\Microsoft\Windows\CurrentVersion\Run", "HKCU_RUN", riskEngine);
            ScanRegistryRunKey(Registry.LocalMachine, @"Software\Microsoft\Windows\CurrentVersion\Run", "HKLM_RUN", riskEngine);

            // 2. Escaneo de carpeta Startup del usuario
            string startupPath = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
            if (Directory.Exists(startupPath))
            {
                try
                {
                    string[] files = Directory.GetFiles(startupPath, "*.*");
                    foreach (var file in files)
                    {
                        var sig = SignatureChecker.CheckSignature(file);
                        riskEngine.AddFinding(new Finding
                        {
                            Category = "PERSISTENCIA_STARTUP_FOLDER",
                            Level = sig.IsSigned ? EvidenceLevel.INFO : EvidenceLevel.SUSPICIOUS,
                            Description = $"Elemento en inicio automático (Startup Folder): '{Path.GetFileName(file)}' (Firmado: {sig.IsSigned})",
                            PID = 0,
                            ProcessName = "-",
                            FilePath = file,
                            ScoreAmount = sig.IsSigned ? 0 : 15
                        });
                    }
                }
                catch (Exception ex)
                {
                    ScanLogger.Error("Error al escanear carpeta de inicio (Startup)", ex);
                }
            }
        }

        private static void ScanRegistryRunKey(RegistryKey rootKey, string subKeyPath, string category, RiskEngine riskEngine)
        {
            try
            {
                using (var key = rootKey.OpenSubKey(subKeyPath, false))
                {
                    if (key == null) return;

                    foreach (var valueName in key.GetValueNames())
                    {
                        string value = key.GetValue(valueName)?.ToString() ?? "";
                        if (string.IsNullOrEmpty(value)) continue;

                        // Extraer posible ruta limpia
                        string cleanPath = value.Replace("\"", "").Trim();
                        int exeIdx = cleanPath.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
                        if (exeIdx > 0)
                        {
                            cleanPath = cleanPath.Substring(0, exeIdx + 4);
                        }

                        if (File.Exists(cleanPath))
                        {
                            var sig = SignatureChecker.CheckSignature(cleanPath);
                            if (!sig.IsSigned)
                            {
                                riskEngine.AddFinding(new Finding
                                {
                                    Category = $"PERSISTENCIA_REGISTRO_{category}",
                                    Level = EvidenceLevel.SUSPICIOUS,
                                    Description = $"Clave de inicio automático sin firma digital: '{valueName}' -> '{cleanPath}'",
                                    PID = 0,
                                    ProcessName = valueName,
                                    FilePath = cleanPath,
                                    ScoreAmount = 15
                                });
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                ScanLogger.Error($"Error al consultar registro {subKeyPath}", ex);
            }
        }
    }
}

