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
    // PBZ starts a tiny bootstrap process with the same name. Bind to the
    // full game module so the static offsets are always module-relative.
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
    vars.MemoryBossUpdateCount = 0L;
    vars.MemoryBossScanCount = 0L;
    vars.MemoryBossSkippedScanCount = 0L;

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

    // UClass names are immutable for the life of a world. Cache by class
    // pointer, never by Actor pointer, so actor destruction cannot leave a
    // reusable object class behind.
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

    // One 0x20-byte read supplies the class pointer, object name id and
    // internal index. The tuple is the freshness key for cached child
    // pointers; address reuse with a different object must miss this key.
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

    // APBZCharacter: +0x750 AbilitySystemComponent, +0x758 AttributeSetBase.
    // These are adjacent, so a newly seen actor resolves both in one read.
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

    // UPBZAbilitySystemComponent.GameplayTagCountContainer is at +0xF48.
    // FGameplayTagCountItem is 0x10 bytes (Tag +0x00, Count +0x08).
    // Read the TArray once and resolve both Dead and ExcludeFromBossRecord
    // locally. Return -1 on a partial/invalid read so callers fail closed.
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

    vars.GetBossSetting = (Func<string, string>)(className =>
    {
        if (string.IsNullOrEmpty(className)
            || !className.EndsWith("_C", StringComparison.Ordinal)) return null;

        string bossName = className.Substring(0, className.Length - 2);
        string setting = "Boss_" + bossName;
        return settings.ContainsKey(setting) ? setting : null;
    });

    vars.ResolveMemoryBossPlayer = (Func<bool>)(() =>
    {
        try
        {
            // Fixed player path:
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
        ((Dictionary<long, float>)vars.MemoryBossLastMaxHealth).Clear();
        ((Dictionary<long, bool>)vars.MemoryBossLastDead).Clear();
    });

    vars.MemoryBossPending = new Queue<string>();
    vars.MemoryBossConsumed = new HashSet<string>();
    vars.MemoryBossSeen = new Dictionary<long, string>();
    vars.MemoryBossChecks = new Dictionary<long, string>();
    vars.MemoryBossCheckUntil = new Dictionary<long, long>();
    vars.MemoryBossArmed = new HashSet<long>();
    vars.MemoryBossLoggedAppeared = new HashSet<string>();
    vars.MemoryBossLastHealth = new Dictionary<long, float>();
    vars.MemoryBossLastMaxHealth = new Dictionary<long, float>();
    vars.MemoryBossLastDead = new Dictionary<long, bool>();
    vars.MemoryBossHealthMilestone = new Dictionary<string, int>();
    vars.MemoryBossWorld = 0L;

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

    // World or Dest changes invalidate every object/class/component address.
    // Actor caches are keyed only to the current world generation.
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
        vars.MemoryBossWorld = 0L;
        vars.MemoryBossNextScan = 0L;

        if (hadState)
        {
            ((Action<string>)vars.Log)("memory cache invalidated: " + reason);
        }
    });
}

