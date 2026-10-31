using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;

internal static class Benchmark
{
    private const int WarmupCount = 12;
    private const int SampleCount = 160;

    private static int Main(string[] args)
    {
        try
        {
            return Run(args);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("benchmark failed: " + ex.GetType().FullName);
            Console.Error.WriteLine(ex.Message);
            Console.Error.WriteLine(ex.StackTrace);
            return 1;
        }
    }

    private static int Run(string[] args)
    {
        string root = args.Length > 0
            ? args[0]
            : Environment.CurrentDirectory;
        string gameExe = args.Length > 1 ? args[1] : FindRunningGame();
        string savePath = args.Length > 2
            ? args[2]
            : PBZ.SaveReader.FindSaveFile(gameExe ?? root);
        string oodlePath = args.Length > 3
            ? args[3]
            : PBZ.SaveReader.FindOodleDll(savePath ?? gameExe ?? root);

        if (string.IsNullOrEmpty(savePath) || !File.Exists(savePath))
        {
            Console.Error.WriteLine("save not found");
            return 2;
        }

        string oldDll = Path.Combine(root, "Components", "PBZBossReader.dll");
        bool externalAvailable = !string.IsNullOrEmpty(oodlePath)
            && File.Exists(oodlePath)
            && File.Exists(oldDll);
        bool gameRunning = Process.GetProcessesByName("PBZ").Length > 0;
        if (!externalAvailable && !gameRunning)
        {
            Console.Error.WriteLine(
                "neither oo2core_* DLL nor PBZ process is available");
            return 3;
        }

        Assembly oldAssembly = null;
        Type oldType = null;
        MethodInfo oldRead = null;
        string externalSnapshot = null;
        if (externalAvailable)
        {
            oldAssembly = Assembly.LoadFrom(oldDll);
            oldType = oldAssembly.GetType("PBZ.BossReader");
            oldRead = oldType.GetMethod(
                "ReadSnapshotText",
                new Type[] { typeof(string), typeof(string) });
            if (oldRead == null)
            {
                Console.Error.WriteLine("old reader API not found");
                return 4;
            }
            externalSnapshot = (string)oldRead.Invoke(
                null, new object[] { savePath, oodlePath });
        }

        string cleanRoomSnapshot = SnapshotWithBackend(
            savePath, "cleanroom", "none");
        string gameSnapshot = gameRunning
            ? SnapshotWithBackend(savePath, "game", null)
            : null;
        Dictionary<string, int> bossCounts = Parse(
            cleanRoomSnapshot ?? externalSnapshot);
        if (gameRunning && externalAvailable
            && !SameCounts(Parse(externalSnapshot), bossCounts))
        {
            Console.Error.WriteLine("clean-room counts differ from oo2core");
            Console.Error.WriteLine(externalSnapshot);
            Console.Error.WriteLine(cleanRoomSnapshot);
            return 6;
        }
        if (gameRunning && !SameCounts(Parse(gameSnapshot), bossCounts))
        {
            Console.Error.WriteLine("game-native counts differ from clean-room");
            Console.Error.WriteLine(gameSnapshot);
            Console.Error.WriteLine(cleanRoomSnapshot);
            return 6;
        }

        for (int i = 0; i < WarmupCount; i++)
        {
            if (externalAvailable)
            {
                oldRead.Invoke(null, new object[] { savePath, oodlePath });
                PBZ.SaveReader.ReadSnapshotText(savePath, oodlePath);
            }
            MeasureCleanRoom(savePath);
            if (gameRunning)
            {
                MeasureGameNative(savePath);
            }
        }

        double[] oldSamples = new double[SampleCount];
        double[] newSamples = new double[SampleCount];
        double[] cleanRoomSamples = new double[SampleCount];
        double[] gameSamples = new double[SampleCount];
        for (int i = 0; i < SampleCount; i++)
        {
            if ((i & 1) == 0)
            {
                if (externalAvailable)
                {
                    oldSamples[i] = MeasureOld(oldRead, savePath, oodlePath);
                    newSamples[i] = MeasureNew(savePath, oodlePath);
                }
                cleanRoomSamples[i] = MeasureCleanRoom(savePath);
                if (gameRunning)
                {
                    gameSamples[i] = MeasureGameNative(savePath);
                }
            }
            else
            {
                if (gameRunning)
                {
                    gameSamples[i] = MeasureGameNative(savePath);
                }
                cleanRoomSamples[i] = MeasureCleanRoom(savePath);
                if (externalAvailable)
                {
                    newSamples[i] = MeasureNew(savePath, oodlePath);
                    oldSamples[i] = MeasureOld(oldRead, savePath, oodlePath);
                }
            }
        }

        Console.WriteLine("save=" + savePath);
        Console.WriteLine(
            "external-oodle="
            + (externalAvailable ? oodlePath : "(not installed / not used)"));
        Console.WriteLine("bosses=" + bossCounts.Count);
        Console.WriteLine("counts-match=True");
        if (externalAvailable)
        {
            Console.WriteLine(
                "old reader v" + GetVersion(oldType)
                + ": " + FormatStats(oldSamples));
            Console.WriteLine(
                "PBZ.SaveReader v" + PBZ.SaveReader.Version
                + " external: " + FormatStats(newSamples));
        }
        Console.WriteLine(
            "PBZ.SaveReader v" + PBZ.SaveReader.Version
            + " C# Mermaid: " + FormatStats(cleanRoomSamples));
        if (gameRunning)
        {
            Console.WriteLine(
                "PBZ.SaveReader v" + PBZ.SaveReader.Version
                + " game-native Oodle"
                + ": " + FormatStats(gameSamples));
        }
        else
        {
            Console.WriteLine("PBZ.SaveReader game-native Oodle: skipped (PBZ not running)");
        }
        Console.WriteLine("samples=" + SampleCount);
        return 0;
    }

