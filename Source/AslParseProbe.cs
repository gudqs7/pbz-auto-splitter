using System;
using System.IO;
using System.Reflection;

internal static class AslParseProbe
{
    /// <summary>
    /// 加载本机 LiveSplit ASL 解析器，并解析传入的每个脚本。
    /// 成功返回 0，ASL 解析失败返回 1，参数错误返回 2。
    /// </summary>
    /// <param name="args">生成后 ASL 文件的绝对路径。</param>
    private static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("No ASL files were supplied.");
            return 2;
        }

        string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
        Environment.CurrentDirectory = baseDirectory;
        Assembly.LoadFrom(Path.Combine(baseDirectory, "LiveSplit.Core.dll"));
        Assembly scriptableAutoSplit = Assembly.LoadFrom(
            Path.Combine(baseDirectory, "Components", "LiveSplit.ScriptableAutoSplit.dll"));
        Type parserType = scriptableAutoSplit.GetType("LiveSplit.ASL.ASLParser", true);
        MethodInfo parseMethod = parserType.GetMethod("Parse");

        foreach (string path in args)
        {
            try
            {
                parseMethod.Invoke(null, new object[] { File.ReadAllText(path) });
                Console.WriteLine("ASL_PARSE_OK " + path);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("ASL_PARSE_FAIL " + path);
                Console.Error.WriteLine(ex);
                return 1;
            }
        }

        return 0;
    }
}
