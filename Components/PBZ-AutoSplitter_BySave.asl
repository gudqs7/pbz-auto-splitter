state("PBZ"){}

startup
{
    string componentDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Components");
    Assembly.Load(File.ReadAllBytes(Path.Combine(componentDir, "asl-help"))).CreateInstance("Basic");
    vars.Helper.GameName = "Phantom Blade Zero";

    vars.SettingsLoaded = false;
    vars.LoadSettings = (Action)(() =>
    {
        if (!(bool)vars.SettingsLoaded)
        {
            try
            {
                string culture = System.Globalization.CultureInfo.CurrentCulture.Name;
                string settingsPath = Path.Combine(componentDir, "PBZ.BossSettings." + culture + ".xml");
                if (!File.Exists(settingsPath))
                {
                    string language = culture.Split('-')[0];
                    settingsPath = Path.Combine(componentDir, "PBZ.BossSettings." + language + ".xml");
                }
                if (!File.Exists(settingsPath))
                    settingsPath = Path.Combine(componentDir, "PBZ.BossSettings.xml");

                vars.Helper.Settings.CreateFromXml(settingsPath);
                vars.SettingsLoaded = true;
                print("[PBZ] settings culture=" + culture + " file=" + settingsPath);
            }
            catch (Exception ex)
            {
                print("[PBZ] boss settings load failed: " + ex.Message);
            }
        }
    });
    ((Action)vars.LoadSettings)();
}

init
{

    vars.FindGame = (Func<Process>)(() =>
    {
        Process best = null;
        int bestSize = 0;
        foreach (Process p in Process.GetProcessesByName("PBZ"))
        {
            try
            {
                int size = p.MainModule.ModuleMemorySize;
                if (size > bestSize) { best = p; bestSize = size; }
            }
            catch {}
        }
        return bestSize == 0x1ec54000 ? best : null;
    });

    Process target = null;
    int findAttempt = 0;
    for (; findAttempt < 20; findAttempt++)
    {
        target = ((Func<Process>)vars.FindGame)();
        if (target != null) break;
        if (findAttempt < 19) System.Threading.Thread.Sleep(50);
    }

    if (target != null)
    {
        vars.Helper.Game = target;
        print("[PBZ] build gate: matched PBZ process, retry=" + findAttempt);
    }
    else
    {
        print("[PBZ] build gate: no matching PBZ process");
        return;
    }

    vars.Helper["World"] = vars.Helper.Make<long>(0xdf741c8, 0xc88, 0x78);
    vars.Helper["WorldNameId"] = vars.Helper.Make<int>(0xdf741c8, 0xc88, 0x78, 0x18);
    vars.Helper["Dest"] = vars.Helper.Make<long>(0xdf741c8, 0xc88, 0x80, 0x118, 0x248);
    vars.Helper["Loading"] = vars.Helper.Make<byte>(0xdf741c8, 0xc88, 0x80, 0x118, 0x248, 0x250);

    vars.Helper["World"].FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull;
    vars.Helper["WorldNameId"].FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull;
    vars.Helper["Dest"].FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull;
    vars.Helper["Loading"].FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull;

    vars.WorldName = "";
    vars.LastNameId = -1;
    vars.Frontend = false;
    vars.Paused = true;

    vars.ReadFName = (Func<int, string>)(nameId =>
    {
        int blockIndex = nameId >> 16;
        int blockOffset = (nameId & 0xffff) * 2;
        int blockCount = vars.Helper.Read<int>(0xdd11ac8);
        if (blockIndex < 0 || blockIndex >= blockCount) return null;

        long block = vars.Helper.Read<long>(0xdd11ac8 + 8 + blockIndex * 8);
        if (block == 0) return null;

        ushort header = vars.Helper.Read<ushort>((IntPtr)(block + blockOffset));
        int length = (header >> 6) & 0x3ff;
        if (length <= 0 || length > 1024) return null;

        bool wide = (header & 1) != 0;
        string name = vars.Helper.ReadString(
            length * (wide ? 2 : 1),
            wide ? ReadStringType.UTF16 : ReadStringType.ASCII,
            (IntPtr)(block + blockOffset + 2));
        return string.IsNullOrEmpty(name) ? null : name;
    });

    vars.BossApiReady = false;
    vars.BossBaseline = null;
    vars.BossPending = new Queue<string>();
    vars.BossSigTicks = 0L;
    vars.BossSigLength = -1L;
    vars.BossSavePath = "";
    vars.BossNextResolve = 0L;
    vars.BossLastErrorLog = 0L;
    vars.BossLastKill = "";

    try
    {
        string bossComponentDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Components");
        Assembly bossAssembly = Assembly.LoadFrom(Path.Combine(bossComponentDir, "PBZSaveReader.dll"));
        Type bossType = bossAssembly.GetType("PBZ.SaveReader");
        if (bossType != null)
        {
            vars.BossReadMethod = bossType.GetMethod(
                "ReadSnapshotText",
                new Type[] { typeof(string) });
            vars.BossFindSaveMethod = bossType.GetMethod("FindSaveFile");
            vars.BossApiReady = vars.BossReadMethod != null
                && vars.BossFindSaveMethod != null;
            PropertyInfo bossVersion = bossType.GetProperty("Version");
            if (bossVersion != null)
            {
                print("[PBZ] save reader v" + bossVersion.GetValue(null, null));
            }
        }
    }
    catch (Exception ex)
    {
        print("[PBZ] save reader load failed: " + ex.Message);
    }

    vars.ReadBossSnapshot = (Func<Tuple<long, long, Dictionary<string, int>>>)(() =>
    {
        if (!(bool)vars.BossApiReady) return null;
        string save = (string)vars.BossSavePath;
        if (string.IsNullOrEmpty(save)) return null;

        string snapshot = null;
        try
        {
            snapshot = (string)vars.BossReadMethod.Invoke(null, new object[] { save });
        }
        catch (Exception ex)
        {
            snapshot = "ERR\t" + ex.GetType().Name + ": " + ex.Message;
        }

        if (snapshot == null || !snapshot.StartsWith("OK\t", StringComparison.Ordinal))
        {
            long nowTicks = DateTime.UtcNow.Ticks;
            if (nowTicks - (long)vars.BossLastErrorLog > TimeSpan.TicksPerSecond * 5)
            {
                vars.BossLastErrorLog = nowTicks;
                string message = snapshot == null ? "(null)" : snapshot;
                if (message.Length > 180) message = message.Substring(0, 180);
                print("[PBZ] boss save read failed: " + message);
            }
            return null;
        }

        string[] lines = snapshot.Split('\n');
        string[] head = lines[0].Split('\t');
        long snapTicks = 0L;
        long snapLength = 0L;
        if (head.Length > 2)
        {
            long.TryParse(head[1], out snapTicks);
            long.TryParse(head[2], out snapLength);
        }

        Dictionary<string, int> counts = new Dictionary<string, int>(StringComparer.Ordinal);
        for (int i = 1; i < lines.Length; i++)
        {
            string line = lines[i];
            if (line.Length == 0) continue;
            string[] parts = line.Split('\t');
            if (parts.Length < 2) continue;
            int value;
            if (int.TryParse(parts[1], out value)) counts[parts[0]] = value;
        }
        return Tuple.Create(snapTicks, snapLength, counts);
    });

    if ((bool)vars.BossApiReady)
    {
        try
        {
            string gameExe = "";
            try { gameExe = vars.Helper.Game.MainModule.FileName; } catch {}
            if (!string.IsNullOrEmpty(gameExe))
            {
                vars.BossSavePath = (string)vars.BossFindSaveMethod.Invoke(null, new object[] { gameExe }) ?? "";
            }
        }
        catch (Exception ex)
        {
            print("[PBZ] boss path resolve failed: " + ex.Message);
        }
        string resolvedSave = (string)vars.BossSavePath;
        print("[PBZ] boss save=" + (string.IsNullOrEmpty(resolvedSave) ? "(not found)" : resolvedSave));
        if (string.IsNullOrEmpty(resolvedSave))
        {
            print("[PBZ] boss auto-split waiting for PBZSaveGame.sav");
        }
    }
}

