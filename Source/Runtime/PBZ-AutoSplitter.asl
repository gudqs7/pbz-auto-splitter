/*
 * Phantom Blade Zero 仅内存自动打点脚本。
 *
 * 源码规则:
 * - 本文件是可编辑源码，也是唯一保留注释的位置。
 * - Components/PBZ-AutoSplitter.asl、发布包和本地 LiveSplit Components 目录
 *   都由本文件生成，并在生成时移除全部注释。
 * - 修改本文件后运行 Source/build_pbz_runtime.ps1。
 */
state("PBZ"){}

// LiveSplit 生命周期钩子：startup
// 作用：在游戏进程出现前初始化 helper、日志并立即加载 Boss 设置。
// 入参：没有显式参数，LiveSplit 通过 ASL 注入设置构建器。
// 返回：null。
// 原理：每次脚本加载或重载只运行一次；XML 与游戏进程是否存在无关，
// 因此在加载委托创建后立即读取。
startup
{
    // 从 LiveSplit 主程序位置解析 Components 目录。必须在运行时计算，
    // 因为 LiveSplit 可能安装在构建仓库之外。
    string componentDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Components");
    Assembly.Load(File.ReadAllBytes(Path.Combine(componentDir, "asl-help"))).CreateInstance("Basic");
    vars.Helper.GameName = "Phantom Blade Zero";

    // 文件日志委托。
    // 入参：message，已经格式化好的一行日志。
    // 返回：void。
    // 原理：把本地时间日志追加到 LiveSplit\Logs。日志失败不能影响计时器，
    // 因此目录和文件读写异常全部吞掉。
    vars.LogPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Logs", "PBZ-AutoSplitter.log");
    vars.Log = (Action<string>)(message =>
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName((string)vars.LogPath));
            File.AppendAllText(
                (string)vars.LogPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine);
        }
        catch {}
    });

    vars.SettingsLoaded = false;
    vars.LoadSettings = (Action)(() =>
    {
        if (!(bool)vars.SettingsLoaded)
        {
            try
            {
                // 设置文件解析顺序：
                // 1. 完整区域名，例如 PBZ.BossSettings.zh-CN.xml。
                // 2. 基础语言名，例如 PBZ.BossSettings.en.xml。
                // 3. 默认的 PBZ.BossSettings.xml。
                // 这里使用 CurrentCulture 而不是 CurrentUICulture，因此默认跟随
                // Windows 区域格式，除非存在完全匹配的文件。
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
                ((Action<string>)vars.Log)("settings loaded: culture=" + culture + " file=" + settingsPath);
            }
            catch (Exception ex)
            {
                ((Action<string>)vars.Log)("settings load failed: " + ex.Message);
            }
        }
    });
    ((Action)vars.LoadSettings)();
}

