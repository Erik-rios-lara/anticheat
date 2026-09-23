using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace L4D2AntiCheatScanner.Modules
{
    public static class SteamLocator
    {
        public static string FindLeft4Dead2()
        {
            try
            {
                string steamPath = "";
                if (Environment.Is64BitOperatingSystem)
                {
                    steamPath = (string)Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", "");
                }
                else
                {
                    steamPath = (string)Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam", "InstallPath", "");
                }

                if (string.IsNullOrEmpty(steamPath))
                    return null;

                List<string> libraryFolders = new List<string> { steamPath };

                string vdfPath = Path.Combine(steamPath, "steamapps", "libraryfolders.vdf");
                if (File.Exists(vdfPath))
                {
                    string vdfContent = File.ReadAllText(vdfPath);
                    MatchCollection matches = Regex.Matches(vdfContent, "\"path\"\\s+\"([^\"]+)\"");
                    foreach (Match match in matches)
                    {
                        if (match.Groups.Count > 1)
                        {
                            string path = match.Groups[1].Value.Replace("\\\\", "\\");
                            if (!libraryFolders.Contains(path))
                            {
                                libraryFolders.Add(path);
                            }
                        }
                    }
                }

                foreach (var lib in libraryFolders)
                {
                    string l4d2Path = Path.Combine(lib, "steamapps", "common", "Left 4 Dead 2");
                    if (Directory.Exists(l4d2Path) && File.Exists(Path.Combine(l4d2Path, "left4dead2.exe")))
                    {
                        return l4d2Path;
                    }
                }

                return null;
            }
            catch
            {
                return null;
            }
        }
    }
}

