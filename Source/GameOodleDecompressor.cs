using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace PBZ
{
    /// <summary>
    /// Calls the Oodle decoder already initialized inside PBZ.exe. The package
    /// contains no Oodle binary and the remote allocation is released after each
    /// save read.
    /// </summary>
    internal static class GameOodleDecompressor
    {
        private const int KnownOodleRva = 0x8D7FD20;
        private const int RemoteGuardBytes = 65536;
        private const int ParameterSize = 0x78;

        private const uint ProcessCreateThread = 0x0002;
        private const uint ProcessVmOperation = 0x0008;
        private const uint ProcessVmRead = 0x0010;
        private const uint ProcessVmWrite = 0x0020;
        private const uint ProcessQueryInformation = 0x0400;

        private const uint MemCommit = 0x00001000;
        private const uint MemReserve = 0x00002000;
        private const uint MemRelease = 0x00008000;
        private const uint PageReadWrite = 0x04;
        private const uint PageExecuteRead = 0x20;

        private const uint WaitObject0 = 0;
        private const uint WaitTimeout = 0x102;
        private const uint Infinite = 0xFFFFFFFF;

        private static readonly object Sync = new object();
        private static readonly int[] Pattern = ParsePattern(
            "40 55 53 56 57 41 54 41 55 41 56 41 57 "
            + "48 81 EC F8 00 00 00 48 8D 6C 24 60 "
            + "48 C7 45 48 FE FF FF FF 48 8B 05 ?? ?? ?? ?? "
            + "48 33 C5 48 89 85 88 00 00 00 4C 89 4D 18 "
            + "4D 8B E8 4C 89 45 38 4C 8B F2 48 89 55 50 "
            + "48 89 4D 08");

        // Windows x64:
        //   RCX = parameter block
        //   shadow space + arguments 4..13
        //   call OodleLZ_Decompress(comp, compSize, raw, rawSize, 0, 0, 0,
        //                           0, 0, 0, 0, 0, 0, 3)
        private static readonly byte[] RemoteStub =
        {
            0x48, 0x81, 0xEC, 0x88, 0x00, 0x00, 0x00,
            0x49, 0x89, 0xCA,
            0x49, 0x8B, 0x0A,
            0x49, 0x8B, 0x52, 0x08,
            0x4D, 0x8B, 0x42, 0x10,
            0x4D, 0x8B, 0x4A, 0x18,
            0x31, 0xC0,
            0x48, 0x89, 0x44, 0x24, 0x20,
            0x48, 0x89, 0x44, 0x24, 0x28,
            0x48, 0x89, 0x44, 0x24, 0x30,
            0x48, 0x89, 0x44, 0x24, 0x38,
            0x48, 0x89, 0x44, 0x24, 0x40,
            0x48, 0x89, 0x44, 0x24, 0x48,
            0x48, 0x89, 0x44, 0x24, 0x50,
            0x48, 0x89, 0x44, 0x24, 0x58,
            0x48, 0x89, 0x44, 0x24, 0x60,
            0x48, 0xC7, 0x44, 0x24, 0x68, 0x03, 0x00, 0x00, 0x00,
            0x4D, 0x8B, 0x5A, 0x70,
            0x41, 0xFF, 0xD3,
            0x48, 0x81, 0xC4, 0x88, 0x00, 0x00, 0x00,
            0xC3
        };

        private static int _cachedPid;
        private static long _cachedBase;
        private static long _cachedFunction;
        private static string _cachedExePath;
        private static long _cachedExeLength;
        private static long _cachedExeWriteTicks;

        public static byte[] Decompress(
            byte[] compressed, int rawSize, string gamePathHint)
        {
            if (compressed == null || compressed.Length == 0)
            {
                throw new ArgumentException("compressed data is empty");
            }
            if (rawSize <= 0 || rawSize > 256 * 1024 * 1024)
            {
                throw new InvalidDataException(
                    "invalid uncompressed size " + rawSize);
            }
            if (compressed.Length == rawSize && LooksLikeJson(compressed))
            {
                return compressed;
            }

            LiveRuntime runtime;
            lock (Sync)
            {
                runtime = ResolveRuntime(gamePathHint);
            }

            IntPtr process = OpenProcess(
                ProcessCreateThread
                | ProcessVmOperation
                | ProcessVmRead
                | ProcessVmWrite
                | ProcessQueryInformation,
                false,
                runtime.ProcessId);
            if (process == IntPtr.Zero)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "OpenProcess(PBZ) failed");
            }

            IntPtr code = IntPtr.Zero;
            IntPtr parameters = IntPtr.Zero;
            IntPtr source = IntPtr.Zero;
            IntPtr destination = IntPtr.Zero;
            IntPtr thread = IntPtr.Zero;
            try
            {
                code = Alloc(process, RemoteStub.Length);
                parameters = Alloc(process, ParameterSize);
                source = Alloc(
                    process, checked(compressed.Length + RemoteGuardBytes));
                destination = Alloc(
                    process, checked(rawSize + RemoteGuardBytes));

                Write(process, code, RemoteStub);

                byte[] parameterBlock = new byte[ParameterSize];
                WriteInt64(parameterBlock, 0x00, source.ToInt64());
                WriteInt64(parameterBlock, 0x08, compressed.Length);
                WriteInt64(parameterBlock, 0x10, destination.ToInt64());
                WriteInt64(parameterBlock, 0x18, rawSize);
                WriteInt64(parameterBlock, 0x70, runtime.FunctionAddress);
                Write(process, parameters, parameterBlock);
                Write(process, source, compressed);

                uint oldProtection;
                if (!VirtualProtectEx(
                    process,
                    code,
                    (UIntPtr)RemoteStub.Length,
                    PageExecuteRead,
                    out oldProtection))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "VirtualProtectEx(code) failed");
                }

                uint threadId;
                thread = CreateRemoteThread(
                    process,
                    IntPtr.Zero,
                    0,
                    code,
                    parameters,
                    0,
                    out threadId);
                if (thread == IntPtr.Zero)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "CreateRemoteThread failed");
                }

                uint wait = WaitForSingleObject(thread, 5000);
                if (wait == WaitTimeout)
                {
                    TerminateThread(thread, 0xFFFFFFFF);
                    WaitForSingleObject(thread, 1000);
                    throw new TimeoutException(
                        "PBZ Oodle decompression timed out");
                }
                if (wait != WaitObject0)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "WaitForSingleObject failed");
                }

                uint result;
                if (!GetExitCodeThread(thread, out result))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "GetExitCodeThread failed");
                }
                if (result != (uint)rawSize)
                {
                    throw new InvalidDataException(
                        "PBZ Oodle decompression failed: got "
                        + result + ", expected " + rawSize);
                }

                byte[] raw = new byte[rawSize];
                Read(process, destination, raw);
                return raw;
            }
            finally
            {
                if (thread != IntPtr.Zero)
                {
                    CloseHandle(thread);
                }
                Free(process, code);
                Free(process, parameters);
                Free(process, source);
                Free(process, destination);
                CloseHandle(process);
            }
        }

        private static LiveRuntime ResolveRuntime(string gamePathHint)
        {
            if (_cachedPid != 0)
            {
                try
                {
                    Process cached = Process.GetProcessById(_cachedPid);
                    ProcessModule module = cached.MainModule;
                    if (module != null
                        && module.BaseAddress.ToInt64() == _cachedBase
                        && File.Exists(_cachedExePath))
                    {
                        return new LiveRuntime(
                            _cachedPid, _cachedBase, _cachedFunction);
                    }
                }
                catch
                {
                    ResetCache();
                }
            }

            Process best = null;
            int bestSize = 0;
            foreach (Process candidate in Process.GetProcessesByName("PBZ"))
            {
                try
                {
                    int size = candidate.MainModule.ModuleMemorySize;
                    if (size > bestSize)
                    {
                        if (best != null)
                        {
                            best.Dispose();
                        }
                        best = candidate;
                        bestSize = size;
                    }
                    else
                    {
                        candidate.Dispose();
                    }
                }
                catch
                {
                    candidate.Dispose();
                }
            }

            if (best == null)
            {
                throw new InvalidOperationException(
                    "PBZ process is not running");
            }

            try
            {
                ProcessModule module = best.MainModule;
                long moduleBase = module.BaseAddress.ToInt64();
                string exePath = module.FileName;

                int rva = FindOodleRva(best, moduleBase, exePath);
                _cachedPid = best.Id;
                _cachedBase = moduleBase;
                _cachedFunction = moduleBase + rva;
                _cachedExePath = exePath;
                FileInfo info = new FileInfo(exePath);
                _cachedExeLength = info.Length;
                _cachedExeWriteTicks = info.LastWriteTimeUtc.Ticks;
                return new LiveRuntime(
                    _cachedPid, _cachedBase, _cachedFunction);
            }
            finally
            {
                best.Dispose();
            }
        }

        private static int FindOodleRva(
            Process process, long moduleBase, string exePath)
        {
            if (MatchesProcessPattern(
                process, moduleBase + KnownOodleRva))
            {
                return KnownOodleRva;
            }

            FileInfo info = new FileInfo(exePath);
            if (!string.Equals(
                _cachedExePath, exePath, StringComparison.OrdinalIgnoreCase)
                || info.Length != _cachedExeLength
                || info.LastWriteTimeUtc.Ticks != _cachedExeWriteTicks)
            {
                ResetCache();
            }

            int rva = PePatternScanner.FindRva(exePath, Pattern);
            if (rva <= 0)
            {
                throw new InvalidDataException(
                    "PBZ embedded Oodle signature not found");
            }
            if (!MatchesProcessPattern(process, moduleBase + rva))
            {
                throw new InvalidDataException(
                    "PBZ embedded Oodle signature mismatch in process");
            }
            return rva;
        }

        private static bool MatchesProcessPattern(
            Process process, long address)
        {
            IntPtr handle = OpenProcess(
                ProcessVmRead | ProcessQueryInformation,
                false,
                process.Id);
            if (handle == IntPtr.Zero)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "OpenProcess(PBZ, read) failed");
            }
            try
            {
                byte[] bytes = new byte[Pattern.Length];
                UIntPtr read;
                if (!ReadProcessMemory(
                    handle,
                    new IntPtr(address),
                    bytes,
                    (UIntPtr)bytes.Length,
                    out read)
                    || read.ToUInt64() != (ulong)bytes.Length)
                {
                    return false;
                }
                return MatchesPattern(bytes);
            }
            finally
            {
                CloseHandle(handle);
            }
        }

        private static bool MatchesPattern(byte[] bytes)
        {
            for (int i = 0; i < Pattern.Length; i++)
            {
                if (Pattern[i] >= 0 && bytes[i] != Pattern[i])
                {
                    return false;
                }
            }
            return true;
        }

        private static bool LooksLikeJson(byte[] data)
        {
            for (int i = 0; i < data.Length && i < 8; i++)
            {
                if (data[i] == (byte)'{'
                    || data[i] == (byte)'['
                    || data[i] == 0xEF)
                {
                    return true;
                }
                if (!char.IsWhiteSpace((char)data[i]))
                {
                    return false;
                }
            }
            return false;
        }

        private static void ResetCache()
        {
            _cachedPid = 0;
            _cachedBase = 0;
            _cachedFunction = 0;
            _cachedExePath = null;
            _cachedExeLength = 0;
            _cachedExeWriteTicks = 0;
        }

        private static IntPtr Alloc(IntPtr process, int size)
        {
            IntPtr result = VirtualAllocEx(
                process,
                IntPtr.Zero,
                (UIntPtr)size,
                MemCommit | MemReserve,
                PageReadWrite);
            if (result == IntPtr.Zero)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "VirtualAllocEx failed");
            }
            return result;
        }

        private static void Free(IntPtr process, IntPtr address)
        {
            if (address != IntPtr.Zero)
            {
                VirtualFreeEx(process, address, UIntPtr.Zero, MemRelease);
            }
        }

        private static void Write(
            IntPtr process, IntPtr address, byte[] data)
        {
            UIntPtr written;
            if (!WriteProcessMemory(
                process,
                address,
                data,
                (UIntPtr)data.Length,
                out written)
                || written.ToUInt64() != (ulong)data.Length)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "WriteProcessMemory failed");
            }
        }

        private static void Read(
            IntPtr process, IntPtr address, byte[] destination)
        {
            UIntPtr read;
            if (!ReadProcessMemory(
                process,
                address,
                destination,
                (UIntPtr)destination.Length,
                out read)
                || read.ToUInt64() != (ulong)destination.Length)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "ReadProcessMemory failed");
            }
        }

        private static void WriteInt64(
            byte[] buffer, int offset, long value)
        {
            byte[] bytes = BitConverter.GetBytes(value);
            Buffer.BlockCopy(bytes, 0, buffer, offset, bytes.Length);
        }

        private static int[] ParsePattern(string pattern)
        {
            string[] parts = pattern.Split(
                new char[] { ' ' },
                StringSplitOptions.RemoveEmptyEntries);
            int[] result = new int[parts.Length];
            for (int i = 0; i < parts.Length; i++)
            {
                result[i] = parts[i] == "??"
                    ? -1
                    : int.Parse(parts[i], System.Globalization.NumberStyles.HexNumber);
            }
            return result;
        }

        private sealed class LiveRuntime
        {
            public readonly int ProcessId;
            public readonly long ModuleBase;
            public readonly long FunctionAddress;

            public LiveRuntime(
                int processId, long moduleBase, long functionAddress)
            {
                ProcessId = processId;
                ModuleBase = moduleBase;
                FunctionAddress = functionAddress;
            }
        }

        [DllImport("kernel32", SetLastError = true)]
        private static extern IntPtr OpenProcess(
            uint access, bool inheritHandle, int processId);

        [DllImport("kernel32", SetLastError = true)]
        private static extern IntPtr VirtualAllocEx(
            IntPtr process,
            IntPtr address,
            UIntPtr size,
            uint allocationType,
            uint protection);

        [DllImport("kernel32", SetLastError = true)]
        private static extern bool VirtualFreeEx(
            IntPtr process, IntPtr address, UIntPtr size, uint freeType);

        [DllImport("kernel32", SetLastError = true)]
        private static extern bool VirtualProtectEx(
            IntPtr process,
            IntPtr address,
            UIntPtr size,
            uint newProtection,
            out uint oldProtection);

        [DllImport("kernel32", SetLastError = true)]
        private static extern bool WriteProcessMemory(
            IntPtr process,
            IntPtr address,
            byte[] buffer,
            UIntPtr size,
            out UIntPtr written);

        [DllImport("kernel32", SetLastError = true)]
        private static extern bool ReadProcessMemory(
            IntPtr process,
            IntPtr address,
            byte[] buffer,
            UIntPtr size,
            out UIntPtr read);

        [DllImport("kernel32", SetLastError = true)]
        private static extern IntPtr CreateRemoteThread(
            IntPtr process,
            IntPtr attributes,
            uint stackSize,
            IntPtr startAddress,
            IntPtr parameter,
            uint creationFlags,
            out uint threadId);

        [DllImport("kernel32", SetLastError = true)]
        private static extern uint WaitForSingleObject(
            IntPtr handle, uint milliseconds);

        [DllImport("kernel32", SetLastError = true)]
        private static extern bool GetExitCodeThread(
            IntPtr thread, out uint exitCode);

        [DllImport("kernel32", SetLastError = true)]
        private static extern bool TerminateThread(
            IntPtr thread, uint exitCode);

        [DllImport("kernel32", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
    }

    internal static class PePatternScanner
    {
        public static int FindRva(string path, int[] pattern)
        {
            using (FileStream stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                byte[] dos = new byte[64];
                ReadExactly(stream, 0, dos, dos.Length);
                if (dos[0] != (byte)'M' || dos[1] != (byte)'Z')
                {
                    return -1;
                }

                int peOffset = BitConverter.ToInt32(dos, 0x3C);
                byte[] peHeader = new byte[24];
                ReadExactly(stream, peOffset, peHeader, peHeader.Length);
                if (peHeader[0] != (byte)'P'
                    || peHeader[1] != (byte)'E'
                    || peHeader[2] != 0
                    || peHeader[3] != 0)
                {
                    return -1;
                }

                int sectionCount = BitConverter.ToUInt16(peHeader, 6);
                int optionalSize = BitConverter.ToUInt16(peHeader, 20);
                long sectionTable = peOffset + 24L + optionalSize;
                for (int i = 0; i < sectionCount; i++)
                {
                    byte[] section = new byte[40];
                    ReadExactly(
                        stream,
                        sectionTable + i * 40L,
                        section,
                        section.Length);
                    uint characteristics = BitConverter.ToUInt32(section, 36);
                    if ((characteristics & 0x20000000) == 0)
                    {
                        continue;
                    }

                    uint virtualAddress = BitConverter.ToUInt32(section, 12);
                    uint rawSize = BitConverter.ToUInt32(section, 16);
                    uint rawOffset = BitConverter.ToUInt32(section, 20);
                    if (rawSize == 0 || rawSize > 512U * 1024 * 1024)
                    {
                        continue;
                    }

                    long found = Search(
                        stream,
                        rawOffset,
                        rawOffset + rawSize,
                        pattern);
                    if (found >= 0)
                    {
                        return checked(
                            (int)(virtualAddress
                                + (found - rawOffset)));
                    }
                }
            }
            return -1;
        }

        private static long Search(
            FileStream stream,
            long start,
            long end,
            int[] pattern)
        {
            const int ChunkSize = 4 * 1024 * 1024;
            int overlap = pattern.Length - 1;
            byte[] buffer = new byte[ChunkSize + overlap];
            int carried = 0;
            long position = start;
            while (position < end)
            {
                int wanted = (int)Math.Min(
                    ChunkSize, end - position);
                stream.Position = position;
                int read = stream.Read(buffer, carried, wanted);
                if (read <= 0)
                {
                    break;
                }

                int total = carried + read;
                for (int i = 0; i <= total - pattern.Length; i++)
                {
                    bool match = true;
                    for (int j = 0; j < pattern.Length; j++)
                    {
                        if (pattern[j] >= 0
                            && buffer[i + j] != pattern[j])
                        {
                            match = false;
                            break;
                        }
                    }
                    if (match)
                    {
                        return position - carried + i;
                    }
                }

                carried = Math.Min(overlap, total);
                if (carried > 0)
                {
                    Buffer.BlockCopy(
                        buffer,
                        total - carried,
                        buffer,
                        0,
                        carried);
                }
                position += read;
            }
            return -1;
        }

        private static void ReadExactly(
            FileStream stream, long offset, byte[] buffer, int length)
        {
            stream.Position = offset;
            int done = 0;
            while (done < length)
            {
                int read = stream.Read(buffer, done, length - done);
                if (read <= 0)
                {
                    throw new EndOfStreamException(
                        "unexpected end of PE file");
                }
                done += read;
            }
        }
    }
}