// LiveSplit 生命周期钩子：init
// 作用：绑定已验证的游戏构建，并创建 update 使用的全部 watcher、缓存和委托。
// 入参：没有显式参数；ASL 运行时已选中名为 PBZ 的进程并刷新初始状态值。
// 返回：null。
// 原理：固定偏移只对精确匹配的可执行文件布局安全；持久状态放在 vars 中，
// 才能跨每次临时编译的 ASL 方法继续使用。
init
{
    // 数据流：
    // 1. 绑定通过校验的 PBZ 游戏进程。
    // 2. 读取 World、Dest 和 Loading，得到失败时保持暂停的状态。
    // 3. 按限频计划解析本地玩家和 BeHatredList。
    // 4. 通过可观察边沿跟踪已配置和未配置 Boss Actor。
    // 5. 把已配置 Boss 的死亡事件送入 split 钩子队列。

    // PBZ 会先启动一个同名引导进程，因此必须绑定完整游戏模块，
    // 保证静态偏移始终相对游戏模块基址计算。
    //
    // FindGame 委托。
    // 入参：无。
    // 返回：匹配的 Process，失败时返回 null。
    // 原理：遍历所有 PBZ 进程，跳过访问失败项，只接受模块大小和文件版本
    // 都与目标构建一致的进程。
    string expectedBuild = "CL-302256_JKS-17280";
    vars.FindGame = (Func<Process>)(() =>
    {
        Process best = null;
        int bestSize = 0;
        foreach (Process p in Process.GetProcessesByName("PBZ"))
        {
            try
            {
                int size = p.MainModule.ModuleMemorySize;
                string build = p.MainModule.FileVersionInfo.FileVersion;
                if (size == 0x1e0bb000
                    && string.Equals(build, expectedBuild, StringComparison.Ordinal)
                    && size > bestSize)
                {
                    best = p;
                    bestSize = size;
                }
            }
            catch {}
        }
        return best;
    });

    // 引导进程会比完整游戏早出现，主进程可能只晚几十毫秒。
    // 初始化阶段做有界重试，最多等待约一秒，避免首次枚举恰好落在空档。
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
        ((Action<string>)vars.Log)(
            "build gate: matched PBZ process, retry=" + findAttempt);
    }
    else
    {
        ((Action<string>)vars.Log)("build gate: no matching PBZ process");
    }

    // World、Dest 和 Loading watcher。
    // 入参：每次 Make 调用接收模块相对基址偏移和后续指针链偏移。
    // 返回：映射到 current.World/current.Dest/current.Loading 的 watcher 对象。
    // 原理：asl-help 对每个中间 offset 先解引用指针，再在最终地址读取目标值。
    vars.Helper["World"] = vars.Helper.Make<long>(0xdfe9278, 0xc88, 0x78);
    vars.Helper["WorldNameId"] = vars.Helper.Make<int>(0xdfe9278, 0xc88, 0x78, 0x18);
    vars.Helper["Dest"] = vars.Helper.Make<long>(0xdfe9278, 0xc88, 0x80, 0x118, 0x248);
    vars.Helper["Loading"] = vars.Helper.Make<byte>(0xdfe9278, 0xc88, 0x80, 0x118, 0x248, 0x250);

    vars.Helper["World"].FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull;
    vars.Helper["WorldNameId"].FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull;
    vars.Helper["Dest"].FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull;
    vars.Helper["Loading"].FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull;

    vars.WorldName = "";
    vars.LastNameId = -1;
    vars.Paused = true;

    vars.DeadTagIndex = 0x53938;
    vars.ExcludeFromBossRecordTagIndex = 0xe23867;
    vars.BossScanIntervalTicks = TimeSpan.TicksPerMillisecond * 50;
    vars.IdleBossScanIntervalTicks = TimeSpan.TicksPerMillisecond * 100;
    vars.PlayerReconcileIntervalTicks = TimeSpan.TicksPerSecond * 2;
    vars.BossRemovalGraceTicks = TimeSpan.TicksPerSecond * 60;
    vars.BossLowHealthRemovalRatio = 0.02f;

    // FName 解码缓存。
    // 键：32 位 UE FName id；值：解码后的名称字符串。
    // 避免世界名和 UClass 名在同一世界代际内重复读取名称池。
    vars.MemoryBossFNameCache = new Dictionary<int, string>();

    // UClass 名称缓存。
    // 键：UClass 对象指针；值：该类对应的 UClass 名称。
    // UClass 指针在同一世界代际内稳定，世界切换时必须整体清空。
    vars.MemoryBossClassCache = new Dictionary<long, string>();

    // Actor 子组件缓存。
    // 键：Actor 地址；值：long[6]。
    // [0] UClass 指针，[1] 对象 FName id，[2] InternalIndex，
    // [3] AttributeSetBase，[4] AbilitySystemComponent，[5] 组件刷新时间。
    // 地址相同但身份三元组不匹配时禁止复用，防止对象销毁后的地址复用误读。
    vars.MemoryBossActorCache = new Dictionary<long, long[]>();

    // 本地玩家完整解析记录。
    // null 表示尚无有效玩家链路；非空时保存 long[9]：
    // [0] PlayerController，[1] Pawn，[2] HatredManager，
    // [3] AttributeSetBase，[4] AbilitySystemComponent，
    // [5] Pawn UClass 指针，[6] Pawn 对象 FName id，
    // [7] Pawn InternalIndex，[8] 最近一次完整解析时间。
    vars.MemoryBossPlayerRecord = null;

    // 当前 Actor 缓存所属的 World/Dest 地址代际。
    // 两者都非零且与当前世界一致时才允许命中缓存；任一变化都会失效全部对象缓存。
    vars.MemoryBossCacheWorld = 0L;
    vars.MemoryBossCacheDest = 0L;

    // 下一次 Boss 扫描的 UTC ticks。
    // 0 表示立即允许扫描；正常值为“上次扫描时间 + 当前阶段对应的扫描间隔”。
    vars.MemoryBossNextScan = 0L;

    // ReadFName 委托。
    // 入参：32 位 UE FName id。
    // 返回：解码后的 ASCII/UTF-16 名称；id 无效或为 None 时返回 null。
    // 原理：高 16 位选择名称池 block，低 16 位选择以 2 字节为单位的条目偏移；
    // 条目头记录字符宽度和长度。成功结果按 id 缓存，避免重复跨进程读取。
    vars.ReadFName = (Func<int, string>)(nameId =>
    {
        if (nameId <= 0) return null;

        Dictionary<int, string> cache = (Dictionary<int, string>)vars.MemoryBossFNameCache;
        string cached;
        if (cache.TryGetValue(nameId, out cached)) return cached;

        int blockIndex = nameId >> 16;
        int blockOffset = (nameId & 0xffff) * 2;
        int blockCount = vars.Helper.Read<int>(0xdd86ac8);
        if (blockIndex < 0 || blockIndex >= blockCount) return null;

        long block = vars.Helper.Read<long>(0xdd86ac8 + 8 + blockIndex * 8);
        if (block == 0) return null;

        ushort header = vars.Helper.Read<ushort>((IntPtr)(block + blockOffset));
        int length = (header >> 6) & 0x3ff;
        if (length <= 0 || length > 1024) return null;

        bool wide = (header & 1) != 0;
        string name = vars.Helper.ReadString(
            length * (wide ? 2 : 1),
            wide ? ReadStringType.UTF16 : ReadStringType.ASCII,
            (IntPtr)(block + blockOffset + 2));
        if (string.IsNullOrEmpty(name) || name == "None") return null;

        cache[nameId] = name;
        return name;
    });

    // ReadObjectClassName 委托。
    // 入参：UClass 对象指针。
    // 返回：类名；指针或名称无效时返回 null。
    // 原理：UClass+0x18 保存类 FName id。UClass 指针在一个世界代际内稳定，
    // 因此按 UClass 缓存可避免重复读取名称。
    vars.ReadObjectClassName = (Func<long, string>)(classPtr =>
    {
        if (classPtr <= 0) return null;

        Dictionary<long, string> cache = (Dictionary<long, string>)vars.MemoryBossClassCache;
        string cached;
        if (cache.TryGetValue(classPtr, out cached)) return cached;

        int nameId = vars.Helper.Read<int>((IntPtr)(classPtr + 0x18));
        string className = ((Func<int, string>)vars.ReadFName)(nameId);
        if (!string.IsNullOrEmpty(className)) cache[classPtr] = className;
        return className;
    });

    // ReadObjectMeta 委托。
    // 入参：UObject 或 Actor 地址。
    // 返回：包含 UClass 指针、对象 FName id 和 InternalIndex 的 long[3]。
    // 原理：一次读取 0x20 字节对象头，比三次独立读取更便宜也更一致；
    // 返回的三元组作为对象身份键。
    vars.ReadObjectMeta = (Func<long, long[]>)(obj =>
    {
        if (obj <= 0) return null;

        byte[] header = vars.Helper.ReadSpan<byte>(0x20, (IntPtr)obj);
        if (header == null || header.Length != 0x20) return null;

        long classPtr = BitConverter.ToInt64(header, 0x10);
        int nameId = BitConverter.ToInt32(header, 0x18);
        int internalIndex = BitConverter.ToInt32(header, 0x0c);
        if (classPtr <= 0x10000 || nameId <= 0 || internalIndex < 0) return null;

        return new long[] { classPtr, nameId, internalIndex };
    });

    // Actor 身份比较辅助方法。
    // 入参：当前 Actor 地址，以及该地址保存的身份缓存记录。
    // 返回：只有三个身份字段全部匹配时才返回 true。
    // 原理：UE 销毁对象后可能复用地址，因此单独一个地址不是稳定身份。
    vars.MemoryBossActorIdentityMatches = (Func<long, long[], bool>)((obj, record) =>
    {
        if (record == null || record.Length < 3) return false;
        long[] meta = ((Func<long, long[]>)vars.ReadObjectMeta)(obj);
        return meta != null
            && meta[0] == record[0]
            && meta[1] == record[1]
            && meta[2] == record[2];
    });

    // ReadCharacterComponents 委托。
    // 入参：APBZCharacter 地址。
    // 返回：{AbilitySystemComponent, AttributeSetBase} 的 long[2]，失败时 null。
    // 原理：APBZCharacter+0x750 和 +0x758 相邻，一次读取 0x10 字节即可
    // 同时取得两个组件指针，避免两次读取之间的对象重建竞争。
    vars.ReadCharacterComponents = (Func<long, long[]>)(character =>
    {
        if (character <= 0) return null;
        byte[] data = vars.Helper.ReadSpan<byte>(0x10, (IntPtr)(character + 0x750));
        if (data == null || data.Length != 0x10) return null;
        return new long[]
        {
            BitConverter.ToInt64(data, 0x00),
            BitConverter.ToInt64(data, 0x08)
        };
    });

    // ReadHealthPair 委托。
    // 入参：AttributeSetBase 地址。
    // 返回：(当前生命, 最大生命, 是否有效)；无效读取返回 valid=false。
    // 原理：从 +0x64 开始读取 0x14 字节，当前生命在跨度内 +0x00，
    // 最大生命在 +0x10。NaN 和 Infinity 一律视为无效。
    vars.ReadHealthPair = (Func<long, Tuple<float, float, bool>>)(attributeSet =>
    {
        if (attributeSet <= 0) return Tuple.Create(0.0f, 0.0f, false);

        byte[] data = vars.Helper.ReadSpan<byte>(0x14, (IntPtr)(attributeSet + 0x64));
        if (data == null || data.Length != 0x14) return Tuple.Create(0.0f, 0.0f, false);

        float health = BitConverter.ToSingle(data, 0x00);
        float maxHealth = BitConverter.ToSingle(data, 0x10);
        if (float.IsNaN(health) || float.IsInfinity(health)
            || float.IsNaN(maxHealth) || float.IsInfinity(maxHealth))
        {
            return Tuple.Create(0.0f, 0.0f, false);
        }
        return Tuple.Create(health, maxHealth, true);
    });

    // ReadTagFlags 委托。
    // 入参：AbilitySystemComponent 地址。
    // 返回：
    //   -1 读取失败；
    //    0 读取成功，Dead 和 ExcludeFromBossRecord 均未激活；
    //    1 仅 Dead 激活；
    //    2 仅 ExcludeFromBossRecord 激活；
    //    3 两个 Tag 均激活。
    // 注意：-1 的位模式也包含 bit 0/1，调用方必须先判断 flags >= 0，
    //       再使用 flags & 1 或 flags & 2。
    // 原理：先读取 ASC+0xEE8 的 TArray 头，再批量读取所有 0x10 字节 Tag
    // 计数项。调用方必须先处理 Exclude，再处理 Dead。
    vars.ReadTagFlags = (Func<long, int>)(abilitySystem =>
    {
        if (abilitySystem <= 0) return -1;

        byte[] header = vars.Helper.ReadSpan<byte>(
            0x10,
            (IntPtr)(abilitySystem + 0xee8));
        if (header == null || header.Length != 0x10) return -1;

        long entries = BitConverter.ToInt64(header, 0x00);
        int entryCount = BitConverter.ToInt32(header, 0x08);
        if (entryCount < 0 || entryCount > 4096) return -1;
        if (entryCount == 0) return 0;
        if (entries == 0) return -1;

        byte[] data = vars.Helper.ReadSpan<byte>(
            entryCount * 0x10,
            (IntPtr)entries);
        if (data == null || data.Length != entryCount * 0x10) return -1;

        int flags = 0;
        int deadTag = (int)vars.DeadTagIndex;
        int excludeTag = (int)vars.ExcludeFromBossRecordTagIndex;
        for (int i = 0; i < entryCount; i++)
        {
            int offset = i * 0x10;
            ulong tagValue = BitConverter.ToUInt64(data, offset);
            int tagIndex = (int)(tagValue & 0xffffffffL);
            if (tagIndex != deadTag && tagIndex != excludeTag) continue;

            int tagCount = BitConverter.ToInt32(data, offset + 0x08);
            if (tagCount <= 0) continue;
            if (tagIndex == deadTag) flags |= 1;
            else flags |= 2;
        }
        return flags;
    });

    // GetBossSetting 委托。
    // 入参：类名，例如 "BP_Monster_Danghui_C"。
    // 返回：匹配的设置 id，例如 "Boss_BP_Monster_Danghui"；无匹配时 null。
    // 原理：只移除 UE 生成的 "_C" 后缀，并要求 XML 中存在完全相同的键名；
    // 永远不使用界面显示文本作为身份。
    vars.GetBossSetting = (Func<string, string>)(className =>
    {
        if (string.IsNullOrEmpty(className)
            || !className.EndsWith("_C", StringComparison.Ordinal)) return null;

        string bossName = className.Substring(0, className.Length - 2);
        string setting = "Boss_" + bossName;
        return settings.ContainsKey(setting) ? setting : null;
    });

    // IsAutoSplitEnabled 委托。
    // 入参：无。
    // 返回：AutoSplitEnabled 缺失或为 true 时返回 true；读取异常时返回 false。
    // 原理：总开关只控制 split 消费。关闭时 Actor 检测和已启用 Boss 日志仍运行。
    vars.IsAutoSplitEnabled = (Func<bool>)(() =>
    {
        try
        {
            return !settings.ContainsKey("AutoSplitEnabled")
                || (bool)settings["AutoSplitEnabled"];
        }
        catch { return false; }
    });

    // ReadMemoryBossPlayerState 委托。
    // 入参：ResolveMemoryBossPlayer 生成的 playerRecord[9]。
    // 返回：(当前生命, 最大生命, 是否有效, Tag 标记)，失败时 null。
    // 原理：保持原先 update 的读取顺序，先读生命再读 GameplayTag；
    // 调用方可以重新解析玩家后重试一次。
    vars.ReadMemoryBossPlayerState = (Func<long[], Tuple<float, float, bool, int>>)(record =>
    {
        if (record == null || record.Length < 5) return null;
        Tuple<float, float, bool> health =
            ((Func<long, Tuple<float, float, bool>>)vars.ReadHealthPair)(record[3]);
        int tagFlags = ((Func<long, int>)vars.ReadTagFlags)(record[4]);
        if (health == null || !health.Item3 || tagFlags < 0) return null;
        return Tuple.Create(health.Item1, health.Item2, true, tagFlags);
    });

    // ReadMemoryBossActorList 委托。
    // 入参：HatredManager 地址。
    // 返回：{Actor 数组指针, Actor 数量} 的 long[2]；数据非法时 null。
    // 原理：空 BeHatredList 可能同时把指针和数量清零，因此 count=0 时
    // 即使数据指针为 0 也必须作为合法空列表处理。
    vars.ReadMemoryBossActorList = (Func<long, long[]>)(hatredManager =>
    {
        byte[] header = vars.Helper.ReadSpan<byte>(0x10, (IntPtr)(hatredManager + 0xd8));
        if (header == null || header.Length != 0x10) return null;
        long actorArray = BitConverter.ToInt64(header, 0x00);
        int actorCount = BitConverter.ToInt32(header, 0x08);
        if (actorCount < 0 || actorCount > 128
            || (actorCount > 0 && actorArray == 0)) return null;
        return new long[] { actorArray, actorCount };
    });

    // ReadMemoryBossActorState 委托。
    // 入参：包含身份和子组件指针的 Actor 缓存记录。
    // 返回：(Tag 标记, 当前生命, 最大生命)；任一组件无效时 null。
    // 原理：Tag 和生命被作为一个逻辑观测同时采样，调用方不会基于半有效状态打点。
    vars.ReadMemoryBossActorState = (Func<long[], Tuple<int, float, float>>)(record =>
    {
        if (record == null || record.Length < 5) return null;
        int tagFlags = ((Func<long, int>)vars.ReadTagFlags)(record[4]);
        Tuple<float, float, bool> health =
            ((Func<long, Tuple<float, float, bool>>)vars.ReadHealthPair)(record[3]);
        if (tagFlags < 0 || health == null || !health.Item3) return null;
        return Tuple.Create(tagFlags, health.Item1, health.Item2);
    });

    // ResolveMemoryBossPlayer 委托。
    // 入参：无，使用固定模块相对偏移。
    // 返回：重建 playerRecord 并验证核心组件后返回 true。
    // 原理：依次遍历 GameEngine、视口/客户端链、本地玩家、控制器和
    // AcknowledgedPawn，再验证身份、ASC、AttributeSet 和 HatredManager
    // 后才缓存解析结果。
    vars.ResolveMemoryBossPlayer = (Func<bool>)(() =>
    {
        try
        {
            // 固定玩家链路：
            // GEngine -> GameViewportClient -> GameInstance -> LocalPlayers[0]
            // -> LocalPlayer -> PlayerController -> AcknowledgedPawn.
            long controller = vars.Helper.Read<long>(
                0xdfe9278, 0xc88, 0x80, 0x38, 0x0, 0x30);
            if (controller <= 0) return false;

            long player = vars.Helper.Read<long>((IntPtr)(controller + 0x358));
            if (player <= 0) return false;

            long[] meta = ((Func<long, long[]>)vars.ReadObjectMeta)(player);
            long[] components = ((Func<long, long[]>)vars.ReadCharacterComponents)(player);
            long hatredManager = vars.Helper.Read<long>((IntPtr)(player + 0xe90));
            if (meta == null || components == null
                || components[0] <= 0 || components[1] <= 0
                || hatredManager <= 0) return false;

            Tuple<float, float, bool> health =
                ((Func<long, Tuple<float, float, bool>>)vars.ReadHealthPair)(components[1]);
            if (health == null || !health.Item3) return false;

            long nowTicks = DateTime.UtcNow.Ticks;
            // 玩家记录字段布局：
            // [0] PlayerController
            // [1] 本地 Pawn
            // [2] HatredManager
            // [3] AttributeSetBase
            // [4] AbilitySystemComponent
            // [5..7] Pawn 的 UClass/FName/内部索引身份键
            // [8] 完整链路最近解析时间
            vars.MemoryBossPlayerRecord = new long[]
            {
                controller, player, hatredManager, components[1], components[0],
                meta[0], meta[1], meta[2], nowTicks
            };
            return true;
        }
        catch {}
        return false;
    });

    // ClearMemoryBossState 操作。
    // 入参：无。
    // 返回：void。
    // 原理：清除当前采样/世界相关的观测，同时保留可复用的对象名称和组件缓存；
    // 会话级队列和已消费设置不在这里处理。
    vars.ClearMemoryBossState = (Action)(() =>
    {
        ((Dictionary<long, string>)vars.MemoryBossSeen).Clear();
        ((Dictionary<long, string>)vars.MemoryBossUnknownSeen).Clear();
        ((Dictionary<long, long>)vars.MemoryBossUnknownMissingSince).Clear();
        ((Dictionary<long, string>)vars.MemoryBossChecks).Clear();
        ((Dictionary<long, long>)vars.MemoryBossCheckUntil).Clear();
        ((HashSet<long>)vars.MemoryBossArmed).Clear();
        ((Dictionary<long, float>)vars.MemoryBossLastHealth).Clear();
        ((Dictionary<long, bool>)vars.MemoryBossLastDead).Clear();
        ((Dictionary<long, float>)vars.MemoryBossLastHealthRatio).Clear();
    });

    // 待消费的 Boss 设置队列。键值不适用；元素为 Boss_* 设置 id。
    // 仅保存已通过总开关和单项开关的事件，split 钩子按 FIFO 顺序消费。
    vars.MemoryBossPending = new Queue<string>();

    // 本计时周期内已经处理过死亡边沿的 Boss 设置集合。
    // 键：Boss_* 设置 id；用途：防止同一 Boss 在同一周期重复打点。
    vars.MemoryBossConsumed = new HashSet<string>();

    // 当前 BeHatredList 中已成功采样且已启用的 Actor 跟踪表。
    // 键：Actor 地址；值：对应 Boss_* 设置 id。
    vars.MemoryBossSeen = new Dictionary<long, string>();

    // 未配置 Boss 候选的轻量跟踪表。
    // 键：Actor 地址；值：UClass 名称。该表只用于日志，不参与打点。
    vars.MemoryBossUnknownSeen = new Dictionary<long, string>();

    // 未配置 Boss 候选开始缺失的时间。
    // 键：Actor 地址；值：首次移出 BeHatredList 的 UTC ticks。
    vars.MemoryBossUnknownMissingSince = new Dictionary<long, long>();

    // 已离开 BeHatredList、但仍处于移除宽限期的已配置 Actor。
    // 键：Actor 地址；值：Boss_* 设置 id。
    vars.MemoryBossChecks = new Dictionary<long, string>();

    // 移除宽限期的截止时间。
    // 键：Actor 地址；值：宽限结束时的 UTC ticks。默认宽限六十秒。
    vars.MemoryBossCheckUntil = new Dictionary<long, long>();

    // 已观察到有效存活状态的 Actor 地址集合。
    // 只有在这个集合中的 Actor 才能通过后续 Dead Tag 或零生命值产生死亡边沿。
    vars.MemoryBossArmed = new HashSet<long>();

    // 本次计时周期内已经记录过“出现”日志的 Boss 设置集合。
    // 键：Boss_* 设置 id；用途：避免同一 Boss 每次扫描重复写 appeared 日志。
    vars.MemoryBossLoggedAppeared = new HashSet<string>();

    // 最近一次读取到的 Boss 当前生命值。
    // 键：Actor 地址；值：当前生命值。主要用于移除边沿诊断日志。
    vars.MemoryBossLastHealth = new Dictionary<long, float>();

    // 最近一次读取到的 Boss Dead Tag 状态。
    // 键：Actor 地址；值：Dead Tag 是否激活。主要用于移除边沿诊断日志。
    vars.MemoryBossLastDead = new Dictionary<long, bool>();

    // 最近一次有效读取到的 Boss 生命值比例。
    // 键：Actor 地址；值：当前生命值 / 最大生命值，用于移除边沿的即时低血打点。
    vars.MemoryBossLastHealthRatio = new Dictionary<long, float>();

    // Boss 血量里程碑日志状态。
    // 键：Boss_* 设置 id；值：已经达到的最低百分比档位（100/75/50/25/10）。
    vars.MemoryBossHealthMilestone = new Dictionary<string, int>();

    // ForgetMemoryBossActor 操作。
    // 入参：Actor 地址。
    // 返回：void。
    // 原理：移除逻辑跟踪状态，避免该地址之后仍产生移除边沿；
    // 组件缓存由另一个操作单独负责。
    vars.ForgetMemoryBossActor = (Action<long>)(actor =>
    {
        ((Dictionary<long, string>)vars.MemoryBossSeen).Remove(actor);
        ((Dictionary<long, string>)vars.MemoryBossChecks).Remove(actor);
        ((Dictionary<long, long>)vars.MemoryBossCheckUntil).Remove(actor);
        ((HashSet<long>)vars.MemoryBossArmed).Remove(actor);
    });

    // ForgetMemoryBossActorCache 操作。
    // 入参：Actor 地址。
    // 返回：void。
    // 原理：身份或指针有效性不再可信时，删除缓存的子组件指针。
    vars.ForgetMemoryBossActorCache = (Action<long>)(actor =>
    {
        ((Dictionary<long, long[]>)vars.MemoryBossActorCache).Remove(actor);
    });

    // ForgetMemoryBossActorSamples 操作。
    // 入参：Actor 地址。
    // 返回：void。
    // 原理：删除仅用于诊断和移除边沿原因文本的最近生命/死亡观测。
    vars.ForgetMemoryBossActorSamples = (Action<long>)(actor =>
    {
        ((Dictionary<long, float>)vars.MemoryBossLastHealth).Remove(actor);
        ((Dictionary<long, bool>)vars.MemoryBossLastDead).Remove(actor);
        ((Dictionary<long, float>)vars.MemoryBossLastHealthRatio).Remove(actor);
    });

    // ResetMemoryBossSession 操作。
    // 入参：resetNextScan=true 表示立即重新扫描，exit/shutdown 路径传 false。
    // 返回：void。
    // 原理：新计时周期必须使用全新的队列、去重、日志和血量里程碑状态；
    // 下一扫描时间可选重置，以免改变 exit/shutdown 路径的可观察时序。
    vars.ResetMemoryBossSession = (Action<bool>)(resetNextScan =>
    {
        vars.MemoryBossPending = new Queue<string>();
        vars.MemoryBossConsumed = new HashSet<string>();
        vars.MemoryBossLoggedAppeared = new HashSet<string>();
        vars.MemoryBossHealthMilestone = new Dictionary<string, int>();
        if (resetNextScan) vars.MemoryBossNextScan = 0L;
        ((Action)vars.ClearMemoryBossState)();
    });

    // QueueMemoryBoss 操作。
    // 入参：设置 id 和可读的死亡原因。
    // 返回：void。
    // 原理：Consumed 以设置 id 而不是 Actor 地址为键，因此同一 Boss 阶段
    // 每个计时周期最多打点一次。死亡日志先于总开关和单项开关判断，
    // 只有两者都启用的事件才进入 Pending。
    vars.QueueMemoryBoss = (Action<string, string>)((setting, reason) =>
    {
        if (!string.IsNullOrEmpty(setting))
        {
            HashSet<string> consumed = (HashSet<string>)vars.MemoryBossConsumed;
            if (!consumed.Contains(setting))
            {
                consumed.Add(setting);

                bool autoSplitEnabled = ((Func<bool>)vars.IsAutoSplitEnabled)();
                bool bossEnabled = settings.ContainsKey(setting) && (bool)settings[setting];
                // 死亡日志不受总开关影响，便于排查漏配或关闭打点的场景。
                ((Action<string>)vars.Log)(
                    "boss died: setting=" + setting
                    + " reason=" + reason
                    + " world=" + (string)vars.WorldName
                    + " phase=" + timer.CurrentPhase.ToString()
                    + " auto-split=" + autoSplitEnabled
                    + " boss-setting=" + bossEnabled);
                if (autoSplitEnabled && bossEnabled)
                {
                    Queue<string> pending = (Queue<string>)vars.MemoryBossPending;
                    pending.Enqueue(setting);
                }
            }
        }
    });

    // InvalidateMemoryBossCaches 操作。
    // 入参：此前存在状态时写入日志的诊断原因。
    // 返回：void。
    // 原理：World 或 Dest 更换会使对象、UClass、组件和玩家地址全部失效；
    // 名称缓存和类名缓存也只对当前世界代际有效。
    vars.InvalidateMemoryBossCaches = (Action<string>)(reason =>
    {
        bool hadState = (long)vars.MemoryBossCacheWorld != 0
            || (long)vars.MemoryBossCacheDest != 0
            || ((Dictionary<long, long[]>)vars.MemoryBossActorCache).Count > 0
            || vars.MemoryBossPlayerRecord != null;

        ((Action)vars.ClearMemoryBossState)();
        ((Dictionary<int, string>)vars.MemoryBossFNameCache).Clear();
        ((Dictionary<long, string>)vars.MemoryBossClassCache).Clear();
        ((Dictionary<long, long[]>)vars.MemoryBossActorCache).Clear();
        vars.MemoryBossPlayerRecord = null;
        vars.MemoryBossCacheWorld = 0L;
        vars.MemoryBossCacheDest = 0L;
        vars.MemoryBossNextScan = 0L;

        if (hadState)
        {
            ((Action<string>)vars.Log)("memory cache invalidated: " + reason);
        }
    });
}