update
{
    // Fail closed: pause until every pointer, loading flag and world name validates.
    vars.Paused = true;
    vars.MemoryBossUpdateCount = (long)vars.MemoryBossUpdateCount + 1;

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
        if (destClass == 0 || recordClass != destClass)
        {
            ((Action<string>)vars.InvalidateMemoryBossCaches)("dest-class-validation");
            return;
        }

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
        if ((bool)vars.Paused)
        {
            ((Action<string>)vars.InvalidateMemoryBossCaches)("loading-or-frontend");
            return;
        }

        long world = (long)current.World;
        long dest = (long)current.Dest;
        if ((long)vars.MemoryBossCacheWorld != world
            || (long)vars.MemoryBossCacheDest != dest
            || (long)vars.MemoryBossCacheWorld == 0
            || (long)vars.MemoryBossCacheDest == 0)
        {
            ((Action<string>)vars.InvalidateMemoryBossCaches)("world-or-dest-change");
            vars.MemoryBossCacheWorld = world;
            vars.MemoryBossCacheDest = dest;
            vars.MemoryBossWorld = world;
        }

        bool bossRunning = timer.CurrentPhase == TimerPhase.Running
            || timer.CurrentPhase == TimerPhase.Paused;
        long nowTicks = DateTime.UtcNow.Ticks;
        // Running/Paused scans every 50 ms. If death and destruction happen
        // between scans, the next scan still observes removal and queues the
        // split after identity validation. Idle scans every 100 ms because
        // no split can be emitted while the timer is not running.
        long scanInterval = bossRunning
            ? (long)vars.BossScanIntervalTicks
            : (long)vars.IdleBossScanIntervalTicks;
        if (nowTicks < (long)vars.MemoryBossNextScan)
        {
            vars.MemoryBossSkippedScanCount = (long)vars.MemoryBossSkippedScanCount + 1;
            return;
        }
        vars.MemoryBossNextScan = nowTicks + scanInterval;
        vars.MemoryBossScanCount = (long)vars.MemoryBossScanCount + 1;

        // Player, HatredManager, AttributeSet and ASC are low-frequency
        // pointers. Reconcile the full fixed path every two seconds, or
        // immediately when the cached pawn identity/read fails.
        long[] playerRecord = (long[])vars.MemoryBossPlayerRecord;
        bool resolvePlayer = playerRecord == null || playerRecord.Length < 9;
        if (!resolvePlayer)
        {
            long[] playerMeta =
                ((Func<long, long[]>)vars.ReadObjectMeta)(playerRecord[1]);
            resolvePlayer = playerMeta == null
                || playerMeta[0] != playerRecord[5]
                || playerMeta[1] != playerRecord[6]
                || playerMeta[2] != playerRecord[7]
                || nowTicks >= playerRecord[8] + (long)vars.PlayerReconcileIntervalTicks;
        }

        if (resolvePlayer && !((Func<bool>)vars.ResolveMemoryBossPlayer)())
        {
            ((Action)vars.ClearMemoryBossState)();
            vars.MemoryBossPlayerRecord = null;
            return;
        }

        playerRecord = (long[])vars.MemoryBossPlayerRecord;
        Tuple<float, float, bool> playerHealth =
            ((Func<long, Tuple<float, float, bool>>)vars.ReadHealthPair)(playerRecord[3]);
        int playerTagFlags =
            ((Func<long, int>)vars.ReadTagFlags)(playerRecord[4]);
        if (playerHealth == null || !playerHealth.Item3 || playerTagFlags < 0)
        {
            vars.MemoryBossPlayerRecord = null;
            if (!((Func<bool>)vars.ResolveMemoryBossPlayer)())
            {
                ((Action)vars.ClearMemoryBossState)();
                return;
            }

            playerRecord = (long[])vars.MemoryBossPlayerRecord;
            playerHealth =
                ((Func<long, Tuple<float, float, bool>>)vars.ReadHealthPair)(playerRecord[3]);
            playerTagFlags =
                ((Func<long, int>)vars.ReadTagFlags)(playerRecord[4]);
            if (playerHealth == null || !playerHealth.Item3 || playerTagFlags < 0)
            {
                ((Action)vars.ClearMemoryBossState)();
                return;
            }
        }

        bool playerDead = (playerTagFlags & 1) != 0;
        if (playerDead || playerHealth.Item1 <= 0.001f)
        {
            ((Action)vars.ClearMemoryBossState)();
            return;
        }

        long hatredManager = playerRecord[2];
        byte[] actorListHeader = vars.Helper.ReadSpan<byte>(
            0x10,
            (IntPtr)(hatredManager + 0xd8));
        bool actorListValid = actorListHeader != null && actorListHeader.Length == 0x10;
        long actorArray = actorListValid ? BitConverter.ToInt64(actorListHeader, 0x00) : 0;
        int actorCount = actorListValid ? BitConverter.ToInt32(actorListHeader, 0x08) : -1;
        if (actorCount < 0 || actorCount > 128
            || (actorCount > 0 && actorArray == 0))
        {
            vars.MemoryBossPlayerRecord = null;
            if (!((Func<bool>)vars.ResolveMemoryBossPlayer)())
            {
                ((Action)vars.ClearMemoryBossState)();
                return;
            }

            playerRecord = (long[])vars.MemoryBossPlayerRecord;
            hatredManager = playerRecord[2];
            actorListHeader = vars.Helper.ReadSpan<byte>(
                0x10,
                (IntPtr)(hatredManager + 0xd8));
            actorListValid = actorListHeader != null && actorListHeader.Length == 0x10;
            actorArray = actorListValid ? BitConverter.ToInt64(actorListHeader, 0x00) : 0;
            actorCount = actorListValid ? BitConverter.ToInt32(actorListHeader, 0x08) : -1;
            if (actorCount < 0 || actorCount > 128
                || (actorCount > 0 && actorArray == 0))
            {
                ((Action)vars.ClearMemoryBossState)();
                return;
            }
        }

        byte[] actorData = null;
        if (actorCount > 0)
        {
            actorData = vars.Helper.ReadSpan<byte>(
                actorCount * 8,
                (IntPtr)actorArray);
            if (actorData == null || actorData.Length != actorCount * 8)
            {
                ((Action)vars.ClearMemoryBossState)();
                return;
            }
        }

        Dictionary<long, string> seen = (Dictionary<long, string>)vars.MemoryBossSeen;
        Dictionary<long, string> checks = (Dictionary<long, string>)vars.MemoryBossChecks;
        Dictionary<long, long> checkUntil = (Dictionary<long, long>)vars.MemoryBossCheckUntil;
        HashSet<long> armed = (HashSet<long>)vars.MemoryBossArmed;
        HashSet<string> loggedAppeared = (HashSet<string>)vars.MemoryBossLoggedAppeared;
        Dictionary<long, float> lastHealth = (Dictionary<long, float>)vars.MemoryBossLastHealth;
        Dictionary<long, float> lastMaxHealth = (Dictionary<long, float>)vars.MemoryBossLastMaxHealth;
        Dictionary<long, bool> lastDead = (Dictionary<long, bool>)vars.MemoryBossLastDead;
        Dictionary<string, int> healthMilestone = (Dictionary<string, int>)vars.MemoryBossHealthMilestone;
        Dictionary<long, long[]> actorCache = (Dictionary<long, long[]>)vars.MemoryBossActorCache;
        HashSet<long> currentActors = new HashSet<long>();

        for (int i = 0; i < actorCount; i++)
        {
            long actor = BitConverter.ToInt64(actorData, i * 8);
            if (actor == 0) continue;

            long[] meta = ((Func<long, long[]>)vars.ReadObjectMeta)(actor);
            if (meta == null) continue;

            string className =
                ((Func<long, string>)vars.ReadObjectClassName)(meta[0]);
            string setting = ((Func<string, string>)vars.GetBossSetting)(className);
            if (string.IsNullOrEmpty(setting)) continue;
            if (!settings.ContainsKey(setting) || !(bool)settings[setting]) continue;

            long[] record;
            if (!actorCache.TryGetValue(actor, out record)
                || record == null
                || record.Length < 6
                || record[0] != meta[0]
                || record[1] != meta[1]
                || record[2] != meta[2])
            {
                long[] components =
                    ((Func<long, long[]>)vars.ReadCharacterComponents)(actor);
                if (components == null
                    || components[0] <= 0
                    || components[1] <= 0)
                {
                    actorCache.Remove(actor);
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
                long[] components =
                    ((Func<long, long[]>)vars.ReadCharacterComponents)(actor);
                if (components == null
                    || components[0] <= 0
                    || components[1] <= 0)
                {
                    actorCache.Remove(actor);
                    continue;
                }
                record[3] = components[1];
                record[4] = components[0];
                record[5] = nowTicks;
            }

            int tagFlags = ((Func<long, int>)vars.ReadTagFlags)(record[4]);
            Tuple<float, float, bool> healthPair =
                ((Func<long, Tuple<float, float, bool>>)vars.ReadHealthPair)(record[3]);
            if (tagFlags < 0 || healthPair == null || !healthPair.Item3)
            {
                long[] refreshed =
                    ((Func<long, long[]>)vars.ReadCharacterComponents)(actor);
                if (refreshed != null
                    && refreshed[0] > 0
                    && refreshed[1] > 0
                    && (refreshed[0] != record[4] || refreshed[1] != record[3]))
                {
                    record[3] = refreshed[1];
                    record[4] = refreshed[0];
                    record[5] = nowTicks;
                    tagFlags = ((Func<long, int>)vars.ReadTagFlags)(record[4]);
                    healthPair =
                        ((Func<long, Tuple<float, float, bool>>)vars.ReadHealthPair)(record[3]);
                }
            }

            if (tagFlags < 0 || healthPair == null || !healthPair.Item3)
            {
                actorCache.Remove(actor);
                continue;
            }

            currentActors.Add(actor);
            bool excluded = (tagFlags & 2) != 0;
            if (excluded)
            {
                seen.Remove(actor);
                checks.Remove(actor);
                checkUntil.Remove(actor);
                armed.Remove(actor);
                lastHealth.Remove(actor);
                lastMaxHealth.Remove(actor);
                lastDead.Remove(actor);
                continue;
            }

            bool dead = (tagFlags & 1) != 0;
            float health = healthPair.Item1;
            float maxHealth = healthPair.Item2;
            lastHealth[actor] = health;
            lastMaxHealth[actor] = maxHealth;
            lastDead[actor] = dead;

            if (!dead && health > 0.001f)
            {
                armed.Add(actor);
                if (!excluded && loggedAppeared.Add(setting))
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

                if (!excluded && maxHealth > 0.001f)
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

            if (bossRunning && armed.Contains(actor) && (dead || health <= 0.001f))
            {
                string reason = dead ? "dead-tag" : "zero-health";
                ((Action<string, string>)vars.QueueMemoryBoss)(
                    setting,
                    reason + ",health=" + health.ToString("0.##"));
                seen.Remove(actor);
                checks.Remove(actor);
                checkUntil.Remove(actor);
                armed.Remove(actor);
                actorCache.Remove(actor);
                continue;
            }

            seen[actor] = setting;
            checks.Remove(actor);
            checkUntil.Remove(actor);
        }

        List<long> seenActors = new List<long>((IEnumerable<long>)seen.Keys);
        foreach (long actor in seenActors)
        {
            if (currentActors.Contains(actor)) continue;

            string setting = seen[actor];
            seen.Remove(actor);

            long[] record;
            bool identityValid = actorCache.TryGetValue(actor, out record)
                && ((Func<long, long[], bool>)vars.MemoryBossActorIdentityMatches)(actor, record);
            if (!identityValid)
            {
                checks.Remove(actor);
                checkUntil.Remove(actor);
                armed.Remove(actor);
                actorCache.Remove(actor);
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

        List<long> checkActors = new List<long>((IEnumerable<long>)checks.Keys);
        foreach (long actor in checkActors)
        {
            string setting = checks[actor];
            long[] record;
            bool identityValid = actorCache.TryGetValue(actor, out record)
                && ((Func<long, long[], bool>)vars.MemoryBossActorIdentityMatches)(actor, record);
            if (!identityValid)
            {
                checks.Remove(actor);
                checkUntil.Remove(actor);
                armed.Remove(actor);
                actorCache.Remove(actor);
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

            int tagFlags = ((Func<long, int>)vars.ReadTagFlags)(record[4]);
            Tuple<float, float, bool> healthPair =
                ((Func<long, Tuple<float, float, bool>>)vars.ReadHealthPair)(record[3]);
            bool dead = tagFlags >= 0 && (tagFlags & 1) != 0;
            float health = 0.0f;
            float maxHealth = 0.0f;
            bool stateValid = tagFlags >= 0 && healthPair != null && healthPair.Item3;
            if (stateValid)
            {
                health = healthPair.Item1;
                maxHealth = healthPair.Item2;
                lastHealth[actor] = health;
                lastMaxHealth[actor] = maxHealth;
                lastDead[actor] = dead;
            }

            if (bossRunning && armed.Contains(actor)
                && stateValid && (dead || health <= 0.001f))
            {
                string reason = dead ? "dead-tag-after-list-removal" : "zero-health-after-list-removal";
                ((Action<string, string>)vars.QueueMemoryBoss)(
                    setting,
                    reason + ",health=" + health.ToString("0.##"));
                checks.Remove(actor);
                checkUntil.Remove(actor);
                armed.Remove(actor);
                actorCache.Remove(actor);
                continue;
            }

            long until;
            if (!checkUntil.TryGetValue(actor, out until) || nowTicks >= until)
            {
                ((Action<string>)vars.Log)(
                    "boss removal not confirmed: setting=" + setting
                    + " actor=0x" + actor.ToString("X")
                    + " class=" + ((Func<long, string>)vars.ReadObjectClassName)(record[0])
                    + " health=" + health.ToString("0.##")
                    + "/" + maxHealth.ToString("0.##")
                    + " dead-tag=" + dead
                    + " world=" + (string)vars.WorldName
                    + " phase=" + timer.CurrentPhase.ToString());
                checks.Remove(actor);
                checkUntil.Remove(actor);
                armed.Remove(actor);
                actorCache.Remove(actor);
            }
        }

        // Do not retain child pointers for actors that are neither in the
        // current BeHatredList nor inside the two-second removal grace window.
        List<long> cachedActors = new List<long>((IEnumerable<long>)actorCache.Keys);
        foreach (long actor in cachedActors)
        {
            if (!currentActors.Contains(actor) && !checks.ContainsKey(actor))
            {
                actorCache.Remove(actor);
                lastHealth.Remove(actor);
                lastMaxHealth.Remove(actor);
                lastDead.Remove(actor);
            }
        }
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
    vars.MemoryBossPending = new Queue<string>();
    vars.MemoryBossConsumed = new HashSet<string>();
    vars.MemoryBossLoggedAppeared = new HashSet<string>();
    vars.MemoryBossHealthMilestone = new Dictionary<string, int>();
    vars.MemoryBossNextScan = 0L;
    ((Action)vars.ClearMemoryBossState)();
}

onReset
{
    vars.MemoryBossPending = new Queue<string>();
    vars.MemoryBossConsumed = new HashSet<string>();
    vars.MemoryBossLoggedAppeared = new HashSet<string>();
    vars.MemoryBossHealthMilestone = new Dictionary<string, int>();
    vars.MemoryBossNextScan = 0L;
    ((Action)vars.ClearMemoryBossState)();
}

exit
{
    vars.Paused = true;
    timer.IsGameTimePaused = true;
    vars.MemoryBossPending = new Queue<string>();
    vars.MemoryBossConsumed = new HashSet<string>();
    vars.MemoryBossLoggedAppeared = new HashSet<string>();
    vars.MemoryBossHealthMilestone = new Dictionary<string, int>();
    ((Action)vars.ClearMemoryBossState)();
}

shutdown
{
    try
    {
        vars.MemoryBossPending = new Queue<string>();
        vars.MemoryBossConsumed = new HashSet<string>();
        vars.MemoryBossLoggedAppeared = new HashSet<string>();
        vars.MemoryBossHealthMilestone = new Dictionary<string, int>();
        ((Action)vars.ClearMemoryBossState)();
    }
    catch {}
}
