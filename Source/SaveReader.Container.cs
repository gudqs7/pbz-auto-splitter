using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace PBZ
{
    public static partial class SaveReader
    {
        private const string SaveMagic = "PBZS";
        private const int RecordHeaderSize = 36;
        private const int OodleGuardBytes = 65536;

        private static IntPtr _oodleModule = IntPtr.Zero;
        private static string _oodlePath;
        private static OodleDecompressDelegate _oodleDecompress;
        private static OodleCompressorDelegate _oodleCompressor;

        private static SortedDictionary<string, int> ReadKills(
            string savePath, string oodlePath)
        {
            using (FileStream stream = new FileStream(
                savePath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                long length = stream.Length;
                if (length <= 0 || length > MaxSaveSize)
                {
                    throw new InvalidDataException("unexpected save size " + length);
                }

                byte[] header = new byte[12];
                ReadExactly(stream, header, header.Length);
                if (!HasMagic(header, 0))
                {
                    throw new InvalidDataException("not a PBZS save container");
                }

                int indexSize = (int)ReadUInt32(header, 8);
                if (indexSize <= RecordHeaderSize
                    || 12L + indexSize > length)
                {
                    throw new InvalidDataException(
                        "invalid index size " + indexSize);
                }

                byte[] indexBlob = new byte[indexSize];
                ReadExactly(stream, indexBlob, indexSize);
                byte[] indexPlain = DecryptRecord(indexBlob);
                IndexEntry advanced = FindIndexEntry(
                    ParseIndex(indexPlain), "__Advanced__");
                if (advanced == null)
                {
                    throw new InvalidDataException(
                        "__Advanced__ chunk not found");
                }

                long chunkStart = 12L + indexSize + advanced.ChunkOffset;
                long chunkEnd = chunkStart + advanced.EncryptedSize;
                if (chunkStart < 0
                    || chunkEnd > length
                    || advanced.EncryptedSize <= 0)
                {
                    throw new InvalidDataException(
                        "__Advanced__ chunk out of range");
                }

                stream.Position = chunkStart;
                byte[] chunk = new byte[advanced.EncryptedSize];
                ReadExactly(stream, chunk, chunk.Length);
                byte[] compressed = DecryptRecord(chunk);
                byte[] raw = DecompressPayload(
                    compressed,
                    advanced.UncompressedSize,
                    savePath,
                    oodlePath);
                string json = Encoding.UTF8.GetString(raw);
                return JsonBossParser.ExtractBossKills(json);
            }
        }

        private static byte[] DecompressPayload(
            byte[] compressed,
            int rawSize,
            string savePath,
            string oodlePath)
        {
            if (!string.IsNullOrEmpty(oodlePath))
            {
                return DecompressWithOodle(compressed, rawSize, oodlePath);
            }

            string backend = Environment.GetEnvironmentVariable(
                "PBZ_ODLE_BACKEND");
            if (string.IsNullOrEmpty(backend))
            {
                backend = "auto";
            }

            if (string.Equals(backend, "cleanroom", StringComparison.OrdinalIgnoreCase)
                || string.Equals(backend, "auto", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    return OodleCleanRoom.MermaidDecoder.Decompress(
                        compressed, rawSize);
                }
                catch (Exception cleanRoomError)
                {
                    bool fallbackEnabled = string.Equals(
                        backend,
                        "auto",
                        StringComparison.OrdinalIgnoreCase);
                    string fallback = Environment.GetEnvironmentVariable(
                        "PBZ_ODLE_FALLBACK");
                    if (string.Equals(
                            fallback,
                            "none",
                            StringComparison.OrdinalIgnoreCase))
                    {
                        fallbackEnabled = false;
                    }
                    else if (string.Equals(
                        fallback,
                        "game",
                        StringComparison.OrdinalIgnoreCase))
                    {
                        fallbackEnabled = true;
                    }

                    if (!fallbackEnabled)
                    {
                        throw new InvalidDataException(
                            "clean-room Mermaid decode failed: "
                            + cleanRoomError.Message,
                            cleanRoomError);
                    }

                    try
                    {
                        return GameOodleDecompressor.Decompress(
                            compressed, rawSize, savePath);
                    }
                    catch (Exception gameError)
                    {
                        throw new InvalidDataException(
                            "clean-room and game Oodle decoders both failed",
                            new AggregateException(
                                cleanRoomError, gameError));
                    }
                }
            }

            if (string.Equals(
                backend, "game", StringComparison.OrdinalIgnoreCase))
            {
                return GameOodleDecompressor.Decompress(
                    compressed, rawSize, savePath);
            }

            throw new InvalidDataException(
                "unknown PBZ_ODLE_BACKEND value: " + backend);
        }

        private static List<IndexEntry> ParseIndex(byte[] plain)
        {
            if (plain.Length < 12 || !HasMagic(plain, 0))
            {
                throw new InvalidDataException("invalid decrypted index header");
            }

            List<IndexEntry> entries = new List<IndexEntry>();
            int position = 12;
            while (position < plain.Length)
            {
                if (position + 2 > plain.Length)
                {
                    throw new InvalidDataException("truncated index entry");
                }

                int nameLength = plain[position] | (plain[position + 1] << 8);
                position += 2;
                if (nameLength <= 0
                    || position + nameLength + 14 > plain.Length)
                {
                    throw new InvalidDataException("truncated index entry");
                }

                IndexEntry entry = new IndexEntry();
                entry.Name = Encoding.UTF8.GetString(plain, position, nameLength);
                position += nameLength + 2;
                entry.UncompressedSize = (int)ReadUInt32(plain, position);
                entry.ChunkOffset = (int)ReadUInt32(plain, position + 4);
                entry.EncryptedSize = (int)ReadUInt32(plain, position + 8);
                position += 12;
                entries.Add(entry);
            }
            return entries;
        }

        private static IndexEntry FindIndexEntry(
            List<IndexEntry> entries, string name)
        {
            for (int i = 0; i < entries.Count; i++)
            {
                if (string.Equals(entries[i].Name, name, StringComparison.Ordinal))
                {
                    return entries[i];
                }
            }
            return null;
        }

        private static byte[] DecompressWithOodle(
            byte[] compressed, int rawSize, string oodlePath)
        {
            if (rawSize <= 0 || rawSize > 256 * 1024 * 1024)
            {
                throw new InvalidDataException("invalid uncompressed size " + rawSize);
            }

            EnsureOodle(oodlePath);

            int compressor = -1;
            if (_oodleCompressor != null)
            {
                byte[] paddedInput = Pad(compressed);
                GCHandle inputHandle = default(GCHandle);
                try
                {
                    inputHandle = GCHandle.Alloc(
                        paddedInput, GCHandleType.Pinned);
                    compressor = _oodleCompressor(
                        inputHandle.AddrOfPinnedObject(),
                        compressed.Length,
                        0);
                }
                finally
                {
                    if (inputHandle.IsAllocated)
                    {
                        inputHandle.Free();
                    }
                }
            }

            if (compressor == 0 || (compressor < 0 && compressed.Length == rawSize))
            {
                return compressed;
            }

            byte[] source = Pad(compressed);
            byte[] destination = new byte[rawSize + OodleGuardBytes];
            GCHandle sourceHandle = default(GCHandle);
            GCHandle destinationHandle = default(GCHandle);
            try
            {
                sourceHandle = GCHandle.Alloc(source, GCHandleType.Pinned);
                destinationHandle = GCHandle.Alloc(
                    destination, GCHandleType.Pinned);
                long result = _oodleDecompress(
                    sourceHandle.AddrOfPinnedObject(),
                    compressed.Length,
                    destinationHandle.AddrOfPinnedObject(),
                    rawSize,
                    0,
                    0,
                    0,
                    IntPtr.Zero,
                    0,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    0,
                    3);
                if (result != rawSize)
                {
                    throw new InvalidDataException(
                        "Oodle decompression failed: got "
                        + result + ", expected " + rawSize);
                }
            }
            finally
            {
                if (sourceHandle.IsAllocated)
                {
                    sourceHandle.Free();
                }
                if (destinationHandle.IsAllocated)
                {
                    destinationHandle.Free();
                }
            }

            byte[] output = new byte[rawSize];
            Buffer.BlockCopy(destination, 0, output, 0, rawSize);
            return output;
        }

        private static byte[] Pad(byte[] data)
        {
            byte[] padded = new byte[data.Length + OodleGuardBytes];
            Buffer.BlockCopy(data, 0, padded, 0, data.Length);
            return padded;
        }

        private static void EnsureOodle(string path)
        {
            lock (Sync)
            {
                if (_oodleDecompress != null
                    && string.Equals(_oodlePath, path, StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }

                IntPtr module = LoadLibraryW(path);
                if (module == IntPtr.Zero)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "LoadLibrary failed: " + path);
                }

                IntPtr decompressAddress = GetProcAddress(
                    module, "OodleLZ_Decompress");
                if (decompressAddress == IntPtr.Zero)
                {
                    throw new EntryPointNotFoundException(
                        "OodleLZ_Decompress not exported by " + path);
                }

                IntPtr compressorAddress = GetProcAddress(
                    module, "OodleLZ_GetFirstChunkCompressor");
                _oodleDecompress = (OodleDecompressDelegate)
                    Marshal.GetDelegateForFunctionPointer(
                        decompressAddress, typeof(OodleDecompressDelegate));
                _oodleCompressor = compressorAddress == IntPtr.Zero
                    ? null
                    : (OodleCompressorDelegate)
                        Marshal.GetDelegateForFunctionPointer(
                            compressorAddress, typeof(OodleCompressorDelegate));
                _oodleModule = module;
                _oodlePath = path;
            }
        }

        private static void ReadExactly(
            Stream stream, byte[] buffer, int length)
        {
            int offset = 0;
            while (offset < length)
            {
                int read = stream.Read(buffer, offset, length - offset);
                if (read <= 0)
                {
                    throw new EndOfStreamException(
                        "unexpected end of save at " + offset + "/" + length);
                }
                offset += read;
            }
        }

        private static bool HasMagic(byte[] data, int offset)
        {
            return data.Length >= offset + 4
                && data[offset] == (byte)'P'
                && data[offset + 1] == (byte)'B'
                && data[offset + 2] == (byte)'Z'
                && data[offset + 3] == (byte)'S';
        }

        private static uint ReadUInt32(byte[] data, int offset)
        {
            return (uint)(data[offset]
                | (data[offset + 1] << 8)
                | (data[offset + 2] << 16)
                | (data[offset + 3] << 24));
        }

        private sealed class IndexEntry
        {
            public string Name;
            public int UncompressedSize;
            public int ChunkOffset;
            public int EncryptedSize;
        }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate long OodleDecompressDelegate(
            IntPtr compressed,
            long compressedSize,
            IntPtr raw,
            long rawSize,
            int fuzzSafe,
            int checkCrc,
            int verbosity,
            IntPtr decoderBufferBase,
            long decoderBufferSize,
            IntPtr callback,
            IntPtr callbackData,
            IntPtr decoderMemory,
            long decoderMemorySize,
            int threadPhase);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int OodleCompressorDelegate(
            IntPtr compressed, long compressedSize, int fuzzSafe);

        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryW(string fileName);

        [DllImport("kernel32", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(
            IntPtr module, string procedureName);
    }
}
