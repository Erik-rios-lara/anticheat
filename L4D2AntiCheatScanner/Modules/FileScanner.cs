using System;
using System.IO;
using L4D2AntiCheatScanner.Core;
using L4D2AntiCheatScanner.Evidence;
using L4D2AntiCheatScanner.Logging;

namespace L4D2AntiCheatScanner.Modules
{
    public static class FileScanner
    {
        public static void ScanGameDirectory(ScanContext context, RiskEngine riskEngine)
        {
            if (string.IsNullOrEmpty(context.GameDirectory) || !Directory.Exists(context.GameDirectory))
            {
                ScanLogger.Warning("No se especificó o no se encontró el directorio de L4D2 para el escaneo de archivos.");
                return;
            }

            ScanLogger.Info($"Escaneando archivos en el directorio del juego: {context.GameDirectory}");

            try
            {
                // Escaneo de archivos sueltos y sospechosos en la raíz del juego
                string[] files = Directory.GetFiles(context.GameDirectory, "*.*", SearchOption.AllDirectories);
                int scanned = 0;

                foreach (var file in files)
                {
                    scanned++;
                    var fileInfo = new FileInfo(file);
                    string ext = fileInfo.Extension.ToLower();

                    // Detectar atributos ocultos o de sistema
                    bool isHidden = (fileInfo.Attributes & FileAttributes.Hidden) != 0;
                    bool isSystem = (fileInfo.Attributes & FileAttributes.System) != 0;

                    if (isHidden || isSystem)
                    {
                        riskEngine.AddFinding(new Finding
                        {
                            Category = "ARCHIVO_OCULTO_JUEGO",
                            Level = EvidenceLevel.SUSPICIOUS,
                            Description = $"Archivo oculto o de sistema dentro de la carpeta del juego: '{file}' (Atributos: {fileInfo.Attributes})",
                            PID = 0,
                            ProcessName = "-",
                            FilePath = file,
                            ScoreAmount = 15
                        });
                    }

                    // Detectar ejecutable o DLL inusual en la raíz del juego
                    if (fileInfo.DirectoryName!.Equals(context.GameDirectory, StringComparison.OrdinalIgnoreCase))
                    {
                        if (ext == ".exe" && !fileInfo.Name.Equals("left4dead2.exe", StringComparison.OrdinalIgnoreCase)
                                          && !fileInfo.Name.Equals("srcds.exe", StringComparison.OrdinalIgnoreCase))
                        {
                            var sig = SignatureChecker.CheckSignature(file);

                            riskEngine.AddFinding(new Finding
                            {
                                Category = "EJECUTABLE_EXTRAÑO_RAIZ",
                                Level = sig.IsSigned ? EvidenceLevel.SUSPICIOUS : EvidenceLevel.HIGH_RISK,
                                Description = $"Ejecutable inesperado en la raíz de L4D2: '{fileInfo.Name}' (Firmado: {sig.IsSigned})",
                                PID = 0,
                                ProcessName = "-",
                                FilePath = file,
                                ScoreAmount = sig.IsSigned ? 15 : 35
                            });
                        }
                    }

                    // Detectar librerías inyectables comunes de cheats (.asi, .dll no estándar en addons/bin sin firma)
                    if (ext == ".asi")
                    {
                        riskEngine.AddFinding(new Finding
                        {
                            Category = "MODULO_ASI_DETECTADO",
                            Level = EvidenceLevel.HIGH_RISK,
                            Description = $"Archivo plugin .ASI detectado en la carpeta del juego: '{file}'",
                            PID = 0,
                            ProcessName = "-",
                            FilePath = file,
                            ScoreAmount = 30
                        });
                    }
                }

                ScanLogger.Info($"Escaneo de archivos del juego finalizado: {scanned} archivos analizados.");
            }
            catch (Exception ex)
            {
                ScanLogger.Error("Error durante el escaneo de archivos del juego", ex);
            }
        }

        public static void ScanCriticalLocations(ScanContext context, RiskEngine riskEngine)
        {
            ScanLogger.Info("Escaneando ubicaciones críticas del sistema (Temp y AppData)...");

            string tempPath = Path.GetTempPath();

            try
            {
                if (Directory.Exists(tempPath))
                {
                    string[] tempDlls = Directory.GetFiles(tempPath, "*.dll", SearchOption.TopDirectoryOnly);
                    foreach (var dll in tempDlls)
                    {
                        var sig = SignatureChecker.CheckSignature(dll);
                        if (!sig.IsSigned)
                        {
                            riskEngine.AddFinding(new Finding
                            {
                                Category = "DLL_TEMPORAL_SIN_FIRMA",
                                Level = EvidenceLevel.SUSPICIOUS,
                                Description = $"DLL no firmada encontrada en carpeta Temp: '{dll}'",
                                PID = 0,
                                ProcessName = "-",
                                FilePath = dll,
                                ScoreAmount = 10
                            });
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                ScanLogger.Error("Error al escanear carpeta Temp", ex);
            }
        }
    }
}

