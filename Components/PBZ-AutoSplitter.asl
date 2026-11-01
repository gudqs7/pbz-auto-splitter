state("PBZ"){}

startup
{
    string componentDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Components");
    Assembly.Load(File.ReadAllBytes(Path.Combine(componentDir, "asl-help"))).CreateInstance("Basic");
    vars.Helper.GameName = "Phantom Blade Zero";

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
        ((Action<string>)vars.Log)("settings loaded: culture=" + culture + " file=" + settingsPath);
    }
    catch (Exception ex)
    {
        ((Action<string>)vars.Log)("settings load failed: " + ex.Message);
    }
}

init
{
    // PBZ 会先启动一个同名引导进程，因此必须绑定完整游戏模块，
    // 保证静态偏移始终相对游戏模块基址计算。
    string expectedBuild = "CL-301524_JKS-17219";
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
                if (size == 0x1ec54000
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

    Process target = ((Func<Process>)vars.FindGame)();
    if (target != null)
    {
        vars.Helper.Game = target;
    }
    else
    {
        ((Action<string>)vars.Log)("build gate: no matching PBZ process");
    }

    // 世界、加载状态和世界名均使用固定模块偏移。
    // 任一读取失败时由 asl-help 将值置零或置空，后续流程保持 fail closed。
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
    vars.Paused = true;

    vars.DeadTagIndex = 0x538d8;
    vars.ExcludeFromBossRecordTagIndex = 0xe23d08;
    vars.BossScanIntervalTicks = TimeSpan.TicksPerMillisecond * 50;
    vars.IdleBossScanIntervalTicks = TimeSpan.TicksPerMillisecond * 100;
    vars.PlayerReconcileIntervalTicks = TimeSpan.TicksPerSecond * 2;

    vars.MemoryBossFNameCache = new Dictionary<int, string>();
    vars.MemoryBossClassCache = new Dictionary<long, string>();
    vars.MemoryBossActorCache = new Dictionary<long, long[]>();
    vars.MemoryBossPlayerRecord = null;
    vars.MemoryBossCacheWorld = 0L;
    vars.MemoryBossCacheDest = 0L;
    vars.MemoryBossNextScan = 0L;

    // 按 nameId 从 UE 的 FName 池解码名称，并缓存结果，
    // 避免相同世界或 UClass 名称反复进行跨进程读取。
    vars.ReadFName = (Func<int, string>)(nameId =>
    {
        if (nameId <= 0) return null;

        Dictionary<int, string> cache = (Dictionary<int, string>)vars.MemoryBossFNameCache;
        string cached;
        if (cache.TryGetValue(nameId, out cached)) return cached;

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
        if (string.IsNullOrEmpty(name) || name == "None") return null;

        cache[nameId] = name;
        return name;
    });

    // UClass 名称在世界生命周期内保持不变。
    // 只按 UClass 指针缓存，绝不按 Actor 指针缓存，
    // 避免 Actor 销毁、地址复用后命中旧对象的类名。
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

    // 一次 0x20 字节读取同时取得 UClass 指针、FName id 和对象内部索引。
    // 这三项共同组成 Actor 身份键；地址被复用但对象不同时，身份键必须失配。
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

    vars.MemoryBossActorIdentityMatches = (Func<long, long[], bool>)((obj, record) =>
    {
        if (record == null || record.Length < 3) return false;
        long[] meta = ((Func<long, long[]>)vars.ReadObjectMeta)(obj);
        return meta != null
            && meta[0] == record[0]
            && meta[1] == record[1]
            && meta[2] == record[2];
    });

    // APBZCharacter: +0x750 为 AbilitySystemComponent，
    // +0x758 为 AttributeSetBase。两者相邻，因此一次读取即可完成组件解析。
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

    // 一次读取生命值和最大生命值；短读、NaN 或 Infinity 均视为无效，
    // 调用方据此 fail closed。
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

    // UPBZAbilitySystemComponent.GameplayTagCountContainer 位于 +0xF48。
    // FGameplayTagCountItem 为 0x10 字节：Tag 在 +0x00，Count 在 +0x08。
    // 一次读取 TArray，在本地同时解析 Dead 和 ExcludeFromBossRecord；
    // 短读或数据异常返回 -1，由调用方 fail closed。
    vars.ReadTagFlags = (Func<long, int>)(abilitySystem =>
    {
        if (abilitySystem <= 0) return -1;

        byte[] header = vars.Helper.ReadSpan<byte>(
            0x10,
            (IntPtr)(abilitySystem + 0xf48));
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

    // 只把以 "_C" 结尾的 UClass 名映射到 Boss 设置，
    // 并确认设置 XML 中确实存在对应的 Boss_* 项目。
    vars.GetBossSetting = (Func<string, string>)(className =>
    {
        if (string.IsNullOrEmpty(className)
            || !className.EndsWith("_C", StringComparison.Ordinal)) return null;

        string bossName = className.Substring(0, className.Length - 2);
        string setting = "Boss_" + bossName;
        return settings.ContainsKey(setting) ? setting : null;
    });

    // 按主 update 路径的原有顺序读取玩家状态：先生命值，后 GameplayTag。
    // 失败返回 null，调用方可以重新解析玩家后只重试一次。
    vars.ReadMemoryBossPlayerState = (Func<long[], Tuple<float, float, bool, int>>)(record =>
    {
        if (record == null || record.Length < 5) return null;
        Tuple<float, float, bool> health =
            ((Func<long, Tuple<float, float, bool>>)vars.ReadHealthPair)(record[3]);
        int tagFlags = ((Func<long, int>)vars.ReadTagFlags)(record[4]);
        if (health == null || !health.Item3 || tagFlags < 0) return null;
        return Tuple.Create(health.Item1, health.Item2, true, tagFlags);
    });

    // BeHatredList 为空时数组指针可能同时清零；
    // 此时 count=0 是合法状态，不能按读取失败处理。
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

    // Actor 的 GameplayTag 和生命值总是一起读取。
    // 任一读取无效时返回 null，让调用方刷新子组件指针后只重试一次。
    vars.ReadMemoryBossActorState = (Func<long[], Tuple<int, float, float>>)(record =>
    {
        if (record == null || record.Length < 5) return null;
        int tagFlags = ((Func<long, int>)vars.ReadTagFlags)(record[4]);
        Tuple<float, float, bool> health =
            ((Func<long, Tuple<float, float, bool>>)vars.ReadHealthPair)(record[3]);
        if (tagFlags < 0 || health == null || !health.Item3) return null;
        return Tuple.Create(tagFlags, health.Item1, health.Item2);
    });

    vars.ResolveMemoryBossPlayer = (Func<bool>)(() =>
    {
        try
        {
            // 固定玩家链路：
            // GEngine -> GameViewportClient -> GameInstance -> LocalPlayers[0]
            // -> LocalPlayer -> PlayerController -> AcknowledgedPawn.
            long controller = vars.Helper.Read<long>(
                0xdf741c8, 0xc88, 0x80, 0x38, 0x0, 0x30);
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

    vars.ClearMemoryBossState = (Action)(() =>
    {
        ((Dictionary<long, string>)vars.MemoryBossSeen).Clear();
        ((Dictionary<long, string>)vars.MemoryBossChecks).Clear();
        ((Dictionary<long, long>)vars.MemoryBossCheckUntil).Clear();
        ((HashSet<long>)vars.MemoryBossArmed).Clear();
        ((Dictionary<long, float>)vars.MemoryBossLastHealth).Clear();
        ((Dictionary<long, bool>)vars.MemoryBossLastDead).Clear();
    });

    // 分帧状态会在 World/Dest 变化时清空；这些状态只对当前世界代际有效。
    vars.MemoryBossPending = new Queue<string>();
    vars.MemoryBossConsumed = new HashSet<string>();
    vars.MemoryBossSeen = new Dictionary<long, string>();
    vars.MemoryBossChecks = new Dictionary<long, string>();
    vars.MemoryBossCheckUntil = new Dictionary<long, long>();
    vars.MemoryBossArmed = new HashSet<long>();
    vars.MemoryBossLoggedAppeared = new HashSet<string>();
    vars.MemoryBossLastHealth = new Dictionary<long, float>();
    vars.MemoryBossLastDead = new Dictionary<long, bool>();
    vars.MemoryBossHealthMilestone = new Dictionary<string, int>();

    // Actor 清理拆成三部分：跟踪状态、组件缓存和最近读取样本。
    // ExcludeFromBossRecord 路径会刻意保留组件缓存。
    vars.ForgetMemoryBossActor = (Action<long>)(actor =>
    {
        ((Dictionary<long, string>)vars.MemoryBossSeen).Remove(actor);
        ((Dictionary<long, string>)vars.MemoryBossChecks).Remove(actor);
        ((Dictionary<long, long>)vars.MemoryBossCheckUntil).Remove(actor);
        ((HashSet<long>)vars.MemoryBossArmed).Remove(actor);
    });

    vars.ForgetMemoryBossActorCache = (Action<long>)(actor =>
    {
        ((Dictionary<long, long[]>)vars.MemoryBossActorCache).Remove(actor);
    });

    vars.ForgetMemoryBossActorSamples = (Action<long>)(actor =>
    {
        ((Dictionary<long, float>)vars.MemoryBossLastHealth).Remove(actor);
        ((Dictionary<long, bool>)vars.MemoryBossLastDead).Remove(actor);
    });

    // 开始、重置、退出和关闭脚本时统一重置会话状态。
    // 退出路径不重置下一扫描时间，保持原先的可观察语义。
    vars.ResetMemoryBossSession = (Action<bool>)(resetNextScan =>
    {
        vars.MemoryBossPending = new Queue<string>();
        vars.MemoryBossConsumed = new HashSet<string>();
        vars.MemoryBossLoggedAppeared = new HashSet<string>();
        vars.MemoryBossHealthMilestone = new Dictionary<string, int>();
        if (resetNextScan) vars.MemoryBossNextScan = 0L;
        ((Action)vars.ClearMemoryBossState)();
    });

    // 同一 Boss 设置在单个计时周期内只入队一次，避免重复打点。
    vars.QueueMemoryBoss = (Action<string, string>)((setting, reason) =>
    {
        if (!string.IsNullOrEmpty(setting))
        {
            HashSet<string> consumed = (HashSet<string>)vars.MemoryBossConsumed;
            if (!consumed.Contains(setting))
            {
                consumed.Add(setting);

                Queue<string> pending = (Queue<string>)vars.MemoryBossPending;
                pending.Enqueue(setting);
                ((Action<string>)vars.Log)(
                    "boss died: setting=" + setting
                    + " reason=" + reason
                    + " world=" + (string)vars.WorldName
                    + " phase=" + timer.CurrentPhase.ToString());
            }
        }
    });

    // World 或 Dest 变化会使对象、UClass 和组件地址全部失效。
    // 所有 Actor 缓存只属于当前世界代际，必须在切换时整体清理。
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

update
{
    // fail closed：默认暂停，只有所有指针、加载标志和世界名都验证通过后才继续。
    vars.Paused = true;

    try
    {
        vars.Helper.Update();
        vars.Helper.MapPointers();

        Action<string> invalidateCaches = (Action<string>)vars.InvalidateMemoryBossCaches;

        if (current.World == null || (long)current.World == 0
            || current.WorldNameId == null || (int)current.WorldNameId == 0
            || current.Dest == null || (long)current.Dest == 0
            || current.Loading == null) return;

        // DestClass 与记录类必须一致，否则立即清空缓存并继续保持暂停。
        long destClass = vars.Helper.Read<long>(0xe021828);
        long recordClass = vars.Helper.Read<long>(0xdf741c8, 0xc88, 0x80, 0x118, 0x240);
        if (destClass == 0 || recordClass != destClass)
        {
            invalidateCaches("dest-class-validation");
            return;
        }

        // 世界名按 nameId 低频刷新；同一世界中无需重复解码 FName。
        int nameId = (int)current.WorldNameId;
        if (nameId != (int)vars.LastNameId || string.IsNullOrEmpty((string)vars.WorldName))
        {
            string name = (string)((Func<int, string>)vars.ReadFName)(nameId);
            if (string.IsNullOrEmpty(name) || name == "None") return;
            vars.WorldName = name;
            vars.LastNameId = nameId;
        }

        // 前端、服务器检查和启动菜单世界不参与 Boss 扫描。
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

        // World/Dest 任一变化都代表进入新的世界代际，必须整体失效缓存。
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

        bool bossRunning = timer.CurrentPhase == TimerPhase.Running
            || timer.CurrentPhase == TimerPhase.Paused;
        long nowTicks = DateTime.UtcNow.Ticks;
        // Running/Paused 每 50 ms 扫描一次；即使死亡和销毁发生在两次扫描之间，
        // 下一次扫描仍会通过移除边沿和身份校验补发打点。
        // Idle 每 100 ms 扫描一次，因为计时器未运行时不会真正触发 split。
        long scanInterval = bossRunning
            ? (long)vars.BossScanIntervalTicks
            : (long)vars.IdleBossScanIntervalTicks;
        if (nowTicks < (long)vars.MemoryBossNextScan)
            return;
        vars.MemoryBossNextScan = nowTicks + scanInterval;

        // 扫描门控通过后才解析委托，跳过扫描的 update 不承担这些转换开销。
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

        // 玩家、HatredManager、AttributeSet 和 ASC 均为低频指针。
        // 每两秒重新解析完整固定链路；缓存 Pawn 身份或读取失败时立即重新解析。
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

        // 玩家状态读取失败时先重新解析完整玩家链路，再仅重试一次。
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

        bool playerDead = (playerState.Item4 & 1) != 0;
        if (playerDead || playerState.Item1 <= 0.001f)
        {
            clearState();
            return;
        }

        // Hatred 列表头读取失败可能只是缓存指针失效；
        // 重新解析玩家后重读一次，仍失败则清空本帧状态。
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
            actorData = vars.Helper.ReadSpan<byte>(
                actorCount * 8,
                (IntPtr)actorArray);
            if (actorData == null || actorData.Length != actorCount * 8)
            {
                clearState();
                return;
            }
        }

        // Actor 级状态：当前列表、移除宽限、武装状态和最近样本。
        Dictionary<long, string> seen = (Dictionary<long, string>)vars.MemoryBossSeen;
        Dictionary<long, string> checks = (Dictionary<long, string>)vars.MemoryBossChecks;
        Dictionary<long, long> checkUntil = (Dictionary<long, long>)vars.MemoryBossCheckUntil;
        HashSet<long> armed = (HashSet<long>)vars.MemoryBossArmed;
        HashSet<string> loggedAppeared = (HashSet<string>)vars.MemoryBossLoggedAppeared;
        Dictionary<long, float> lastHealth = (Dictionary<long, float>)vars.MemoryBossLastHealth;
        Dictionary<long, bool> lastDead = (Dictionary<long, bool>)vars.MemoryBossLastDead;
        Dictionary<string, int> healthMilestone = (Dictionary<string, int>)vars.MemoryBossHealthMilestone;
        Dictionary<long, long[]> actorCache = (Dictionary<long, long[]>)vars.MemoryBossActorCache;
        Action<long> forgetActor = (Action<long>)vars.ForgetMemoryBossActor;
        Action<long> forgetActorCache = (Action<long>)vars.ForgetMemoryBossActorCache;
        Action<long> forgetActorSamples = (Action<long>)vars.ForgetMemoryBossActorSamples;
        HashSet<long> currentActors = new HashSet<long>();

        // 逐个 Actor 读取身份和组件。UClass 名称及子组件指针命中缓存时，
        // 不会在热路径中重复跨进程读取。
        for (int i = 0; i < actorCount; i++)
        {
            long actor = BitConverter.ToInt64(actorData, i * 8);
            if (actor == 0) continue;

            long[] meta = readMeta(actor);
            if (meta == null) continue;

            string className = readClassName(meta[0]);
            string setting = ((Func<string, string>)vars.GetBossSetting)(className);
            if (string.IsNullOrEmpty(setting) || !(bool)settings[setting]) continue;

            long[] record;
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

            // 组件指针可能因对象重建而失效；仅在读取失败且指针确实变化时重试。
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
            // ExcludeFromBossRecord 优先于死亡判断，并清除该 Actor 的所有打点状态。
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

            // 只有先观察到过存活状态才会触发死亡边沿，避免初始即死亡的对象误打点。
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

        // Actor 从 BeHatredList 消失后不立即打点：
        // 先校验身份，确认对象未被销毁或地址复用后，再进入两秒移除宽限。
        List<long> seenActors = new List<long>((IEnumerable<long>)seen.Keys);
        foreach (long actor in seenActors)
        {
            if (currentActors.Contains(actor)) continue;

            string setting = seen[actor];
            seen.Remove(actor);

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

            checks[actor] = setting;
            checkUntil[actor] = nowTicks + TimeSpan.TicksPerSecond * 2;
        }

        // 宽限期内继续观察死亡 Tag 和生命值，
        // 用于捕捉“死亡与销毁发生在同一扫描间隔”的情况。
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

        // 既不在当前 BeHatredList、也不在两秒移除宽限窗口内的 Actor，
        // 不再保留其子组件指针和最近读取样本。
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

start
{
    // 只允许在指定起始世界完成加载的边沿启动计时。
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
    // 只在计时器 Running 阶段消费待处理 Boss，避免暂停或待机时误打点。
    if ((bool)vars.Paused) return false;
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

onStart
{
    // 新计时周期清空 Boss 队列、去重集合和扫描调度。
    ((Action<bool>)vars.ResetMemoryBossSession)(true);
}

onReset
{
    // 重置计时器时回到与 onStart 相同的初始状态。
    ((Action<bool>)vars.ResetMemoryBossSession)(true);
}

exit
{
    // 游戏退出时立即暂停游戏时间并清空会话状态。
    vars.Paused = true;
    timer.IsGameTimePaused = true;
    ((Action<bool>)vars.ResetMemoryBossSession)(false);
}

shutdown
{
    try
    {
        // 脚本关闭时释放全部会话引用；保留异常吞掉逻辑，避免 LiveSplit 退出时报错。
        ((Action<bool>)vars.ResetMemoryBossSession)(false);
    }
    catch {}
}
