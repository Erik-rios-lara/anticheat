using System;
using System.Diagnostics;
using System.IO;
using L4D2AntiCheatScanner.Core;
using L4D2AntiCheatScanner.Evidence;
using L4D2AntiCheatScanner.Logging;

namespace L4D2AntiCheatScanner.Modules
{
    public static class ModuleScanner
    {
        public static void Scan(ScanContext context, RiskEngine riskEngine)
        {
            ScanLogger.Info("Escaneando módulos y DLLs cargadas en Left 4 Dead 2...");

            Process[] l4d2Processes = Process.GetProcessesByName("left4dead2");

            if (l4d2Processes.Length == 0)
            {
                ScanLogger.Info("Left 4 Dead 2 no está en ejecución actualmente. (Se omitió análisis de módulos en vivo).");
                return;
            }

            string tempPath = Path.GetTempPath().TrimEnd('\\');
            string appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData).TrimEnd('\\');
            string localAppDataPath = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData).TrimEnd('\\');
            string system32Path = Environment.GetFolderPath(Environment.SpecialFolder.System).TrimEnd('\\');
            string sysWow64Path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "SysWOW64");

            foreach (var proc in l4d2Processes)
            {
                ScanLogger.Info($"Analizando DLLs cargadas en el proceso '{proc.ProcessName}' (PID: {proc.Id})...");

                try
                {
                    ProcessModuleCollection modules = proc.Modules;
                    int moduleCount = 0;

                    foreach (ProcessModule module in modules)
                    {
                        moduleCount++;
                        string fileName = module.ModuleName;
                        string filePath = module.FileName;

                        if (string.IsNullOrEmpty(filePath))
                            continue;

                        // Categorizar origen
                        bool isWindowsDll = filePath.StartsWith(system32Path, StringComparison.OrdinalIgnoreCase) ||
                                           filePath.StartsWith(sysWow64Path, StringComparison.OrdinalIgnoreCase);

                        bool isGameDll = !string.IsNullOrEmpty(context.GameDirectory) &&
                                        filePath.StartsWith(context.GameDirectory, StringComparison.OrdinalIgnoreCase);

                        bool isUserPath = filePath.StartsWith(tempPath, StringComparison.OrdinalIgnoreCase) ||
                                          filePath.StartsWith(appDataPath, StringComparison.OrdinalIgnoreCase) ||
                                          filePath.StartsWith(localAppDataPath, StringComparison.OrdinalIgnoreCase);

                        var sig = SignatureChecker.CheckSignature(filePath);

                        // 1. DLL cargada desde Temp/AppData en proceso del juego
                        if (isUserPath)
                        {
                            int score = sig.IsSigned ? 20 : 50;
                            var level = sig.IsSigned ? EvidenceLevel.SUSPICIOUS : EvidenceLevel.HIGH_RISK;

                            riskEngine.AddFinding(new Finding
                            {
                                Category = "DLL_UBICACION_SOSPECHOSA",
                                Level = level,
                                Description = $"DLL cargada en L4D2 desde directorio de usuario: '{filePath}' (Firmado: {sig.IsSigned}, Publisher: {sig.Publisher})",
                                PID = proc.Id,
                                ProcessName = proc.ProcessName,
                                FilePath = filePath,
                                ScoreAmount = score
                            });
                        }
                        // 2. DLL sin firma y fuera del juego/windows/steam
                        else if (!isWindowsDll && !isGameDll && !sig.IsSigned)
                        {
                            riskEngine.AddFinding(new Finding
                            {
                                Category = "DLL_SIN_FIRMA_DESCONOCIDA",
                                Level = EvidenceLevel.SUSPICIOUS,
                                Description = $"DLL no firmada cargada desde ubicación externa: '{filePath}'",
                                PID = proc.Id,
                                ProcessName = proc.ProcessName,
                                FilePath = filePath,
                                ScoreAmount = 15
                            });
                        }
                        // 3. Módulos reconocidos/info
                        else
                        {
                            riskEngine.AddFinding(new Finding
                            {
                                Category = "DLL_CARGADA",
                                Level = EvidenceLevel.INFO,
                                Description = $"DLL: '{fileName}' | Publisher: {sig.Publisher} | Ruta: {filePath}",
                                PID = proc.Id,
                                ProcessName = proc.ProcessName,
                                FilePath = filePath,
                                ScoreAmount = 0
                            });
                        }
                    }

                    ScanLogger.Info($"Se inspeccionaron {moduleCount} módulos en el proceso PID {proc.Id}.");
                }
                catch (System.ComponentModel.Win32Exception ex)
                {
                    ScanLogger.Warning($"No se pudieron enumerar los módulos del proceso PID {proc.Id} (Acceso denegado o arquitectura 32/64 bit mismatch: {ex.Message}).");
                    riskEngine.AddFinding(new Finding
                    {
                        Category = "MODULOS_ACCESO_DENEGADO",
                        Level = EvidenceLevel.INFO,
                        Description = $"No se pudo acceder a los módulos de PID {proc.Id}: {ex.Message}. Intente ejecutar como Administrador.",
                        PID = proc.Id,
                        ProcessName = proc.ProcessName,
                        FilePath = context.GameDirectory,
                        ScoreAmount = 0
                    });
                }
                catch (Exception ex)
                {
                    ScanLogger.Error($"Error al analizar módulos de PID {proc.Id}", ex);
                }
            }
        }
    }
}