// LiveSplit 生命周期钩子：update
// 作用：验证当前世界和加载状态，采样玩家和 Boss Actor，并把已配置 Boss 的
// 死亡/移除边沿转换为待处理打点。
// 入参：current/old 状态字典、vars、timer 和已绑定游戏进程。
// 返回：正常路径返回 null。返回 false 会阻止同一轮后续 ASL 钩子，
// 所以本脚本用暂停状态而不是 false 控制流程。
// 原理：每轮先保持暂停，逐项通过加载门控，限制昂贵扫描频率，
// 并且只有先观测到有效存活状态后才武装 Boss。
update
{
    // 失败保持暂停：任何未验证的指针链或可疑世界都继续暂停游戏时间。
    // 前半段负责加载移除，后半段负责玩家解析、Actor 状态和打点队列。
    vars.Paused = true;

    try
    {
        vars.Helper.Update();
        vars.Helper.MapPointers();

        // 每轮只解析一次失效委托。所有加载门控共用该函数，
        // 避免某条返回路径漏清某一类缓存。
        Action<string> invalidateCaches = (Action<string>)vars.InvalidateMemoryBossCaches;

        // 必需的 watcher 值。Loading 为 byte 0 是合法状态，但 watcher 为 null 无效。
        if (current.World == null || (long)current.World == 0
            || current.WorldNameId == null || (int)current.WorldNameId == 0
            || current.Dest == null || (long)current.Dest == 0
            || current.Loading == null) return;

        // DestClass 与 recordClass 必须指向同一世界类型。两者不一致通常意味着
        // 偏移失效、世界尚未构造完成，或当前仍处于菜单。
        long destClass = vars.Helper.Read<long>(0xe08d680);
        long recordClass = vars.Helper.Read<long>(0xdfe9278, 0xc88, 0x80, 0x118, 0x240);
        if (destClass == 0 || recordClass != destClass)
        {
            invalidateCaches("dest-class-validation");
            return;
        }

        // 只有 FName id 变化或缓存名称为空时才解码世界名，
        // 避免每轮 update 都重复读取名称池。
        int nameId = (int)current.WorldNameId;
        if (nameId != (int)vars.LastNameId || string.IsNullOrEmpty((string)vars.WorldName))
        {
            string name = (string)((Func<int, string>)vars.ReadFName)(nameId);
            if (string.IsNullOrEmpty(name) || name == "None") return;
            vars.WorldName = name;
            vars.LastNameId = nameId;
        }

        // 前端、服务器检查和启动菜单世界绝不能扫描 Boss Actor，
        // 也不能留下上一世界的活动缓存。
        string worldName = (string)vars.WorldName;
        bool frontend = worldName == "Untitled"
            || worldName == "ServerCheck"
            || worldName.IndexOf("StartMenu", StringComparison.OrdinalIgnoreCase) >= 0;
        vars.Paused = (byte)current.Loading != 0 || frontend;
        if ((bool)vars.Paused)
        {
            invalidateCaches("loading-or-frontend");
            return;
        }

        // World/Dest 的组合定义缓存代际。地址变化或此前未设置时，
        // 必须清除所有依赖对象地址的缓存。
        long world = (long)current.World;
        long dest = (long)current.Dest;
        if ((long)vars.MemoryBossCacheWorld != world
            || (long)vars.MemoryBossCacheDest != dest
            || (long)vars.MemoryBossCacheWorld == 0
            || (long)vars.MemoryBossCacheDest == 0)
        {
            invalidateCaches("world-or-dest-change");
            vars.MemoryBossCacheWorld = world;
            vars.MemoryBossCacheDest = dest;
        }

        // 计时器 Running 和 Paused 阶段需要正常扫描 Boss；NotRunning 和 Ended
        // 仍以较低频率观测和记录，但还不能真正打点。
        bool bossRunning = timer.CurrentPhase == TimerPhase.Running
            || timer.CurrentPhase == TimerPhase.Paused;
        long nowTicks = DateTime.UtcNow.Ticks;
        // Running/Paused 使用 50 ms，Idle/Ended 使用 100 ms。ASL 宿主仍会更高频
        // 调用 update，这个门控只限制昂贵的内存读取。
        long scanInterval = bossRunning
            ? (long)vars.BossScanIntervalTicks
            : (long)vars.IdleBossScanIntervalTicks;
        if (nowTicks < (long)vars.MemoryBossNextScan)
            return;
        vars.MemoryBossNextScan = nowTicks + scanInterval;

        // 只有通过扫描门控后才解析委托，被跳过的 update 不承担动态类型转换开销。
        Action clearState = (Action)vars.ClearMemoryBossState;
        Func<long, long[]> readMeta = (Func<long, long[]>)vars.ReadObjectMeta;
        Func<long, long[]> readComponents =
            (Func<long, long[]>)vars.ReadCharacterComponents;
        Func<long, string> readClassName =
            (Func<long, string>)vars.ReadObjectClassName;
        Func<long[], Tuple<float, float, bool, int>> readPlayerState = (Func<long[], Tuple<float, float, bool, int>>)vars.ReadMemoryBossPlayerState;
        Func<long, long[]> readActorList = (Func<long, long[]>)vars.ReadMemoryBossActorList;
        Func<long[], Tuple<int, float, float>> readActorState = (Func<long[], Tuple<int, float, float>>)vars.ReadMemoryBossActorState;
        Func<long, long[], bool> actorIdentityMatches = (Func<long, long[], bool>)vars.MemoryBossActorIdentityMatches;

        // 玩家、HatredManager、AttributeSet 和 ASC 指针相对稳定。每两秒重建
        // 完整链路；缓存 Pawn 身份变化或读取失败时立即重建。
        long[] playerRecord = (long[])vars.MemoryBossPlayerRecord;
        bool resolvePlayer = playerRecord == null || playerRecord.Length < 9;
        if (!resolvePlayer)
        {
            long[] playerMeta = readMeta(playerRecord[1]);
            resolvePlayer = playerMeta == null
                || playerMeta[0] != playerRecord[5]
                || playerMeta[1] != playerRecord[6]
                || playerMeta[2] != playerRecord[7]
                || nowTicks >= playerRecord[8] + (long)vars.PlayerReconcileIntervalTicks;
        }

        if (resolvePlayer && !((Func<bool>)vars.ResolveMemoryBossPlayer)())
        {
            clearState();
            vars.MemoryBossPlayerRecord = null;
            return;
        }

        // 玩家状态读取失败可能是缓存子指针被替换。重新解析完整链路后，
        // 只允许重试一次。
        playerRecord = (long[])vars.MemoryBossPlayerRecord;
        Tuple<float, float, bool, int> playerState = readPlayerState(playerRecord);
        if (playerState == null)
        {
            vars.MemoryBossPlayerRecord = null;
            if (!((Func<bool>)vars.ResolveMemoryBossPlayer)())
            {
                clearState();
                return;
            }

            playerRecord = (long[])vars.MemoryBossPlayerRecord;
            playerState = readPlayerState(playerRecord);
            if (playerState == null)
            {
                clearState();
                return;
            }
        }

        // 玩家死亡或生命归零时停止 Boss 处理。清空观测可防止已武装边沿
        // 泄漏到下一次有效扫描。
        bool playerDead = (playerState.Item4 & 1) != 0;
        if (playerDead || playerState.Item1 <= 0.001f)
        {
            clearState();
            return;
        }

        // Hatred 列表头读取失败可能是缓存指针过期。重新解析玩家后再读一次；
        // 第二次仍失败就清空本轮观测。
        long hatredManager = playerRecord[2];
        long[] actorList = readActorList(hatredManager);
        if (actorList == null)
        {
            vars.MemoryBossPlayerRecord = null;
            if (!((Func<bool>)vars.ResolveMemoryBossPlayer)())
            {
                clearState();
                return;
            }

            playerRecord = (long[])vars.MemoryBossPlayerRecord;
            actorList = readActorList(playerRecord[2]);
            if (actorList == null)
            {
                clearState();
                return;
            }
        }
        long actorArray = actorList[0];
        int actorCount = (int)actorList[1];

        byte[] actorData = null;
        if (actorCount > 0)
        {
            // Actor 指针是连续的 64 位值。一次读取整个数组，
            // 让当前扫描基于同一份指针快照。
            actorData = vars.Helper.ReadSpan<byte>(
                actorCount * 8,
                (IntPtr)actorArray);
            if (actorData == null || actorData.Length != actorCount * 8)
            {
                clearState();
                return;
            }
        }

        // 每轮只解析一次集合别名。局部变量可减少 Actor 热循环中的动态转换，
        // 也让状态转换更容易阅读。
        Dictionary<long, string> seen = (Dictionary<long, string>)vars.MemoryBossSeen;
        Dictionary<long, string> unknownSeen =
            (Dictionary<long, string>)vars.MemoryBossUnknownSeen;
        Dictionary<long, long> unknownMissingSince =
            (Dictionary<long, long>)vars.MemoryBossUnknownMissingSince;
        Dictionary<long, string> checks = (Dictionary<long, string>)vars.MemoryBossChecks;
        Dictionary<long, long> checkUntil = (Dictionary<long, long>)vars.MemoryBossCheckUntil;
        HashSet<long> armed = (HashSet<long>)vars.MemoryBossArmed;
        HashSet<string> loggedAppeared = (HashSet<string>)vars.MemoryBossLoggedAppeared;
        Dictionary<long, float> lastHealth = (Dictionary<long, float>)vars.MemoryBossLastHealth;
        Dictionary<long, bool> lastDead = (Dictionary<long, bool>)vars.MemoryBossLastDead;
        Dictionary<long, float> lastHealthRatio =
            (Dictionary<long, float>)vars.MemoryBossLastHealthRatio;
        Dictionary<string, int> healthMilestone = (Dictionary<string, int>)vars.MemoryBossHealthMilestone;
        Dictionary<long, long[]> actorCache = (Dictionary<long, long[]>)vars.MemoryBossActorCache;
        Action<long> forgetActor = (Action<long>)vars.ForgetMemoryBossActor;
        Action<long> forgetActorCache = (Action<long>)vars.ForgetMemoryBossActorCache;
        Action<long> forgetActorSamples = (Action<long>)vars.ForgetMemoryBossActorSamples;
        HashSet<long> currentActors = new HashSet<long>();

        // actorCache 字段布局：
        // [0] UClass 指针，[1] 对象 FName id，[2] InternalIndex，
        // [3] AttributeSetBase，[4] AbilitySystemComponent，[5] 刷新时间。
        // seen 记录当前仇恨列表中的已配置 Actor。
        // checks 记录进入六十秒移除宽限期的 Actor。
        // armed 证明该地址此前产生过有效的存活样本。

        // 处理仇恨列表中的每个 Actor。每轮都读取对象元数据；
        // 类名和组件指针使用当前世界代际内的缓存。
        for (int i = 0; i < actorCount; i++)
        {
            long actor = BitConverter.ToInt64(actorData, i * 8);
            if (actor == 0) continue;

            long[] meta = readMeta(actor);
            if (meta == null) continue;

            string className = readClassName(meta[0]);
            string setting = ((Func<string, string>)vars.GetBossSetting)(className);
            if (string.IsNullOrEmpty(setting))
            {
                // 未配置候选只检查类身份，不读取组件、Tag 和生命值。
                // 这些 Actor 不能打点，读取只会增加热路径负担。
                if (string.IsNullOrEmpty(className)
                    || !className.EndsWith("_C", StringComparison.Ordinal)) continue;

                currentActors.Add(actor);
                unknownMissingSince.Remove(actor);
                if (!unknownSeen.ContainsKey(actor))
                {
                    // 分配器可能复用该地址。记录新候选前，先清除同一地址上
                    // 可能残留的已配置 Boss 跟踪状态。
                    forgetActor(actor);
                    forgetActorCache(actor);
                    forgetActorSamples(actor);
                    ((Action<string>)vars.Log)(
                        "unconfigured boss appeared: class=" + className
                        + " actor=0x" + actor.ToString("X")
                        + " world=" + (string)vars.WorldName
                        + " phase=" + timer.CurrentPhase.ToString());
                }
                unknownSeen[actor] = className;
                continue;
            }
            // 单项 Boss 关闭后完全跳过检测和日志。
            // settings[setting] 还会递归应用所有父分组开关。
            if (!(bool)settings[setting]) continue;

            long[] record;
            // 只有完整对象身份匹配时才能复用组件缓存；
            // 同一地址但身份不同时必须重新读取。
            if (!actorCache.TryGetValue(actor, out record)
                || record == null
                || record.Length < 6
                || record[0] != meta[0]
                || record[1] != meta[1]
                || record[2] != meta[2])
            {
                long[] components = readComponents(actor);
                if (components == null
                    || components[0] <= 0
                    || components[1] <= 0)
                {
                    forgetActorCache(actor);
                    continue;
                }

                record = new long[]
                {
                    meta[0], meta[1], meta[2],
                    components[1], components[0], nowTicks
                };
                actorCache[actor] = record;
            }
            else if (nowTicks >= record[5] + (long)vars.PlayerReconcileIntervalTicks)
            {
                long[] components = readComponents(actor);
                if (components == null
                    || components[0] <= 0
                    || components[1] <= 0)
                {
                    forgetActorCache(actor);
                    continue;
                }
                record[3] = components[1];
                record[4] = components[0];
                record[5] = nowTicks;
            }

            // 对象局部重建后组件指针可能过期。读取失败时，
            // 只有观察到组件指针确实变化才重试。
            Tuple<int, float, float> actorState = readActorState(record);
            if (actorState == null)
            {
                long[] refreshed = readComponents(actor);
                if (refreshed != null
                    && refreshed[0] > 0
                    && refreshed[1] > 0
                    && (refreshed[0] != record[4] || refreshed[1] != record[3]))
                {
                    record[3] = refreshed[1];
                    record[4] = refreshed[0];
                    record[5] = nowTicks;
                    actorState = readActorState(record);
                }
            }

            if (actorState == null)
            {
                forgetActorCache(actor);
                continue;
            }

            currentActors.Add(actor);
            int tagFlags = actorState.Item1;
            // ExcludeFromBossRecord 优先于 Dead。清除全部打点状态，
            // 但保留组件指针，以便该 Actor 以后重新纳入时复用。
            if ((tagFlags & 2) != 0)
            {
                // Exclude 只清除打点状态，保留组件缓存，避免重新纳入时再次解析。
                forgetActor(actor);
                forgetActorSamples(actor);
                continue;
            }

            bool dead = (tagFlags & 1) != 0;
            float health = actorState.Item2;
            float maxHealth = actorState.Item3;
            lastHealth[actor] = health;
            lastDead[actor] = dead;
            if (maxHealth > 0.001f)
            {
                lastHealthRatio[actor] = health / maxHealth;
            }

            // 只有有效且未死亡的观测才会武装 Actor。日志和血量里程碑
            // 只用于诊断，不改变打点决策。
            if (!dead && health > 0.001f)
            {
                armed.Add(actor);
                if (loggedAppeared.Add(setting))
                {
                    ((Action<string>)vars.Log)(
                        "boss appeared: setting=" + setting
                        + " class=" + className
                        + " actor=0x" + actor.ToString("X")
                        + " world=" + (string)vars.WorldName
                        + " health=" + health.ToString("0.##")
                        + "/" + maxHealth.ToString("0.##")
                        + " phase=" + timer.CurrentPhase.ToString());
                }

                if (maxHealth > 0.001f)
                {
                    float ratio = health / maxHealth;
                    int milestone = 100;
                    if (ratio <= 0.10f) milestone = 10;
                    else if (ratio <= 0.25f) milestone = 25;
                    else if (ratio <= 0.50f) milestone = 50;
                    else if (ratio <= 0.75f) milestone = 75;

                    int previousMilestone;
                    if (healthMilestone.TryGetValue(setting, out previousMilestone)
                        && milestone < previousMilestone)
                    {
                        ((Action<string>)vars.Log)(
                            "boss health: setting=" + setting
                            + " health=" + health.ToString("0.##")
                            + "/" + maxHealth.ToString("0.##")
                            + " percent=" + (ratio * 100.0f).ToString("0.#")
                            + " milestone=" + milestone + "%");
                    }
                    if (!healthMilestone.ContainsKey(setting)
                        || milestone < healthMilestone[setting])
                    {
                        healthMilestone[setting] = milestone;
                    }
                }
            }

            // 死亡边沿要求此前存在存活观测。Dead Tag 和零生命值都可作为证据；
            // 两者同时存在时优先记录 Dead Tag。
            if (bossRunning && armed.Contains(actor) && (dead || health <= 0.001f))
            {
                string reason = dead ? "dead-tag" : "zero-health";
                ((Action<string, string>)vars.QueueMemoryBoss)(
                    setting,
                    reason + ",health=" + health.ToString("0.##"));
                forgetActor(actor);
                forgetActorCache(actor);
                continue;
            }

            seen[actor] = setting;
            checks.Remove(actor);
            checkUntil.Remove(actor);
        }

        // 未配置 Boss 不进入打点状态机，只跟踪出现和稳定缺失。
        // 连续缺失两秒后才记录死亡/移除，避免单次读取失败产生误导日志。
        List<long> unknownActors = new List<long>((IEnumerable<long>)unknownSeen.Keys);
        foreach (long actor in unknownActors)
        {
            if (currentActors.Contains(actor))
            {
                unknownMissingSince.Remove(actor);
                continue;
            }

            long missingSince;
            if (!unknownMissingSince.TryGetValue(actor, out missingSince))
            {
                unknownMissingSince[actor] = nowTicks;
                continue;
            }
            if (nowTicks < missingSince + (long)vars.PlayerReconcileIntervalTicks)
                continue;

            string className = unknownSeen[actor];
            ((Action<string>)vars.Log)(
                "unconfigured boss died/removed: class=" + className
                + " actor=0x" + actor.ToString("X")
                + " world=" + (string)vars.WorldName
                + " phase=" + timer.CurrentPhase.ToString());
            unknownSeen.Remove(actor);
            unknownMissingSince.Remove(actor);
        }

        // 已配置 Actor 离开 BeHatredList 时先校验身份。阶段切换会更换类名和
        // 设置 ID，因此旧 Actor 的移除是该阶段的有效结束边沿；若当前或最近
        // 一次有效生命值比例已进入低血线，就在同一轮 update 中立即打点。
        List<long> seenActors = new List<long>((IEnumerable<long>)seen.Keys);
        foreach (long actor in seenActors)
        {
            if (currentActors.Contains(actor)) continue;

            string setting = seen[actor];
            seen.Remove(actor);

            // 移除时重新读取对象元数据。Actor 已不在当前列表中，
            // 这是判断原对象是否仍然存在的唯一剩余证据。
            long[] record;
            bool identityValid = actorCache.TryGetValue(actor, out record)
                && actorIdentityMatches(actor, record);
            if (!identityValid)
            {
                forgetActor(actor);
                forgetActorCache(actor);
                if (bossRunning)
                {
                    float previousHealth;
                    lastHealth.TryGetValue(actor, out previousHealth);
                    bool previousDead;
                    lastDead.TryGetValue(actor, out previousDead);
                    ((Action<string, string>)vars.QueueMemoryBoss)(
                        setting,
                        "actor-invalid-on-removal,last-health=" + previousHealth.ToString("0.##")
                        + ",last-dead=" + previousDead);
                }
                continue;
            }

            Tuple<int, float, float> removalState = readActorState(record);
            bool removalStateValid = removalState != null;
            bool removalDead = removalStateValid && (removalState.Item1 & 1) != 0;
            float removalHealth = 0.0f;
            float removalMaxHealth = 0.0f;
            float removalRatio = 1.0f;
            if (removalStateValid)
            {
                removalHealth = removalState.Item2;
                removalMaxHealth = removalState.Item3;
                lastHealth[actor] = removalHealth;
                lastDead[actor] = removalDead;
                if (removalMaxHealth > 0.001f)
                {
                    removalRatio = removalHealth / removalMaxHealth;
                    lastHealthRatio[actor] = removalRatio;
                }
            }
            else
            {
                lastHealth.TryGetValue(actor, out removalHealth);
                float cachedRatio;
                if (lastHealthRatio.TryGetValue(actor, out cachedRatio))
                {
                    removalRatio = cachedRatio;
                }
            }

            bool lowHealthRemoval = removalRatio <= (float)vars.BossLowHealthRemovalRatio;
            if (bossRunning && armed.Contains(actor)
                && (removalDead
                    || (removalStateValid && removalHealth <= 0.001f)
                    || lowHealthRemoval))
            {
                string reason;
                if (removalDead)
                {
                    reason = "dead-tag-on-removal,health=" + removalHealth.ToString("0.##");
                }
                else if (removalStateValid && removalHealth <= 0.001f)
                {
                    reason = "zero-health-on-removal,health=" + removalHealth.ToString("0.##");
                }
                else
                {
                    reason = "low-health-removal,health=" + removalHealth.ToString("0.##")
                        + ",percent=" + (removalRatio * 100.0f).ToString("0.###");
                }

                ((Action<string, string>)vars.QueueMemoryBoss)(setting, reason);
                forgetActor(actor);
                forgetActorCache(actor);
                continue;
            }

            checks[actor] = setting;
            checkUntil[actor] = nowTicks + (long)vars.BossRemovalGraceTicks;
        }

        // 宽限期内继续用缓存的子组件读取 Dead 和生命值，
        // 覆盖两次扫描之间发生的死亡和销毁；到期仍无死亡证据则清理且不打点。
        List<long> checkActors = new List<long>((IEnumerable<long>)checks.Keys);
        foreach (long actor in checkActors)
        {
            string setting = checks[actor];
            long[] record;
            bool identityValid = actorCache.TryGetValue(actor, out record)
                && actorIdentityMatches(actor, record);
            if (!identityValid)
            {
                forgetActor(actor);
                forgetActorCache(actor);
                if (bossRunning)
                {
                    float previousHealth;
                    lastHealth.TryGetValue(actor, out previousHealth);
                    ((Action<string, string>)vars.QueueMemoryBoss)(
                        setting,
                        "actor-invalid-during-grace,last-health=" + previousHealth.ToString("0.##"));
                }
                continue;
            }

            Tuple<int, float, float> actorState = readActorState(record);
            bool stateValid = actorState != null;
            bool dead = stateValid && (actorState.Item1 & 1) != 0;
            float health = 0.0f;
            float maxHealth = 0.0f;
            if (stateValid)
            {
                health = actorState.Item2;
                maxHealth = actorState.Item3;
                lastHealth[actor] = health;
                lastDead[actor] = dead;
                if (maxHealth > 0.001f)
                {
                    lastHealthRatio[actor] = health / maxHealth;
                }
            }

            if (bossRunning && armed.Contains(actor)
                && stateValid && (dead || health <= 0.001f))
            {
                string reason = dead ? "dead-tag-after-list-removal" : "zero-health-after-list-removal";
                ((Action<string, string>)vars.QueueMemoryBoss)(
                    setting,
                    reason + ",health=" + health.ToString("0.##"));
                forgetActor(actor);
                forgetActorCache(actor);
                continue;
            }

            long until;
            if (!checkUntil.TryGetValue(actor, out until) || nowTicks >= until)
            {
                ((Action<string>)vars.Log)(
                    "boss removal not confirmed: setting=" + setting
                    + " actor=0x" + actor.ToString("X")
                    + " class=" + readClassName(record[0])
                    + " health=" + health.ToString("0.##")
                    + "/" + maxHealth.ToString("0.##")
                    + " dead-tag=" + dead
                    + " world=" + (string)vars.WorldName
                    + " phase=" + timer.CurrentPhase.ToString());
                forgetActor(actor);
                forgetActorCache(actor);
            }
        }

        // 最终缓存清扫。既不在当前列表，也不在移除宽限期的地址，
        // 不再保留组件缓存和最近样本。
        List<long> cachedActors = new List<long>((IEnumerable<long>)actorCache.Keys);
        foreach (long actor in cachedActors)
        {
            if (!currentActors.Contains(actor) && !checks.ContainsKey(actor))
            {
                forgetActorCache(actor);
                forgetActorSamples(actor);
            }
        }
    }
    catch {}
}

