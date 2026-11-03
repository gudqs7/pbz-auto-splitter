// 旧版存档读取变体。生产注释只保留在这里；Components 和发布包由
// build_pbz_runtime.ps1 生成，并会移除全部注释。
state("PBZ"){}

// LiveSplit 生命周期钩子：startup
// 作用：加载 asl-help，并立即加载匹配语言的 Boss 设置 XML。
// 入参：无。LiveSplit 提供设置构建器。
// 返回：null。
// 原理：XML 与游戏进程是否存在无关，因此在加载委托创建后立即读取；
// 存档读取 DLL 仍在稍后的 init 中按需加载。
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

// LiveSplit 生命周期钩子：init
// 作用：验证并绑定 PBZ，初始化加载 watcher、名称解码和存档读取 API。
// 入参：无。ASL 运行时已经连接到名为 PBZ 的进程。
// 返回：null。
// 原理：内存偏移负责启动和加载暂停；存档击杀计数独立于实时 Actor 状态，
// 单独负责 Boss 打点。
init
{
    // PBZ 会先启动一个同名的小型引导进程。必须绑定完整游戏模块，
    // 保证静态偏移始终相对游戏模块计算。
    // FindGame 委托。
    // 入参：无。
    // 返回：模块大小符合目标构建的 PBZ 进程，否则 null。
    // 原理：通过模块大小排除同名引导进程或辅助进程。
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

    // ReadFName 委托。
    // 入参：UE FName id。
    // 返回：解码后的名称；id 无效、名称为空或为 None 时返回 null。
    // 原理：先解析全局名称块，再根据条目头解码长度和字符宽度。
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

    // Boss 存档读取会话状态。基线计数表示本次尝试开始前的状态，
    // 待处理打点由 split 钩子消费。
    vars.BossApiReady = false;
    vars.BossBaseline = null;
    vars.BossPending = new Queue<string>();
    vars.BossSigTicks = 0L;
    vars.BossSigLength = -1L;
    vars.BossSavePath = "";
    vars.BossNextResolve = 0L;
    vars.BossLastErrorLog = 0L;
    vars.BossLastKill = "";

    // 反射加载延迟到 init，这样 DLL 缺失时只会关闭存档打点功能，
    // 不会阻止内存加载检测脚本启动。
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

    // ReadBossSnapshot 委托。
    // 入参：无，通过反射得到的读取 API 读取 vars.BossSavePath。
    // 返回：(文件时间, 文件长度, Boss 计数)，API 或读取失败时 null。
    // 原理：把读取器返回的制表符分隔 OK 文本解析为 Boss 计数；
    // 错误日志最多每五秒记录一次。
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

// LiveSplit 生命周期钩子：update
// 作用：采样存档中的 Boss 计数，同时更新失败保持暂停的加载状态。
// 入参：current/old ASL 状态、vars、timer 和已绑定 PBZ 进程。
// 返回：null。Boss 存档跟踪独立于内存指针链运行。
// 原理：只有存档签名变化才触发解码；第一次快照作为基线，
// 后续计数增加时把已启用 Boss 设置加入队列。
update
{
    // 失败保持暂停：所有指针、加载标志和世界名都通过验证后才继续。
    vars.Paused = true;

    // Boss 存档跟踪有意独立于指针链和加载状态，
    // 因此内存偏移失效时仍可使用存档打点。
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
        // 只有存档时间或长度变化时才重新解码，
        // 避免对未变化文件反复解密和解压。
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

// LiveSplit 生命周期钩子：start
// 作用：在已验证起始世界的加载完成边沿自动启动计时器。
// 入参：current/old 的 Loading，以及 vars.Paused/WorldName。
// 返回：在预期起始世界中，Loading 从非零变为零时返回 true。
// 原理：要求 old/current 有效，并且世界已验证且未暂停。
start
{
    if ((bool)vars.Paused) return false;
    if ((string)vars.WorldName != "PBZ_WP_ZhuLinGuWu") return false;
    if (current.Loading == null || old.Loading == null) return false;

    return (byte)current.Loading == 0 && (byte)old.Loading != 0;
}

// LiveSplit 生命周期钩子：isLoading
// 作用：内存加载门控处于暂停时暂停 LiveSplit 游戏时间。
// 入参：vars.Paused。
// 返回：当前暂停状态。
// 原理：LiveSplit 只在计时器 Running/Paused 阶段调用该钩子。
isLoading
{
    return (bool)vars.Paused;
}

// LiveSplit 生命周期钩子：split
// 作用：从 BossPending 消费一个已启用的存档 Boss 击杀。
// 入参：vars.Paused、计时器阶段、Pending 和递归父链后的设置值。
// 返回：找到一个启用设置时返回 true，否则 false。
// 原理：持续出队过期或关闭的设置，直到找到启用项。
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

// LiveSplit 生命周期钩子：onStart
// 作用：重置存档状态，并为新一次跑图建立 Boss 计数基线。
// 入参：无。
// 返回：null。
// 原理：清空 Pending、Baseline 和签名后读取一次新快照；
// 基线读取失败时保持 null，由后续 update 重建。
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

// LiveSplit 生命周期钩子：onReset
// 作用：丢弃存档读取基线和待处理打点，为下一次尝试做准备。
// 入参：无。
// 返回：null。
// 原理：下一次 Running 状态 update 或 onStart 会重新建立基线。
onReset
{
    vars.BossPending = new Queue<string>();
    vars.BossBaseline = null;
    vars.BossSigTicks = 0L;
    vars.BossSigLength = -1L;
}

// LiveSplit 生命周期钩子：exit
// 作用：PBZ 退出时暂停游戏时间并释放当前尝试的存档状态。
// 入参：无。
// 返回：null。
// 原理：保留反射读取对象以便后续重新连接，但清空与上一进程会话绑定的
// 计数和待处理打点。
exit
{
    vars.Paused = true;
    timer.IsGameTimePaused = true;
    vars.BossPending = new Queue<string>();
    vars.BossBaseline = null;
}
