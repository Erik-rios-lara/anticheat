using System;
using System.IO;

namespace L4D2AntiCheatScanner.Logging
{
    public static class ScanLogger
    {
        private static string logFilePath;

        public static void Initialize()
        {
            try
            {
                string logsDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs");
                if (!Directory.Exists(logsDir))
                {
                    Directory.CreateDirectory(logsDir);
                }
                logFilePath = Path.Combine(logsDir, "scanner.log");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[!] Could not initialize file logger: {ex.Message}");
            }
        }

        public static void Info(string message)
        {
            Log("INFO", message, "[+]");
        }

        public static void Warning(string message)
        {
            Log("WARNING", message, "[!]");
        }

        public static void Error(string message, Exception? ex = null)
        {
            string fullMessage = ex == null ? message : $"{message} - {ex.Message}";
            Log("ERROR", fullMessage, "[-]");
        }

        private static void Log(string level, string message, string prefix)
        {
            string consoleMsg = $"{prefix} {message}";
            Console.WriteLine(consoleMsg);

            if (!string.IsNullOrEmpty(logFilePath))
            {
                try
                {
                    string fileMsg = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] [{level}] {message}";
                    File.AppendAllText(logFilePath, fileMsg + Environment.NewLine);
                }
                catch
                {
                    // Fail silently for file logging
                }
            }
        }
    }
}