// LiveSplit 生命周期钩子：start
// 作用：从开始菜单进入已知起始世界时自动启动计时器。
// 入参：current/old 状态字典和 vars。
// 返回：上一世界为开始菜单，且当前世界为竹林谷屋或西谷时返回 true。
// 原理：直接比较前后 WorldNameId 解码出的世界名；old 值由 LiveSplit
// 在 update 前的 ASL 状态快照提供。
start
{
    if (old.WorldNameId == null || current.WorldNameId == null) return false;

    string previousWorld = (string)((Func<int, string>)vars.ReadFName)((int)old.WorldNameId);
    string currentWorld = (string)((Func<int, string>)vars.ReadFName)((int)current.WorldNameId);

    return previousWorld == "PBZ_StartMenu_CE_WP"
        && (currentWorld == "PBZ_WP_ZhuLinGuWu" || currentWorld == "PBZ_Xigu_WP");
}

// LiveSplit 生命周期钩子：isLoading
// 作用：把脚本的失败保持暂停状态转换为 LiveSplit 游戏时间暂停状态。
// 入参：vars.Paused。
// 返回：加载中、前端世界或校验失败时返回 true。
// 原理：LiveSplit 只在 Running/Paused 阶段调用该钩子；本脚本不会通过它
// 直接控制计时器。
isLoading
{
    return (bool)vars.Paused;
}

