using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using L4D2AntiCheatScanner.Indicators.Models;
using L4D2AntiCheatScanner.Logging;

namespace L4D2AntiCheatScanner.Indicators
{
    public static class IndicatorLoader
    {
        public static List<Indicator> LoadIndicators()
        {
            var list = new List<Indicator>();
            string filePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "data", "indicators.json");

            if (!File.Exists(filePath))
            {
                ScanLogger.Warning($"Archivo de indicadores no encontrado en: {filePath}");
                return list;
            }

            try
            {
                string json = File.ReadAllText(filePath);
                var items = JsonSerializer.Deserialize<List<Indicator>>(json);
                if (items != null)
                {
                    list.AddRange(items);
                    ScanLogger.Info($"Se cargaron {list.Count} indicadores conocidos de cheat.");
                }
            }
            catch (Exception ex)
            {
                ScanLogger.Error("Error al cargar indicators.json", ex);
            }

            return list;
        }
    }
}