update
{

    vars.Paused = true;

    if ((bool)vars.BossApiReady)
    {
        long bossNow = DateTime.UtcNow.Ticks;
        bool pathMissing = string.IsNullOrEmpty((string)vars.BossSavePath);
        if (pathMissing && bossNow >= (long)vars.BossNextResolve)
        {
            vars.BossNextResolve = bossNow + TimeSpan.TicksPerSecond * 5;
            try
            {
                string bossExe = "";
                try { bossExe = vars.Helper.Game.MainModule.FileName; } catch {}
                if (!string.IsNullOrEmpty(bossExe))
                {
                    if (string.IsNullOrEmpty((string)vars.BossSavePath))
                    {
                        vars.BossSavePath = (string)vars.BossFindSaveMethod.Invoke(null, new object[] { bossExe }) ?? "";
                    }
                }
            }
            catch {}
        }

        string bossSavePath = (string)vars.BossSavePath;

        if (!string.IsNullOrEmpty(bossSavePath))
        {
            long bossFileTicks = 0L;
            long bossFileLength = -1L;
            try
            {
                FileInfo bossFile = new FileInfo(bossSavePath);
                if (bossFile.Exists)
                {
                    bossFileTicks = bossFile.LastWriteTimeUtc.Ticks;
                    bossFileLength = bossFile.Length;
                }
            }
            catch {}

            if (bossFileTicks != (long)vars.BossSigTicks || bossFileLength != (long)vars.BossSigLength)
            {
                Tuple<long, long, Dictionary<string, int>> bossSnapshot =
                    ((Func<Tuple<long, long, Dictionary<string, int>>>)vars.ReadBossSnapshot)();
                if (bossSnapshot != null)
                {
                    vars.BossSigTicks = bossSnapshot.Item1;
                    vars.BossSigLength = bossSnapshot.Item2;
                    Dictionary<string, int> bossCounts = bossSnapshot.Item3;
                    bool bossRunning = timer.CurrentPhase == TimerPhase.Running
                        || timer.CurrentPhase == TimerPhase.Paused;
                    Dictionary<string, int> bossBaseline = (Dictionary<string, int>)vars.BossBaseline;

                    if (bossBaseline == null || !bossRunning)
                    {
                        vars.BossBaseline = bossCounts;
                    }
                    else
                    {
                        Queue<string> bossPending = (Queue<string>)vars.BossPending;
                        foreach (KeyValuePair<string, int> bossPair in bossCounts)
                        {
                            int bossOld = 0;
                            bossBaseline.TryGetValue(bossPair.Key, out bossOld);
                            if (bossPair.Value <= bossOld) continue;

                            string bossSetting = "Boss_" + bossPair.Key;
                            bool bossEnabled = settings.ContainsKey(bossSetting) && (bool)settings[bossSetting];
                            print("[PBZ] boss kill " + bossPair.Key + " " + bossOld
                                + " -> " + bossPair.Value + " enabled=" + bossEnabled);
                            vars.BossLastKill = bossPair.Key;
                            if (bossEnabled) bossPending.Enqueue(bossSetting);
                        }
                        vars.BossBaseline = bossCounts;
                    }
                }
            }
        }
    }

    try
    {
        vars.Helper.Update();
        vars.Helper.MapPointers();

        if (current.World == null || (long)current.World == 0
            || current.WorldNameId == null || (int)current.WorldNameId == 0
            || current.Dest == null || (long)current.Dest == 0
            || current.Loading == null) return;

        long destClass = vars.Helper.Read<long>(0xe021828);
        long recordClass = vars.Helper.Read<long>(0xdf741c8, 0xc88, 0x80, 0x118, 0x240);
        if (destClass == 0 || recordClass != destClass) return;

        int nameId = (int)current.WorldNameId;
        if (nameId != (int)vars.LastNameId || string.IsNullOrEmpty((string)vars.WorldName))
        {
            string name = (string)((Func<int, string>)vars.ReadFName)(nameId);
            if (string.IsNullOrEmpty(name) || name == "None") return;
            vars.WorldName = name;
            vars.LastNameId = nameId;
        }

        string worldName = (string)vars.WorldName;
        vars.Frontend = worldName == "Untitled"
            || worldName == "ServerCheck"
            || worldName.IndexOf("StartMenu", StringComparison.OrdinalIgnoreCase) >= 0;
        vars.Paused = (byte)current.Loading != 0 || (bool)vars.Frontend;
    }
    catch {}
}

