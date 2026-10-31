using System;
using System.IO;
using OodleCleanRoom;

internal static class FailureProbe
{
    private static int Main(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine(
                "usage: FailureProbe <valid.oodle> <valid.expected>");
            return 2;
        }

        byte[] valid = File.ReadAllBytes(args[0]);
        byte[] expected = File.ReadAllBytes(args[1]);
        try
        {
            byte[] baseline = MermaidDecoder.Decompress(
                valid, expected.Length);
            if (!BytesEqual(baseline, expected))
            {
                throw new Exception("baseline vector does not match");
            }

            ExpectFormatError("truncated input", delegate
            {
                byte[] truncated = new byte[valid.Length - 1];
                Buffer.BlockCopy(valid, 0, truncated, 0, truncated.Length);
                MermaidDecoder.Decompress(truncated, expected.Length);
            });

            ExpectFormatError("trailing input", delegate
            {
                byte[] trailing = new byte[valid.Length + 1];
                Buffer.BlockCopy(valid, 0, trailing, 0, valid.Length);
                MermaidDecoder.Decompress(trailing, expected.Length);
            });

            ExpectFormatError("bad block header", delegate
            {
                byte[] broken = (byte[])valid.Clone();
                broken[0] = (byte)(broken[0] & 0xF0);
                MermaidDecoder.Decompress(broken, expected.Length);
            });

            ExpectFormatError("wrong output size", delegate
            {
                MermaidDecoder.Decompress(valid, expected.Length + 1);
            });

            ExpectArgumentError("null input", delegate
            {
                MermaidDecoder.Decompress(null, expected.Length);
            });

            Console.WriteLine("CORRUPTION_TESTS_OK 5");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.GetType().FullName + ": " + ex.Message);
            Console.Error.WriteLine(ex.StackTrace);
            return 1;
        }
    }

    private static void ExpectFormatError(string name, Action action)
    {
        try
        {
            action();
        }
        catch (OodleFormatException)
        {
            return;
        }
        throw new Exception(name + " unexpectedly succeeded");
    }

    private static void ExpectArgumentError(string name, Action action)
    {
        try
        {
            action();
        }
        catch (ArgumentNullException)
        {
            return;
        }
        throw new Exception(name + " unexpectedly succeeded");
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
}
