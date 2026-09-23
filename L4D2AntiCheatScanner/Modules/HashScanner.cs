using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using L4D2AntiCheatScanner.Core;
using L4D2AntiCheatScanner.Evidence;
using L4D2AntiCheatScanner.Indicators;
using L4D2AntiCheatScanner.Indicators.Models;
using L4D2AntiCheatScanner.Logging;

namespace L4D2AntiCheatScanner.Modules
{
    public static class HashScanner
    {
        public static string ComputeSHA256(string filePath)
        {
            if (string.IsNullOrEmpty(filePath) || !File.Exists(filePath))
                return string.Empty;

            try
            {
                using (var sha256 = SHA256.Create())
                using (var stream = File.OpenRead(filePath))
                {
                    byte[] hashBytes = sha256.ComputeHash(stream);
                    return BitConverter.ToString(hashBytes).Replace("-", "").ToLowerInvariant();
                }
            }
            catch
            {
                return string.Empty;
            }
        }

        public static void ScanHashes(ScanContext context, RiskEngine riskEngine)
        {
            ScanLogger.Info("Verificando hashes SHA-256 contra la base de datos de indicadores...");

            List<Indicator> indicators = IndicatorLoader.LoadIndicators();
            List<WhitelistEntry> whitelist = WhitelistLoader.LoadWhitelist();

            if (indicators.Count == 0 && whitelist.Count == 0)
            {
                ScanLogger.Info("No hay indicadores ni whitelist para comparar hashes.");
                return;
            }

            // Escanear ejecutables y DLLs clave en la carpeta del juego
            if (!string.IsNullOrEmpty(context.GameDirectory) && Directory.Exists(context.GameDirectory))
            {
                try
                {
                    var filesToHash = Directory.EnumerateFiles(context.GameDirectory, "*.*", SearchOption.AllDirectories)
                        .Where(f => f.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ||
                                    f.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ||
                                    f.EndsWith(".asi", StringComparison.OrdinalIgnoreCase));

                    int checkedCount = 0;
                    foreach (var file in filesToHash)
                    {
                        checkedCount++;
                        string hash = ComputeSHA256(file);
                        if (string.IsNullOrEmpty(hash)) continue;

                        // Comprobar coincidencia con indicadores
                        var match = indicators.FirstOrDefault(i => i.Hash.Equals(hash, StringComparison.OrdinalIgnoreCase));
                        if (match != null)
                        {
                            riskEngine.AddFinding(new Finding
                            {
                                Category = "HASH_CHEAT_CONFIRMADO",
                                Level = EvidenceLevel.CRITICAL,
                                Description = $"Coincidencia exacta de hash con cheat conocido ({match.Name}): '{file}' [SHA256: {hash}]",
                                PID = 0,
                                ProcessName = "-",
                                FilePath = file,
                                ScoreAmount = 90
                            });
                        }
                    }

                    ScanLogger.Info($"Verificación de hashes completada: {checkedCount} archivos analizados contra la base de datos.");
                }
                catch (Exception ex)
                {
                    ScanLogger.Error("Error al escanear hashes de la carpeta del juego", ex);
                }
            }
        }
    }
}

