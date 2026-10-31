using System;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using OodleCleanRoom;

internal static class Probe
{
    private static int Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("usage: Probe <input.oodle> <expected.raw>");
            return 2;
        }

        try
        {
            byte[] compressed = File.ReadAllBytes(args[0]);
            byte[] expected = File.ReadAllBytes(args[1]);
            byte[] actual = MermaidDecoder.Decompress(
                compressed, expected.Length);
            if (args.Length > 2)
            {
                File.WriteAllBytes(args[2], actual);
            }
            Console.WriteLine("input=" + args[0]);
            Console.WriteLine("compressed=" + compressed.Length);
            Console.WriteLine("expected=" + expected.Length);
            Console.WriteLine("expected-sha256=" + Sha256(expected));
            Console.WriteLine("actual-sha256=" + Sha256(actual));
            if (!BytesEqual(actual, expected))
            {
                int difference = FirstDifference(actual, expected);
                Console.Error.WriteLine(
                    "MISMATCH at byte "
                    + difference.ToString(CultureInfo.InvariantCulture));
                return 1;
            }
            Console.WriteLine("MATCH");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.GetType().FullName + ": " + ex.Message);
            Console.Error.WriteLine(ex.StackTrace);
            return 1;
        }
    }

    private static bool BytesEqual(byte[] left, byte[] right)
    {
        if (left.Length != right.Length)
        {
            return false;
        }
        for (int i = 0; i < left.Length; i++)
        {
            if (left[i] != right[i])
            {
                return false;
            }
        }
        return true;
    }

    private static int FirstDifference(byte[] left, byte[] right)
    {
        int count = Math.Min(left.Length, right.Length);
        for (int i = 0; i < count; i++)
        {
            if (left[i] != right[i])
            {
                return i;
            }
        }
        return count;
    }

    private static string Sha256(byte[] data)
    {
        using (SHA256 algorithm = SHA256.Create())
        {
            return BitConverter.ToString(algorithm.ComputeHash(data))
                .Replace("-", "")
                .ToLowerInvariant();
        }
    }
}
