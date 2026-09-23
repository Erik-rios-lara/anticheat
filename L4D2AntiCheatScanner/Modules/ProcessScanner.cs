using System;
using System.Diagnostics;
using System.IO;
using L4D2AntiCheatScanner.Core;
using L4D2AntiCheatScanner.Evidence;
using L4D2AntiCheatScanner.Logging;

namespace L4D2AntiCheatScanner.Modules
{
    public static class ProcessScanner
    {
        public static void Scan(ScanContext context, RiskEngine riskEngine)
        {
            ScanLogger.Info("Escaneando procesos activos en el sistema...");

            string tempPath = Path.GetTempPath().TrimEnd('\\');
            string appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData).TrimEnd('\\');
            string localAppDataPath = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData).TrimEnd('\\');
            string system32Path = Environment.GetFolderPath(Environment.SpecialFolder.System).TrimEnd('\\');

            Process[] processes = Process.GetProcesses();
            int scannedCount = 0;
            int errorCount = 0;

            foreach (var proc in processes)
            {
                try
                {
                    int pid = proc.Id;
                    string name = proc.ProcessName;

                    // Ignorar Idle y System
                    if (pid <= 4 || name.Equals("System", StringComparison.OrdinalIgnoreCase) || name.Equals("Idle", StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    string filePath = null;
                    try
                    {
                        filePath = proc.MainModule?.FileName;
                    }
                    catch
                    {
                        // Acceso denegado al intentar leer MainModule (común sin privilegios admin o en procesos de sistema)
                    }

                    scannedCount++;

                    if (string.IsNullOrEmpty(filePath))
                    {
                        // Registramos como info si no se pudo obtener ruta (sin admin)
                        continue;
                    }

                    // 1. Detectar ejecución desde ubicaciones sospechosas (%TEMP%, %APPDATA%, %LOCALAPPDATA%)
                    if (filePath.StartsWith(tempPath, StringComparison.OrdinalIgnoreCase) ||
                        filePath.StartsWith(appDataPath, StringComparison.OrdinalIgnoreCase) ||
                        filePath.StartsWith(localAppDataPath, StringComparison.OrdinalIgnoreCase))
                    {
                        var sig = SignatureChecker.CheckSignature(filePath);
                        int score = sig.IsSigned ? 10 : 25;

                        riskEngine.AddFinding(new Finding
                        {
                            Category = "PROCESO_UBICACION_SOSPECHOSA",
                            Level = sig.IsSigned ? EvidenceLevel.SUSPICIOUS : EvidenceLevel.HIGH_RISK,
                            Description = $"Proceso corriendo desde ubicación temporal/usuario: '{filePath}' (Firmado: {sig.IsSigned})",
                            PID = pid,
                            ProcessName = name,
                            FilePath = filePath,
                            ScoreAmount = score
                        });
                    }

                    // 2. Detectar imitación de procesos del sistema (ej. svchost.exe o lsass.exe corriendo fuera de System32)
                    if ((name.Equals("svchost", StringComparison.OrdinalIgnoreCase) ||
                         name.Equals("lsass", StringComparison.OrdinalIgnoreCase) ||
                         name.Equals("csrss", StringComparison.OrdinalIgnoreCase) ||
                         name.Equals("explorer", StringComparison.OrdinalIgnoreCase)) &&
                        !filePath.StartsWith(system32Path, StringComparison.OrdinalIgnoreCase) &&
                        !filePath.StartsWith(Path.GetDirectoryName(system32Path)!, StringComparison.OrdinalIgnoreCase))
                    {
                        riskEngine.AddFinding(new Finding
                        {
                            Category = "PROCESO_IMITACION_SISTEMA",
                            Level = EvidenceLevel.HIGH_RISK,
                            Description = $"Proceso crítico del sistema ejecutándose fuera del directorio legítimo: '{filePath}'",
                            PID = pid,
                            ProcessName = name,
                            FilePath = filePath,
                            ScoreAmount = 50
                        });
                    }

                    // 3. Detectar si Left 4 Dead 2 está activo
                    if (name.Equals("left4dead2", StringComparison.OrdinalIgnoreCase))
                    {
                        riskEngine.AddFinding(new Finding
                        {
                            Category = "L4D2_DETECTADO",
                            Level = EvidenceLevel.INFO,
                            Description = $"Proceso del juego Left 4 Dead 2 detectado en ejecución (PID: {pid}).",
                            PID = pid,
                            ProcessName = name,
                            FilePath = filePath,
                            ScoreAmount = 0
                        });
                    }
                }
                catch (Exception ex)
                {
                    errorCount++;
                    ScanLogger.Error($"Error al analizar proceso PID {proc.Id}", ex);
                }
            }

            ScanLogger.Info($"Escaneo de procesos finalizado: {scannedCount} procesos analizados ({errorCount} omitidos por permisos).");
        }
    }
}
