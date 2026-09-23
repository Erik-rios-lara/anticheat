using System;
using L4D2AntiCheatScanner.Core;
using L4D2AntiCheatScanner.Logging;

namespace L4D2AntiCheatScanner
{
    class Program
    {
        static void Main(string[] args)
        {
            bool isInteractiveDoubleCLick = args.Length == 0;
            string command = isInteractiveDoubleCLick ? "--game" : args[0].ToLower();

            ScanLogger.Initialize();
            ScanLogger.Info("Initializing scanner...");

            var scanner = new Scanner();

            switch (command)
            {
                case "--fast":
                    scanner.RunFastScan();
                    break;
                case "--game":
                    scanner.RunGameScan();
                    break;
                case "--deep":
                    scanner.RunDeepScan();
                    break;
                case "--report":
                    Console.WriteLine("[!] La opción --report aún no está implementada.");
                    break;
                case "--help":
                case "-h":
                    ShowHelp();
                    break;
                default:
                    Console.WriteLine($"[!] Comando desconocido: {command}");
                    ShowHelp();
                    break;
            }

            if (isInteractiveDoubleCLick)
            {
                Console.WriteLine("");
                Console.WriteLine("==================================================");
                Console.WriteLine("Presiona cualquier tecla para cerrar esta ventana...");
                Console.WriteLine("==================================================");
                Console.ReadKey();
            }
        }

        static void ShowHelp()
        {
            Console.WriteLine("L4D2 Anti-Cheat Scanner");
            Console.WriteLine("Usage: L4D2AntiCheat.exe [option]");
            Console.WriteLine("");
            Console.WriteLine("Options:");
            Console.WriteLine("  --fast    Analiza procesos, módulos y ubicaciones críticas.");
            Console.WriteLine("  --game    Analiza profundamente Left 4 Dead 2 y Steam.");
            Console.WriteLine("  --deep    Realiza una búsqueda más amplia del sistema de archivos.");
            Console.WriteLine("  --report  Muestra o genera el reporte del último escaneo.");
            Console.WriteLine("  --help    Muestra este mensaje de ayuda.");
        }
    }
}