    private static string FindRunningGame()
    {
        foreach (Process process in Process.GetProcessesByName("PBZ"))
        {
            try
            {
                if (process.MainModule != null)
                {
                    return process.MainModule.FileName;
                }
            }
            catch
            {
            }
        }
        return null;
    }

    private static string GetVersion(Type type)
    {
        PropertyInfo version = type.GetProperty("Version");
        return version == null
            ? "?"
            : Convert.ToString(version.GetValue(null, null), CultureInfo.InvariantCulture);
    }

    private static Dictionary<string, int> Parse(string snapshot)
    {
        if (snapshot == null || !snapshot.StartsWith("OK\t", StringComparison.Ordinal))
        {
            throw new InvalidDataException(snapshot ?? "(null)");
        }

        Dictionary<string, int> result =
            new Dictionary<string, int>(StringComparer.Ordinal);
        string[] lines = snapshot.Split('\n');
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
            result[line.Substring(0, tab)] = int.Parse(
                line.Substring(tab + 1),
                CultureInfo.InvariantCulture);
        }
        return result;
    }

    private static bool SameCounts(
        Dictionary<string, int> left, Dictionary<string, int> right)
    {
        if (left.Count != right.Count)
        {
            return false;
        }
        foreach (KeyValuePair<string, int> pair in left)
        {
            int value;
            if (!right.TryGetValue(pair.Key, out value) || value != pair.Value)
            {
                return false;
            }
        }
        return true;
    }

    private static double ElapsedMilliseconds(long start)
    {
        return (Stopwatch.GetTimestamp() - start)
            * 1000.0 / Stopwatch.Frequency;
    }

    private static double MeasureOld(
        MethodInfo read, string savePath, string oodlePath)
    {
        long start = Stopwatch.GetTimestamp();
        read.Invoke(null, new object[] { savePath, oodlePath });
        return ElapsedMilliseconds(start);
    }

    private static double MeasureNew(string savePath, string oodlePath)
    {
        long start = Stopwatch.GetTimestamp();
        PBZ.SaveReader.ReadSnapshotText(savePath, oodlePath);
        return ElapsedMilliseconds(start);
    }

    private static double MeasureCleanRoom(string savePath)
    {
        return MeasureWithBackend(savePath, "cleanroom", "none");
    }

    private static double MeasureGameNative(string savePath)
    {
        return MeasureWithBackend(savePath, "game", null);
    }

    private static double MeasureWithBackend(
        string savePath, string backend, string fallback)
    {
        string oldBackend = Environment.GetEnvironmentVariable(
            "PBZ_ODLE_BACKEND");
        string oldFallback = Environment.GetEnvironmentVariable(
            "PBZ_ODLE_FALLBACK");
        try
        {
            Environment.SetEnvironmentVariable("PBZ_ODLE_BACKEND", backend);
            Environment.SetEnvironmentVariable("PBZ_ODLE_FALLBACK", fallback);
            long start = Stopwatch.GetTimestamp();
            PBZ.SaveReader.ReadSnapshotText(savePath);
            return ElapsedMilliseconds(start);
        }
        finally
        {
            Environment.SetEnvironmentVariable("PBZ_ODLE_BACKEND", oldBackend);
            Environment.SetEnvironmentVariable("PBZ_ODLE_FALLBACK", oldFallback);
        }
    }

    private static string SnapshotWithBackend(
        string savePath, string backend, string fallback)
    {
        string oldBackend = Environment.GetEnvironmentVariable(
            "PBZ_ODLE_BACKEND");
        string oldFallback = Environment.GetEnvironmentVariable(
            "PBZ_ODLE_FALLBACK");
        try
        {
            Environment.SetEnvironmentVariable("PBZ_ODLE_BACKEND", backend);
            Environment.SetEnvironmentVariable("PBZ_ODLE_FALLBACK", fallback);
            return PBZ.SaveReader.ReadSnapshotText(savePath);
        }
        finally
        {
            Environment.SetEnvironmentVariable("PBZ_ODLE_BACKEND", oldBackend);
            Environment.SetEnvironmentVariable("PBZ_ODLE_FALLBACK", oldFallback);
        }
    }

    private static string FormatStats(double[] samples)
    {
        double[] sorted = (double[])samples.Clone();
        Array.Sort(sorted);
        double total = 0;
        for (int i = 0; i < samples.Length; i++)
        {
            total += samples[i];
        }
        return "avg=" + total / samples.Length
            + "ms p50=" + Percentile(sorted, 0.50)
            + "ms p95=" + Percentile(sorted, 0.95)
            + "ms max=" + sorted[sorted.Length - 1] + "ms";
    }

    private static string Percentile(double[] sorted, double percentile)
    {
        int index = (int)Math.Ceiling(percentile * sorted.Length) - 1;
        if (index < 0)
        {
            index = 0;
        }
        if (index >= sorted.Length)
        {
            index = sorted.Length - 1;
        }
        return sorted[index].ToString("0.0000", CultureInfo.InvariantCulture);
    }
}
