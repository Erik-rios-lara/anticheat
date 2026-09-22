using System;
using System.Diagnostics;
using System.IO;

namespace AntiCheatManager
{
    public class AppManager
    {
        public string GamePath { get; private set; }

        public AppManager(string path)
        {
            GamePath = path;
        }

        public bool IsGameFolderValid()
        {
            if (string.IsNullOrEmpty(GamePath)) return false;
            return Directory.Exists(Path.Combine(GamePath, "left4dead2"));
        }

        public bool IsMetaModInstalled()
        {
            if (!IsGameFolderValid()) return false;
            return Directory.Exists(Path.Combine(GamePath, "left4dead2", "addons", "metamod"));
        }

        public bool IsSourceModInstalled()
        {
            if (!IsGameFolderValid()) return false;
            return Directory.Exists(Path.Combine(GamePath, "left4dead2", "addons", "sourcemod"));
        }

        public bool IsAntiCheatInstalled()
        {
            if (!IsGameFolderValid()) return false;
            string pluginPath = Path.Combine(GamePath, "left4dead2", "addons", "sourcemod", "plugins", "anticheat_core.smx");
            string disabledPath = Path.Combine(GamePath, "left4dead2", "addons", "sourcemod", "plugins", "anticheat_core.smx.disabled");
            return File.Exists(pluginPath) || File.Exists(disabledPath);
        }

        public bool IsAntiCheatEnabled()
        {
            if (!IsGameFolderValid()) return false;
            string pluginPath = Path.Combine(GamePath, "left4dead2", "addons", "sourcemod", "plugins", "anticheat_core.smx");
            return File.Exists(pluginPath);
        }

        public bool ToggleAntiCheat()
        {
            if (!IsGameFolderValid()) return false;
            string pluginPath = Path.Combine(GamePath, "left4dead2", "addons", "sourcemod", "plugins", "anticheat_core.smx");
            string disabledPath = Path.Combine(GamePath, "left4dead2", "addons", "sourcemod", "plugins", "anticheat_core.smx.disabled");

            try
            {
                if (File.Exists(pluginPath))
                {
                    File.Move(pluginPath, disabledPath);
                    return false; // Now disabled
                }
                else if (File.Exists(disabledPath))
                {
                    File.Move(disabledPath, pluginPath);
                    return true; // Now enabled
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine("Toggle error: " + ex.Message);
            }
            return false;
        }

        public void BackupFile(string relativePath)
        {
            if (!IsGameFolderValid()) return;
            string source = Path.Combine(GamePath, "left4dead2", relativePath);
            if (File.Exists(source))
            {
                string backupDir = Path.Combine(GamePath, "left4dead2", "addons", "sourcemod", "backups", DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss"));
                Directory.CreateDirectory(backupDir);
                string fileName = Path.GetFileName(source);
                File.Copy(source, Path.Combine(backupDir, fileName), true);
            }
        }

        public bool IsServerRunning()
        {
            Process[] srcds = Process.GetProcessesByName("srcds");
            Process[] l4d2 = Process.GetProcessesByName("left4dead2");
            return srcds.Length > 0 || l4d2.Length > 0;
        }
    }
}

