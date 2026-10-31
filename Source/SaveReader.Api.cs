using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace PBZ
{
    /// <summary>
    /// Reads the boss counters used by the Phantom Blade Zero save splitter.
    /// Only __Advanced__ is decoded from a PBZS container.
    /// </summary>
    public static partial class SaveReader
    {
        private const long MaxSaveSize = 128L * 1024 * 1024;
        private static readonly object Sync = new object();
        private static string _cachedLookupKey;
        private static string _cachedOodlePath;

        public static string Version
        {
            get { return "2.2.0"; }
        }

        /// <summary>
        /// Returns OK, the file signature, and sorted boss counters:
        /// OK\t&lt;writeTicks&gt;\t&lt;length&gt;\n&lt;bossKey&gt;\t&lt;killCount&gt;...
        /// </summary>
        public static string ReadSnapshotText(string savePath)
        {
            try
            {
                return ReadSnapshotTextInternal(savePath, null);
            }
            catch (Exception ex)
            {
                return "ERR\t" + Sanitize(ex.GetType().Name + ": " + ex.Message);
            }
        }

        public static string ReadSnapshotText(string savePath, string oodleDllPath)
        {
            try
            {
                if (string.IsNullOrEmpty(oodleDllPath) || !File.Exists(oodleDllPath))
                {
                    throw new FileNotFoundException(
                        "Oodle DLL not found", oodleDllPath ?? "(null)");
                }
                return ReadSnapshotTextInternal(savePath, oodleDllPath);
            }
            catch (Exception ex)
            {
                return "ERR\t" + Sanitize(ex.GetType().Name + ": " + ex.Message);
            }
        }

        public static Dictionary<string, int> ReadBossKills(string savePath)
        {
            return ParseSnapshotText(ReadSnapshotText(savePath));
        }

        public static Dictionary<string, int> ReadBossKills(
            string savePath, string oodleDllPath)
        {
            return ParseSnapshotText(ReadSnapshotText(savePath, oodleDllPath));
        }

        private static string ReadSnapshotTextInternal(
            string savePath, string oodleDllPath)
        {
            if (string.IsNullOrEmpty(savePath))
            {
                throw new ArgumentException("savePath is empty");
            }

            long ticks;
            long length;
            SortedDictionary<string, int> kills;

            lock (Sync)
            {
                FileInfo info = new FileInfo(savePath);
                if (!info.Exists)
                {
                    throw new FileNotFoundException("save file not found", savePath);
                }
                ticks = info.LastWriteTimeUtc.Ticks;
                length = info.Length;
                if (length <= 0 || length > MaxSaveSize)
                {
                    throw new InvalidDataException("unexpected save size " + length);
                }

                kills = ReadKills(savePath, oodleDllPath);
            }

            StringBuilder text = new StringBuilder(256 + kills.Count * 48);
            text.Append("OK\t");
            text.Append(ticks.ToString(CultureInfo.InvariantCulture));
            text.Append('\t');
            text.Append(length.ToString(CultureInfo.InvariantCulture));
            foreach (KeyValuePair<string, int> pair in kills)
            {
                text.Append('\n');
                text.Append(pair.Key);
                text.Append('\t');
                text.Append(pair.Value.ToString(CultureInfo.InvariantCulture));
            }
            return text.ToString();
        }

        /// <summary>
        /// Finds the newest PBZSaveGame.sav below ProjectPBZ\Saved\SaveGames.
        /// Falls back to any *.sav in that tree if the aggregate file is absent.
        /// </summary>
        public static string FindSaveFile(string gameExeOrDirectory)
        {
            string root = FindGameRoot(gameExeOrDirectory);
            if (root == null)
            {
                return null;
            }

            string saveRoot = Path.Combine(root, "ProjectPBZ", "Saved", "SaveGames");
            if (!Directory.Exists(saveRoot))
            {
                return null;
            }

            string best = FindNewestFile(saveRoot, "PBZSaveGame.sav");
            if (best == null)
            {
                best = FindNewestFile(saveRoot, "*.sav");
            }
            return best;
        }

        /// <summary>
        /// Finds an Oodle decoder in the usual game/LiveSplit locations. The
        /// result is cached until the lookup changes or the DLL disappears.
        /// </summary>
        public static string FindOodleDll(string gameExeSaveOrDirectory)
        {
            lock (Sync)
            {
                if (!string.IsNullOrEmpty(_cachedOodlePath)
                    && File.Exists(_cachedOodlePath)
                    && string.Equals(
                        _cachedLookupKey,
                        gameExeSaveOrDirectory,
                        StringComparison.OrdinalIgnoreCase))
                {
                    return _cachedOodlePath;
                }
            }

            string root = FindGameRoot(gameExeSaveOrDirectory);
            List<string> candidates = new List<string>();
            string env = Environment.GetEnvironmentVariable("OO2CORE_DLL");
            AddOodleFile(candidates, env);

            string appDir = AppDomain.CurrentDomain.BaseDirectory;
            AddOodleFiles(candidates, appDir);
            AddOodleFiles(candidates, Path.Combine(appDir, "Components"));

            if (root != null)
            {
                AddOodleFiles(candidates, root);
                AddOodleFiles(candidates, Path.Combine(root, "Game"));
                AddOodleFiles(candidates, Path.Combine(root, "Binaries", "Win64"));
                AddOodleFiles(candidates, Path.Combine(root, "Engine", "Binaries", "ThirdParty"));
            }

            string common = FindSteamCommonRoot(root);
            if (!string.IsNullOrEmpty(common))
            {
                AddSiblingGameOodleFiles(candidates, common);
            }

            if (candidates.Count == 0)
            {
                return null;
            }

            candidates.Sort(CompareOodleCandidates);
            string best = candidates[0];
            lock (Sync)
            {
                _cachedLookupKey = gameExeSaveOrDirectory;
                _cachedOodlePath = best;
            }
            return best;
        }

        private static Dictionary<string, int> ParseSnapshotText(string text)
        {
            if (text == null || !text.StartsWith("OK\t", StringComparison.Ordinal))
            {
                throw new InvalidDataException(text ?? "(null)");
            }

            Dictionary<string, int> result =
                new Dictionary<string, int>(StringComparer.Ordinal);
            string[] lines = text.Split('\n');
            for (int i = 1; i < lines.Length; i++)
            {
                string line = lines[i].Trim();
                if (line.Length == 0)
                {
                    continue;
                }
                int tab = line.IndexOf('\t');
                if (tab <= 0)
                {
                    continue;
                }
                int count;
                if (int.TryParse(
                    line.Substring(tab + 1),
                    NumberStyles.Integer,
                    CultureInfo.InvariantCulture,
                    out count))
                {
                    result[line.Substring(0, tab)] = count;
                }
            }
            return result;
        }

        private static string FindNewestFile(string directory, string pattern)
        {
            string best = null;
            DateTime bestTime = DateTime.MinValue;
            try
            {
                foreach (string candidate in Directory.GetFiles(
                    directory, pattern, SearchOption.AllDirectories))
                {
                    DateTime time = File.GetLastWriteTimeUtc(candidate);
                    if (best == null || time > bestTime)
                    {
                        best = candidate;
                        bestTime = time;
                    }
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
            return best;
        }

        private static int CompareOodleCandidates(string a, string b)
        {
            int va = OodleVersionRank(a);
            int vb = OodleVersionRank(b);
            if (va != vb)
            {
                return vb.CompareTo(va);
            }
            return string.Compare(a, b, StringComparison.OrdinalIgnoreCase);
        }

        private static int OodleVersionRank(string path)
        {
            string name = Path.GetFileName(path);
            int best = 0;
            for (int i = 0; i < name.Length; i++)
            {
                if (name[i] < '0' || name[i] > '9')
                {
                    continue;
                }

                int value = 0;
                int start = i;
                while (i < name.Length && name[i] >= '0' && name[i] <= '9')
                {
                    value = value * 10 + (name[i] - '0');
                    i++;
                }
                if (i - start > 0 && value > best && value < 100)
                {
                    best = value;
                }
            }
            return best;
        }

        private static void AddOodleFile(List<string> candidates, string file)
        {
            if (string.IsNullOrEmpty(file) || !File.Exists(file))
            {
                return;
            }
            string name = Path.GetFileName(file);
            if (!name.StartsWith("oo2core", StringComparison.OrdinalIgnoreCase)
                || !name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
            if (!candidates.Exists(delegate(string x)
            {
                return string.Equals(x, file, StringComparison.OrdinalIgnoreCase);
            }))
            {
                candidates.Add(file);
            }
        }

        private static void AddOodleFiles(List<string> candidates, string directory)
        {
            if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory))
            {
                return;
            }
            try
            {
                foreach (string file in Directory.GetFiles(directory, "oo2core*.dll"))
                {
                    AddOodleFile(candidates, file);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        private static void AddSiblingGameOodleFiles(
            List<string> candidates, string common)
        {
            string[] known =
            {
                "ARMORED CORE VI FIRES OF RUBICON",
                "ELDEN RING",
                "Sekiro",
                "Black Myth Wukong"
            };
            for (int i = 0; i < known.Length; i++)
            {
                AddKnownGameOodleFiles(candidates, Path.Combine(common, known[i]));
            }

            try
            {
                foreach (string dir in Directory.GetDirectories(common))
                {
                    AddKnownGameOodleFiles(candidates, dir);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        private static void AddKnownGameOodleFiles(
            List<string> candidates, string gameDirectory)
        {
            AddOodleFiles(candidates, gameDirectory);
            AddOodleFiles(candidates, Path.Combine(gameDirectory, "Game"));
            AddOodleFiles(candidates, Path.Combine(gameDirectory, "Binaries", "Win64"));
        }

        private static string FindGameRoot(string gameExeSaveOrDirectory)
        {
            if (string.IsNullOrEmpty(gameExeSaveOrDirectory))
            {
                return null;
            }

            string dir;
            try
            {
                dir = Directory.Exists(gameExeSaveOrDirectory)
                    ? gameExeSaveOrDirectory
                    : Path.GetDirectoryName(gameExeSaveOrDirectory);
            }
            catch (ArgumentException)
            {
                return null;
            }

            for (int i = 0; i < 12 && !string.IsNullOrEmpty(dir); i++)
            {
                if (Directory.Exists(Path.Combine(dir, "ProjectPBZ")))
                {
                    return dir;
                }
                DirectoryInfo parent = Directory.GetParent(dir);
                if (parent == null)
                {
                    break;
                }
                dir = parent.FullName;
            }
            return null;
        }

        private static string FindSteamCommonRoot(string gameRoot)
        {
            if (string.IsNullOrEmpty(gameRoot))
            {
                return null;
            }
            string dir = gameRoot;
            for (int i = 0; i < 6 && !string.IsNullOrEmpty(dir); i++)
            {
                if (string.Equals(
                        Path.GetFileName(dir), "common", StringComparison.OrdinalIgnoreCase)
                    && string.Equals(
                        Path.GetFileName(Path.GetDirectoryName(dir)),
                        "steamapps",
                        StringComparison.OrdinalIgnoreCase))
                {
                    return dir;
                }
                DirectoryInfo parent = Directory.GetParent(dir);
                if (parent == null)
                {
                    break;
                }
                dir = parent.FullName;
            }
            return null;
        }

        private static string Sanitize(string text)
        {
            if (text == null)
            {
                return "(null)";
            }
            return text.Replace('\r', ' ').Replace('\n', ' ').Replace('\t', ' ');
        }
    }
}
