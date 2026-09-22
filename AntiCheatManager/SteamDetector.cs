using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace AntiCheatManager
{
    public static class SteamDetector
    {
        public static string FindLeft4Dead2()
        {
            try
            {
                // 1. Try to find Steam install path from Registry
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

                // 2. Default library path
                List<string> libraryFolders = new List<string> { steamPath };

                // 3. Parse libraryfolders.vdf
                string vdfPath = Path.Combine(steamPath, "steamapps", "libraryfolders.vdf");
                if (File.Exists(vdfPath))
                {
                    string vdfContent = File.ReadAllText(vdfPath);
                    // Match paths in VDF. Usually like: "path" "D:\\SteamLibrary"
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

                // 4. Search for L4D2 in all libraries
                foreach (var lib in libraryFolders)
                {
                    string l4d2Path = Path.Combine(lib, "steamapps", "common", "Left 4 Dead 2");
                    if (Directory.Exists(l4d2Path) && Directory.Exists(Path.Combine(l4d2Path, "left4dead2")))
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