start
{
    if ((bool)vars.Paused) return false;
    if ((string)vars.WorldName != "PBZ_WP_ZhuLinGuWu") return false;
    if (current.Loading == null || old.Loading == null) return false;

    return (byte)current.Loading == 0 && (byte)old.Loading != 0;
}

isLoading
{
    return (bool)vars.Paused;
}

split
{
    if ((bool)vars.Paused) return false;
    if (timer.CurrentPhase != TimerPhase.Running) return false;

    Queue<string> bossPending = (Queue<string>)vars.BossPending;
    while (bossPending.Count > 0)
    {
        string bossSetting = bossPending.Dequeue();
        if (settings.ContainsKey(bossSetting) && (bool)settings[bossSetting])
        {
            print("[PBZ] split -> " + bossSetting);
            return true;
        }
    }
    return false;
}

onStart
{
    vars.BossPending = new Queue<string>();
    vars.BossBaseline = null;
    vars.BossSigTicks = 0L;
    vars.BossSigLength = -1L;

    try
    {
        Tuple<long, long, Dictionary<string, int>> bossSnapshot =
            ((Func<Tuple<long, long, Dictionary<string, int>>>)vars.ReadBossSnapshot)();
        if (bossSnapshot != null)
        {
            vars.BossBaseline = bossSnapshot.Item3;
            vars.BossSigTicks = bossSnapshot.Item1;
            vars.BossSigLength = bossSnapshot.Item2;
            print("[PBZ] boss baseline ready: " + bossSnapshot.Item3.Count + " bosses");
        }
    }
    catch (Exception ex)
    {
        print("[PBZ] boss baseline failed: " + ex.Message);
    }
}

onReset
{
    vars.BossPending = new Queue<string>();
    vars.BossBaseline = null;
    vars.BossSigTicks = 0L;
    vars.BossSigLength = -1L;
}

exit
{
    vars.Paused = true;
    timer.IsGameTimePaused = true;
    vars.BossPending = new Queue<string>();
    vars.BossBaseline = null;
}