// LiveSplit 生命周期钩子：split
// 作用：消费一个已配置 Boss 队列事件并请求打点。
// 入参：vars.Paused、AutoSplitEnabled、Pending、settings 和计时器阶段。
// 返回：找到一个启用设置时返回一次 true，否则 false。
// 原理：加载暂停或不在 Running 时绝不打点；总开关生产端和消费端都检查。
split
{
    if ((bool)vars.Paused) return false;
    if (!((Func<bool>)vars.IsAutoSplitEnabled)())
    {
        ((Queue<string>)vars.MemoryBossPending).Clear();
        return false;
    }
    if (timer.CurrentPhase != TimerPhase.Running) return false;

    Queue<string> pending = (Queue<string>)vars.MemoryBossPending;
    while (pending.Count > 0)
    {
        string setting = pending.Dequeue();
        if (settings.ContainsKey(setting) && (bool)settings[setting])
        {
            ((Action<string>)vars.Log)("boss split: setting=" + setting);
            return true;
        }
    }
    return false;
}

// LiveSplit 生命周期钩子：onStart
// 作用：计时器首次进入 Running 时开始新的 Boss 会话。
// 入参：无。
// 返回：null。
// 原理：清空待处理、已消费和日志状态，并让下一次 Boss 扫描立即运行；
// 该钩子在 TimerModel.Start 改变阶段之后执行。
onStart
{
    ((Action<bool>)vars.ResetMemoryBossSession)(true);
}

