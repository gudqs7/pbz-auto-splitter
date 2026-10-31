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

    Process target = ((Func<Process>)vars.FindGame)();
    if (target != null) vars.Helper.Game = target;

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

    vars.ReadObjectClassName = (Func<long, string>)(obj =>
    {
        if (obj == 0) return null;
        long objectClass = vars.Helper.Read<long>((IntPtr)(obj + 0x10));
        if (objectClass == 0) return null;
        int nameId = vars.Helper.Read<int>((IntPtr)(objectClass + 0x18));
        return ((Func<int, string>)vars.ReadFName)(nameId);
    });

    vars.GetBossSetting = (Func<string, string>)(className =>
    {
        if (string.IsNullOrEmpty(className)
            || !className.EndsWith("_C", StringComparison.Ordinal)) return null;

        string bossName = className.Substring(0, className.Length - 2);
        string setting = "Boss_" + bossName;
        return settings.ContainsKey(setting) ? setting : null;
    });

    vars.ReadHealth = (Func<long, float>)(character =>
    {
        if (character == 0) return 0.0f;
        long attributeSet = vars.Helper.Read<long>((IntPtr)(character + 0x758));
        if (attributeSet == 0) return 0.0f;
        return vars.Helper.Read<float>((IntPtr)(attributeSet + 0x64));
    });

    vars.ReadMaxHealth = (Func<long, float>)(character =>
    {
        if (character == 0) return 0.0f;
        long attributeSet = vars.Helper.Read<long>((IntPtr)(character + 0x758));
        if (attributeSet == 0) return 0.0f;
        return vars.Helper.Read<float>((IntPtr)(attributeSet + 0x74));
    });

    // UPBZAbilitySystemComponent stores active gameplay tags at +0xF48.
    // Each TMap entry is 0x14 bytes: FName index at +0, count at +8.
    vars.HasGameplayTag = (Func<long, int, bool>)((character, tagIndex) =>
    {
        try
        {
            if (character == 0) return false;
            long abilitySystem = vars.Helper.Read<long>((IntPtr)(character + 0x750));
            if (abilitySystem == 0) return false;

            long tagContainer = abilitySystem + 0xf48;
            long entries = vars.Helper.Read<long>((IntPtr)tagContainer);
            int entryCount = vars.Helper.Read<int>((IntPtr)(tagContainer + 8));
            if (entries == 0 || entryCount <= 0 || entryCount > 4096) return false;

            for (int i = 0; i < entryCount; i++)
            {
                int entryOffset = i * 0x14;
                long tagValue = vars.Helper.Read<long>((IntPtr)(entries + entryOffset));
                if ((int)(tagValue & 0xffffffffL) != tagIndex) continue;

                int tagCount = vars.Helper.Read<int>((IntPtr)(entries + entryOffset + 8));
                if (tagCount > 0) return true;
            }
        }
        catch {}
        return false;
    });

    vars.IsObjectValid = (Func<long, bool>)(obj =>
    {
        string className = ((Func<long, string>)vars.ReadObjectClassName)(obj);
        return !string.IsNullOrEmpty(className);
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
}

update
{
    // Fail closed: pause until every pointer, loading flag and world name validates.
    vars.Paused = true;

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
        if ((bool)vars.Paused) {
            ((Action)vars.ClearMemoryBossState)();
            vars.MemoryBossWorld = 0L;
            return;
        }

        long world = (long)current.World;
        if ((long)vars.MemoryBossWorld != world)
        {
            ((Action)vars.ClearMemoryBossState)();
            vars.MemoryBossWorld = world;
        }

        // GEngine -> GameViewportClient -> GameInstance -> LocalPlayers[0]
        // -> PlayerController -> AcknowledgedPawn.
        long player = vars.Helper.Read<long>(
            0xdf741c8, 0xc88, 0x80, 0x38, 0x0, 0x30, 0x358);
        if (player == 0)
        {
            ((Action)vars.ClearMemoryBossState)();
            return;
        }

        bool playerDead =
            ((Func<long, int, bool>)vars.HasGameplayTag)(player, 0x538d8);
        float playerHealth = ((Func<long, float>)vars.ReadHealth)(player);
        if (playerDead || playerHealth <= 0.001f)
        {
            ((Action)vars.ClearMemoryBossState)();
            return;
        }

        long hatredManager = vars.Helper.Read<long>((IntPtr)(player + 0xe90));
        if (hatredManager == 0)
        {
            ((Action)vars.ClearMemoryBossState)();
            return;
        }

        long actorArray = vars.Helper.Read<long>((IntPtr)(hatredManager + 0xd8));
        int actorCount = vars.Helper.Read<int>((IntPtr)(hatredManager + 0xe0));
        if (actorCount < 0 || actorCount > 128
            || (actorCount > 0 && actorArray == 0))
        {
            ((Action)vars.ClearMemoryBossState)();
            return;
        }

        bool bossRunning = timer.CurrentPhase == TimerPhase.Running
            || timer.CurrentPhase == TimerPhase.Paused;
        Dictionary<long, string> seen = (Dictionary<long, string>)vars.MemoryBossSeen;
        Dictionary<long, string> checks = (Dictionary<long, string>)vars.MemoryBossChecks;
        Dictionary<long, long> checkUntil = (Dictionary<long, long>)vars.MemoryBossCheckUntil;
        HashSet<long> armed = (HashSet<long>)vars.MemoryBossArmed;
        HashSet<string> loggedAppeared = (HashSet<string>)vars.MemoryBossLoggedAppeared;
        Dictionary<long, float> lastHealth = (Dictionary<long, float>)vars.MemoryBossLastHealth;
        Dictionary<long, float> lastMaxHealth = (Dictionary<long, float>)vars.MemoryBossLastMaxHealth;
        Dictionary<long, bool> lastDead = (Dictionary<long, bool>)vars.MemoryBossLastDead;
        Dictionary<string, int> healthMilestone = (Dictionary<string, int>)vars.MemoryBossHealthMilestone;
        HashSet<long> currentActors = new HashSet<long>();

        for (int i = 0; i < actorCount; i++)
        {
            long actor = vars.Helper.Read<long>((IntPtr)(actorArray + i * 8));
            if (actor == 0) continue;

            string className = ((Func<long, string>)vars.ReadObjectClassName)(actor);
            string setting = ((Func<string, string>)vars.GetBossSetting)(className);
            if (string.IsNullOrEmpty(setting)) continue;
            if (!settings.ContainsKey(setting) || !(bool)settings[setting]) continue;

            bool excluded =
                ((Func<long, int, bool>)vars.HasGameplayTag)(actor, 0xe23d08);
            bool dead = ((Func<long, int, bool>)vars.HasGameplayTag)(actor, 0x538d8);
            float health = ((Func<long, float>)vars.ReadHealth)(actor);
            float maxHealth = ((Func<long, float>)vars.ReadMaxHealth)(actor);
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
                currentActors.Add(actor);
                continue;
            }

            if (excluded) continue;

            currentActors.Add(actor);
            seen[actor] = setting;
            checks.Remove(actor);
            checkUntil.Remove(actor);
        }

        List<long> seenActors = new List<long>((IEnumerable<long>)seen.Keys);
        long nowTicks = DateTime.UtcNow.Ticks;
        foreach (long actor in seenActors)
        {
            if (currentActors.Contains(actor)) continue;

            string setting = seen[actor];
            seen.Remove(actor);

            if (!((Func<long, bool>)vars.IsObjectValid)(actor))
            {
                checks.Remove(actor);
                checkUntil.Remove(actor);
                armed.Remove(actor);
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
            if (!((Func<long, bool>)vars.IsObjectValid)(actor))
            {
                checks.Remove(actor);
                checkUntil.Remove(actor);
                armed.Remove(actor);
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

            bool dead = ((Func<long, int, bool>)vars.HasGameplayTag)(actor, 0x538d8);
            float health = ((Func<long, float>)vars.ReadHealth)(actor);
            float maxHealth = ((Func<long, float>)vars.ReadMaxHealth)(actor);
            lastHealth[actor] = health;
            lastMaxHealth[actor] = maxHealth;
            lastDead[actor] = dead;

            if (bossRunning && armed.Contains(actor) && (dead || health <= 0.001f))
            {
                string reason = dead ? "dead-tag-after-list-removal" : "zero-health-after-list-removal";
                ((Action<string, string>)vars.QueueMemoryBoss)(
                    setting,
                    reason + ",health=" + health.ToString("0.##"));
                checks.Remove(actor);
                checkUntil.Remove(actor);
                armed.Remove(actor);
                continue;
            }

            long until;
            if (!checkUntil.TryGetValue(actor, out until) || nowTicks >= until)
            {
                ((Action<string>)vars.Log)(
                    "boss removal not confirmed: setting=" + setting
                    + " actor=0x" + actor.ToString("X")
                    + " class=" + ((Func<long, string>)vars.ReadObjectClassName)(actor)
                    + " health=" + health.ToString("0.##")
                    + "/" + maxHealth.ToString("0.##")
                    + " dead-tag=" + dead
                    + " world=" + (string)vars.WorldName
                    + " phase=" + timer.CurrentPhase.ToString());
                checks.Remove(actor);
                checkUntil.Remove(actor);
                armed.Remove(actor);
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
    ((Action)vars.ClearMemoryBossState)();
}

onReset
{
    vars.MemoryBossPending = new Queue<string>();
    vars.MemoryBossConsumed = new HashSet<string>();
    vars.MemoryBossLoggedAppeared = new HashSet<string>();
    vars.MemoryBossHealthMilestone = new Dictionary<string, int>();
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
    vars.MemoryBossPending = new Queue<string>();
    vars.MemoryBossConsumed = new HashSet<string>();
    vars.MemoryBossLoggedAppeared = new HashSet<string>();
    vars.MemoryBossHealthMilestone = new Dictionary<string, int>();
    ((Action)vars.ClearMemoryBossState)();
}
