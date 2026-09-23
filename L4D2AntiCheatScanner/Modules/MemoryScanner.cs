using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using L4D2AntiCheatScanner.Core;
using L4D2AntiCheatScanner.Evidence;
using L4D2AntiCheatScanner.Logging;

namespace L4D2AntiCheatScanner.Modules
{
    public static class MemoryScanner
    {
        // Constantes de permisos de Windows API
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint PROCESS_VM_READ = 0x0010;

        private const uint MEM_COMMIT = 0x1000;
        private const uint MEM_PRIVATE = 0x20000;

        private const uint PAGE_EXECUTE_READWRITE = 0x40;
        private const uint PAGE_EXECUTE_READ = 0x20;
        private const uint PAGE_EXECUTE_WRITECOPY = 0x80;

        [StructLayout(LayoutKind.Sequential)]
        private struct MEMORY_BASIC_INFORMATION
        {
            public IntPtr BaseAddress;
            public IntPtr AllocationBase;
            public uint AllocationProtect;
            public IntPtr RegionSize;
            public uint State;
            public uint Protect;
            public uint Type;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint processAccess, bool bInheritHandle, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern int VirtualQueryEx(IntPtr hProcess, IntPtr lpAddress, out MEMORY_BASIC_INFORMATION lpBuffer, uint dwLength);

        public static void Scan(ScanContext context, RiskEngine riskEngine)
        {
            ScanLogger.Info("Escaneando memoria de regiones en vivo de Left 4 Dead 2...");

            Process[] l4d2Processes = Process.GetProcessesByName("left4dead2");

            if (l4d2Processes.Length == 0)
            {
                ScanLogger.Info("Left 4 Dead 2 no está en ejecución. (Escaneo de memoria omitido).");
                return;
            }

            foreach (var proc in l4d2Processes)
            {
                ScanLogger.Info($"Analizando mapa de memoria de PID {proc.Id}...");

                IntPtr hProcess = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, proc.Id);

                if (hProcess == IntPtr.Zero)
                {
                    int err = Marshal.GetLastWin32Error();
                    ScanLogger.Warning($"No se pudo abrir handle de lectura de memoria hacia PID {proc.Id} (Win32 Error: {err}). Se requieren privilegios de Administrador.");
                    
                    riskEngine.AddFinding(new Finding
                    {
                        Category = "MEMORIA_ACCESO_DENEGADO",
                        Level = EvidenceLevel.INFO,
                        Description = $"No se pudo abrir handle de lectura en memoria para PID {proc.Id}. Ejecute como Administrador para habilitar análisis de regiones.",
                        PID = proc.Id,
                        ProcessName = proc.ProcessName,
                        FilePath = "-",
                        ScoreAmount = 0
                    });
                    continue;
                }

                try
                {
                    IntPtr address = IntPtr.Zero;
                    int rwxCount = 0;
                    int privateExecCount = 0;

                    while (true)
                    {
                        MEMORY_BASIC_INFORMATION mbi;
                        int result = VirtualQueryEx(hProcess, address, out mbi, (uint)Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION)));

                        if (result == 0)
                            break;

                        // Analizar regiones committed
                        if (mbi.State == MEM_COMMIT)
                        {
                            bool isRWX = (mbi.Protect & PAGE_EXECUTE_READWRITE) != 0;
                            bool isPrivate = (mbi.Type == MEM_PRIVATE);
                            bool isExecutable = (mbi.Protect & (PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) != 0;

                            if (isRWX)
                            {
                                rwxCount++;
                            }

                            if (isPrivate && isExecutable)
                            {
                                privateExecCount++;
                            }
                        }

                        // Avanzar a la siguiente región de memoria
                        long nextAddr = address.ToInt64() + mbi.RegionSize.ToInt64();
                        if (nextAddr <= address.ToInt64()) break; // Prevención de desbordamiento
                        address = new IntPtr(nextAddr);
                    }

                    if (rwxCount > 0)
                    {
                        riskEngine.AddFinding(new Finding
                        {
                            Category = "MEMORIA_REGION_RWX",
                            Level = EvidenceLevel.HIGH_RISK,
                            Description = $"Se detectaron {rwxCount} regiones de memoria RWX (Lectura/Escritura/Ejecución) en L4D2.",
                            PID = proc.Id,
                            ProcessName = proc.ProcessName,
                            FilePath = "-",
                            ScoreAmount = 40
                        });
                    }

                    if (privateExecCount > 0)
                    {
                        riskEngine.AddFinding(new Finding
                        {
                            Category = "MEMORIA_PRIVADA_EJECUTABLE",
                            Level = EvidenceLevel.SUSPICIOUS,
                            Description = $"Se detectaron {privateExecCount} regiones de memoria ejecutable privada (posible manual mapping / shellcode).",
                            PID = proc.Id,
                            ProcessName = proc.ProcessName,
                            FilePath = "-",
                            ScoreAmount = 25
                        });
                    }

                    ScanLogger.Info($"Análisis de memoria de PID {proc.Id} finalizado. Regiones RWX: {rwxCount}, Privadas Ejecutables: {privateExecCount}.");
                }
                finally
                {
                    CloseHandle(hProcess);
                }
            }
        }
    }
}

