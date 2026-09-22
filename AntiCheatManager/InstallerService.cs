using System;
using System.IO;

namespace AntiCheatManager
{
    public class InstallerService
    {
        public static (bool success, string message) Install(string gamePath, string sourceRepoPath)
        {
            try
            {
                if (string.IsNullOrEmpty(gamePath) || !Directory.Exists(Path.Combine(gamePath, "left4dead2")))
                    return (false, "Ruta de Left 4 Dead 2 inválida.");

                string targetBase = Path.Combine(gamePath, "left4dead2");

                // Check SourceMod and MetaMod requirement
                if (!Directory.Exists(Path.Combine(targetBase, "addons", "metamod")) || 
                    !Directory.Exists(Path.Combine(targetBase, "addons", "sourcemod")))
                {
                    return (false, "MetaMod:Source y SourceMod deben estar instalados primero.");
                }

                // Definimos la carpeta fuente (donde está el .exe o el root del repo)
                // Si existe addons/sourcemod/plugins, asumimos que estamos en la raíz del repo.
                string addonsSource = Path.Combine(sourceRepoPath, "addons");
                string cfgSource = Path.Combine(sourceRepoPath, "cfg");

                if (!Directory.Exists(addonsSource))
                {
                    // Si no está, buscar si estamos ejecutando desde AntiCheatManager/bin/... y subir
                    string upRepo = Path.GetFullPath(Path.Combine(sourceRepoPath, "..", "..", "..", ".."));
                    addonsSource = Path.Combine(upRepo, "addons");
                    cfgSource = Path.Combine(upRepo, "cfg");
                    
                    if (!Directory.Exists(addonsSource))
                    {
                        // Buscar una carpeta arriba
                        upRepo = Path.GetFullPath(Path.Combine(sourceRepoPath, ".."));
                        addonsSource = Path.Combine(upRepo, "addons");
                        cfgSource = Path.Combine(upRepo, "cfg");
                    }
                }

                if (!Directory.Exists(addonsSource))
                    return (false, "No se encontraron los archivos del Anti-Cheat (carpeta 'addons') para copiar.");

                // Copiar todo el contenido de addons a targetBase\addons
                CopyDirectory(addonsSource, Path.Combine(targetBase, "addons"), true);
                
                // Copiar cfg si existe
                if (Directory.Exists(cfgSource))
                {
                    CopyDirectory(cfgSource, Path.Combine(targetBase, "cfg"), true);
                }

                return (true, "Instalación completada exitosamente.");
            }
            catch (Exception ex)
            {
                return (false, "Error: " + ex.Message);
            }
        }

        private static void CopyDirectory(string sourceDir, string destinationDir, bool recursive)
        {
            var dir = new DirectoryInfo(sourceDir);

            if (!dir.Exists)
                throw new DirectoryNotFoundException($"Directorio fuente no encontrado: {dir.FullName}");

            DirectoryInfo[] dirs = dir.GetDirectories();
            Directory.CreateDirectory(destinationDir);

            foreach (FileInfo file in dir.GetFiles())
            {
                string targetFilePath = Path.Combine(destinationDir, file.Name);
                // No sobreescribir configs clave directamente si ya existen, sin hacer backup primero
                if (file.Name.Equals("anticheat.cfg", StringComparison.OrdinalIgnoreCase) && File.Exists(targetFilePath))
                {
                     // Backup if exists done by AppManager before calling this, or just skip if we want.
                     // We will overwrite but it assumes a backup was made.
                }
                file.CopyTo(targetFilePath, true);
            }

            if (recursive)
            {
                foreach (DirectoryInfo subDir in dirs)
                {
                    // Evitar copiar código fuente (.sp)
                    if (subDir.Name.Equals("scripting", StringComparison.OrdinalIgnoreCase)) continue;

                    string newDestinationDir = Path.Combine(destinationDir, subDir.Name);
                    CopyDirectory(subDir.FullName, newDestinationDir, true);
                }
            }
        }
    }
}