// LiveSplit 生命周期钩子：onReset
// 作用：真正重置计时器后丢弃当前尝试的全部 Boss 观测。
// 入参：无。
// 返回：null。
// 原理：与 onStart 共用重置路径，确保新尝试不会继承待处理打点、
// 已武装 Actor、已消费设置或里程碑日志。
onReset
{
    ((Action<bool>)vars.ResetMemoryBossSession)(true);
}

// LiveSplit 生命周期钩子：exit
// 作用：PBZ 退出时停止游戏时间统计并丢弃会话状态。
// 入参：无。
// 返回：null。
// 原理：该钩子在 LiveSplit 清除断开进程并重新寻找进程前运行一次；
// 此路径有意不重置 NextScan。
exit
{
    vars.Paused = true;
    timer.IsGameTimePaused = true;
    ((Action<bool>)vars.ResetMemoryBossSession)(false);
}

// LiveSplit 生命周期钩子：shutdown
// 作用：ASL 卸载或重载时释放会话引用。
// 入参：无。
// 返回：null。
// 原理：asl-help 在 startup 时会把自身 Dispose 调用插到该钩子前面；
// 函数体保持防御性，避免 LiveSplit 关闭时暴露清理异常。
shutdown
{
    try
    {
        // 用全新队列和集合避免临时编译脚本被丢弃时继续引用 Actor 或设置对象。
        ((Action<bool>)vars.ResetMemoryBossSession)(false);
    }
    catch {}
}
