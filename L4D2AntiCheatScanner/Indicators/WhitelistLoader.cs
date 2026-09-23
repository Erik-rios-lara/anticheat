using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using L4D2AntiCheatScanner.Indicators.Models;
using L4D2AntiCheatScanner.Logging;

namespace L4D2AntiCheatScanner.Indicators
{
    public static class WhitelistLoader
    {
        public static List<WhitelistEntry> LoadWhitelist()
        {
            var list = new List<WhitelistEntry>();
            string filePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "data", "whitelist.json");

            if (!File.Exists(filePath))
            {
                ScanLogger.Warning($"Archivo de whitelist no encontrado en: {filePath}");
                return list;
            }

            try
            {
                string json = File.ReadAllText(filePath);
                var items = JsonSerializer.Deserialize<List<WhitelistEntry>>(json);
                if (items != null)
                {
                    list.AddRange(items);
                    ScanLogger.Info($"Se cargaron {list.Count} entradas de whitelist.");
                }
            }
            catch (Exception ex)
            {
                ScanLogger.Error("Error al cargar whitelist.json", ex);
            }

            return list;
        }
    }
}

