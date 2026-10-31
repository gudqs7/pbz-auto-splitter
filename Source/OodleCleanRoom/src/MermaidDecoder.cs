using System;
using System.Collections.Generic;

namespace OodleCleanRoom
{
    /// <summary>
    /// Scalar decoder for the Oodle LZ subset used by Phantom Blade Zero saves.
    /// </summary>
    public static class MermaidDecoder
    {
        private const int BlockSize = 0x40000;
        private const int ChunkSize = 0x20000;
        private const int SubBlockSize = 0x10000;

        public static byte[] Decompress(byte[] compressed, int rawSize)
        {
            if (compressed == null)
            {
                throw new ArgumentNullException("compressed");
            }
            if (compressed.Length == 0)
            {
                throw new ArgumentException("compressed data is empty");
            }
            if (rawSize <= 0 || rawSize > 256 * 1024 * 1024)
            {
                throw new OodleFormatException(
                    "invalid uncompressed size " + rawSize);
            }

            byte[] output = new byte[rawSize];
            int inputPosition = 0;
            int outputPosition = 0;
            while (outputPosition < rawSize)
            {
                if (inputPosition > compressed.Length - 2)
                {
                    throw new OodleFormatException(
                        "truncated Oodle block header");
                }

                int header0 = compressed[inputPosition];
                int header1 = compressed[inputPosition + 1];
                inputPosition += 2;
                if ((header0 & 0x0F) != 0x0C
                    || (header0 & 0x30) != 0)
                {
                    throw new OodleFormatException(
                        "invalid Oodle block header");
                }

                bool stored = (header0 & 0x40) != 0;
                bool restart = (header0 & 0x80) != 0;
                bool checksums = (header1 & 0x80) != 0;
                int decoderId = header1 & 0x7F;
                int blockOutput = Math.Min(BlockSize, rawSize - outputPosition);

                if (decoderId != 0x0A)
                {
                    throw new OodleFormatException(
                        "unsupported Oodle decoder id " + decoderId);
                }
                if (checksums)
                {
                    throw new OodleFormatException(
                        "Oodle checksum blocks are unsupported");
                }

                if (stored)
                {
                    if (blockOutput > compressed.Length - inputPosition)
                    {
                        throw new OodleFormatException(
                            "truncated stored Oodle block");
                    }
                    Buffer.BlockCopy(
                        compressed,
                        inputPosition,
                        output,
                        outputPosition,
                        blockOutput);
                    inputPosition += blockOutput;
                    outputPosition += blockOutput;
                    continue;
                }

                if (inputPosition > compressed.Length - 3)
                {
                    throw new OodleFormatException(
                        "truncated Oodle quantum header");
                }
                int quantum =
                    (compressed[inputPosition] << 16)
                    | (compressed[inputPosition + 1] << 8)
                    | compressed[inputPosition + 2];
                inputPosition += 3;
                int sizeMinusOne = quantum & 0x3FFFF;
                if (sizeMinusOne == 0x3FFFF)
                {
                    throw new OodleFormatException(
                        "special Oodle quanta are unsupported");
                }

                int compressedSize = sizeMinusOne + 1;
                if (compressedSize > compressed.Length - inputPosition)
                {
                    throw new OodleFormatException(
                        "truncated Oodle quantum");
                }
                int payloadStart = inputPosition;
                int payloadEnd = payloadStart + compressedSize;
                DecodeQuantum(
                    compressed,
                    payloadStart,
                    payloadEnd,
                    output,
                    outputPosition,
                    blockOutput,
                    restart || outputPosition == 0,
                    outputPosition == 0);
                inputPosition = payloadEnd;
                outputPosition += blockOutput;
            }

            if (inputPosition != compressed.Length)
            {
                throw new OodleFormatException(
                    "trailing bytes after Oodle data");
            }
            return output;
        }

        private static void DecodeQuantum(
            byte[] data,
            int source,
            int sourceEnd,
            byte[] destination,
            int destinationOffset,
            int destinationLength,
            bool restart,
            bool outputAtZero)
        {
            if (sourceEnd - source < 4)
            {
                throw new OodleFormatException(
                    "truncated Mermaid quantum");
            }

            int selector =
                (data[source] << 16)
                | (data[source + 1] << 8)
                | data[source + 2];
            if ((selector & 0x800000) == 0)
            {
                int directLength;
                EntropyDecoder.DecodeChunkInto(
                    data,
                    source,
                    sourceEnd,
                    destination,
                    destinationOffset,
                    out directLength);
                if (directLength != destinationLength)
                {
                    throw new OodleFormatException(
                        "direct entropy size mismatch");
                }
                return;
            }

            source += 3;
            int compressedLength = selector & 0x7FFFF;
            int mode = (selector >> 19) & 0xF;
            if (compressedLength > sourceEnd - source)
            {
                throw new OodleFormatException(
                    "truncated Mermaid payload");
            }
            int payloadEnd = source + compressedLength;

            if (compressedLength >= destinationLength)
            {
                if (compressedLength != destinationLength || mode != 0)
                {
                    throw new OodleFormatException(
                        "invalid direct Mermaid payload");
                }
                Buffer.BlockCopy(
                    data,
                    source,
                    destination,
                    destinationOffset,
                    destinationLength);
                return;
            }

            if (mode > 1)
            {
                throw new OodleFormatException(
                    "unsupported Mermaid mode " + mode);
            }

            DecodeMermaidPayload(
                data,
                source,
                payloadEnd,
                destination,
                destinationOffset,
                destinationLength,
                mode,
                outputAtZero,
                restart);
        }

        private static void DecodeMermaidPayload(
            byte[] data,
            int source,
            int sourceEnd,
            byte[] destination,
            int destinationOffset,
            int destinationLength,
            int mode,
            bool outputAtZero,
            bool restart)
        {
            if (sourceEnd - source < 10)
            {
                throw new OodleFormatException(
                    "truncated Mermaid table");
            }
            if (!outputAtZero)
            {
                throw new OodleFormatException(
                    "PBZ clean-room decoder requires output offset zero");
            }

            Buffer.BlockCopy(
                data,
                source,
                destination,
                destinationOffset,
                8);
            source += 8;

            byte[] literals;
            int literalLength;
            EntropyDecoder.DecodeChunkInto(
                data,
                source,
                sourceEnd,
                literals = new byte[Math.Min(
                    EntropyDecoder.MaxOutputSize,
                    Math.Max(1, destinationLength))],
                0,
                out literalLength);
            source += EntropyDecoder.ParseChunk(
                data, source, sourceEnd).TotalLength;
            Array.Resize(ref literals, literalLength);

            byte[] commands;
            int commandLength;
            EntropyDecoder.DecodeChunkInto(
                data,
                source,
                sourceEnd,
                commands = new byte[Math.Min(
                    EntropyDecoder.MaxOutputSize,
                    Math.Max(1, destinationLength))],
                0,
                out commandLength);
            source += EntropyDecoder.ParseChunk(
                data, source, sourceEnd).TotalLength;
            Array.Resize(ref commands, commandLength);

            int commandSplit = commandLength;
            if (destinationLength > SubBlockSize)
            {
                Require(source, sourceEnd, 2);
                commandSplit = ReadUInt16(data, source);
                if (commandSplit > commandLength)
                {
                    throw new OodleFormatException(
                        "invalid Mermaid command split");
                }
                source += 2;
            }

            Require(source, sourceEnd, 2);
            int off16Count = ReadUInt16(data, source);
            source += 2;

            ushort[] off16;
            if (off16Count == 0xFFFF)
            {
                byte[] high;
                int highLength;
                EntropyDecoder.DecodeChunkInto(
                    data,
                    source,
                    sourceEnd,
                    high = new byte[Math.Min(
                        EntropyDecoder.MaxOutputSize,
                        Math.Max(1, destinationLength >> 1))],
                    0,
                    out highLength);
                source += EntropyDecoder.ParseChunk(
                    data, source, sourceEnd).TotalLength;

                byte[] low;
                int lowLength;
                EntropyDecoder.DecodeChunkInto(
                    data,
                    source,
                    sourceEnd,
                    low = new byte[Math.Min(
                        EntropyDecoder.MaxOutputSize,
                        Math.Max(1, destinationLength >> 1))],
                    0,
                    out lowLength);
                source += EntropyDecoder.ParseChunk(
                    data, source, sourceEnd).TotalLength;

                if (lowLength != highLength)
                {
                    throw new OodleFormatException(
                        "Mermaid off16 entropy sizes differ");
                }
                off16 = new ushort[lowLength];
                for (int i = 0; i < lowLength; i++)
                {
                    off16[i] = (ushort)(low[i] | (high[i] << 8));
                }
            }
            else
            {
                Require(source, sourceEnd, off16Count * 2);
                off16 = new ushort[off16Count];
                for (int i = 0; i < off16Count; i++)
                {
                    off16[i] = (ushort)ReadUInt16(data, source);
                    source += 2;
                }
            }

            Require(source, sourceEnd, 3);
            int farCounts = ReadUInt24(data, source);
            source += 3;

            int[] farOffsets1 = new int[0];
            int[] farOffsets2 = new int[0];
            if (farCounts != 0)
            {
                int count1 = farCounts >> 12;
                int count2 = farCounts & 0xFFF;
                if (count1 == 0xFFF)
                {
                    Require(source, sourceEnd, 2);
                    count1 = ReadUInt16(data, source);
                    source += 2;
                }
                if (count2 == 0xFFF)
                {
                    Require(source, sourceEnd, 2);
                    count2 = ReadUInt16(data, source);
                    source += 2;
                }

                farOffsets1 = ReadFarOffsets(
                    data, ref source, sourceEnd, count1, 0);
                farOffsets2 = ReadFarOffsets(
                    data, ref source, sourceEnd, count2, SubBlockSize);
            }

            int lengthStreamStart = source;
            int remaining = destinationLength;
            int destinationPosition = destinationOffset;
            int savedDistance = -8;
            int iteration = 0;
            while (remaining > 0)
            {
                if (iteration >= 2)
                {
                    throw new OodleFormatException(
                        "Mermaid produced too many sub-blocks");
                }

                int subBlockLength = Math.Min(remaining, SubBlockSize);
                int commandStart = iteration == 0 ? 0 : commandSplit;
                int commandEnd = iteration == 0
                    ? commandSplit
                    : commandLength;
                int[] farOffsets = iteration == 0
                    ? farOffsets1
                    : farOffsets2;
                int startOffset = iteration == 0 ? 8 : 0;

                ProcessCommands(
                    data,
                    ref lengthStreamStart,
                    sourceEnd,
                    destination,
                    destinationPosition,
                    subBlockLength,
                    commands,
                    commandStart,
                    commandEnd,
                    literals,
                    off16,
                    farOffsets,
                    mode,
                    startOffset,
                    ref savedDistance);

                destinationPosition += subBlockLength;
                remaining -= subBlockLength;
                iteration++;
            }

            if (lengthStreamStart != sourceEnd)
            {
                throw new OodleFormatException(
                    "Mermaid length stream not fully consumed");
            }
        }

        private static void ProcessCommands(
            byte[] data,
            ref int lengthPosition,
            int lengthEnd,
            byte[] destination,
            int subBlockStart,
            int subBlockLength,
            byte[] commands,
            int commandStart,
            int commandEnd,
            byte[] literals,
            ushort[] off16,
            int[] farOffsets,
            int mode,
            int startOffset,
            ref int savedDistance)
        {
            int destinationPosition = subBlockStart + startOffset;
            int destinationEnd = subBlockStart + subBlockLength;
            int literalPosition = 0;
            int off16Position = 0;
            int farPosition = 0;
            int recentOffset = savedDistance;

            for (int commandPosition = commandStart;
                commandPosition < commandEnd;
                commandPosition++)
            {
                int command = commands[commandPosition];
                if (command >= 24)
                {
                    int literalCount = command & 7;
                    CopyLiterals(
                        literals,
                        ref literalPosition,
                        destination,
                        destinationPosition,
                        recentOffset,
                        literalCount,
                        mode);
                    destinationPosition += literalCount;

                    if ((command & 0x80) == 0)
                    {
                        if (off16Position >= off16.Length)
                        {
                            throw new OodleFormatException(
                                "Mermaid recent-offset stream exhausted");
                        }
                        recentOffset = -off16[off16Position++];
                    }

                    int matchLength = (command >> 3) & 0xF;
                    CopyMatch(
                        destination,
                        destinationPosition,
                        recentOffset,
                        matchLength);
                    destinationPosition += matchLength;
                    continue;
                }

                if (command > 2)
                {
                    int matchLength = command + 5;
                    if (farPosition >= farOffsets.Length)
                    {
                        throw new OodleFormatException(
                            "Mermaid far-offset stream exhausted");
                    }
                    recentOffset =
                        subBlockStart - farOffsets[farPosition++]
                        - destinationPosition;
                    CopyMatch(
                        destination,
                        destinationPosition,
                        recentOffset,
                        matchLength);
                    destinationPosition += matchLength;
                    continue;
                }

                int length = ReadExtendedLength(
                    data, ref lengthPosition, lengthEnd);
                if (command == 0)
                {
                    length += 64;
                    CopyLiterals(
                        literals,
                        ref literalPosition,
                        destination,
                        destinationPosition,
                        recentOffset,
                        length,
                        mode);
                    destinationPosition += length;
                }
                else if (command == 1)
                {
                    length += 91;
                    if (off16Position >= off16.Length)
                    {
                        throw new OodleFormatException(
                            "Mermaid recent-offset stream exhausted");
                    }
                    recentOffset = -off16[off16Position++];
                    CopyMatch(
                        destination,
                        destinationPosition,
                        recentOffset,
                        length);
                    destinationPosition += length;
                }
                else
                {
                    length += 29;
                    if (farPosition >= farOffsets.Length)
                    {
                        throw new OodleFormatException(
                            "Mermaid far-offset stream exhausted");
                    }
                    recentOffset =
                        subBlockStart - farOffsets[farPosition++]
                        - destinationPosition;
                    CopyMatch(
                        destination,
                        destinationPosition,
                        recentOffset,
                        length);
                    destinationPosition += length;
                }
            }

            int tailLength = destinationEnd - destinationPosition;
            CopyLiterals(
                literals,
                ref literalPosition,
                destination,
                destinationPosition,
                recentOffset,
                tailLength,
                mode);
            destinationPosition += tailLength;
            savedDistance = recentOffset;
        }

        private static void CopyLiterals(
            byte[] literals,
            ref int literalPosition,
            byte[] destination,
            int destinationPosition,
            int recentOffset,
            int count,
            int mode)
        {
            if (count < 0
                || count > literals.Length - literalPosition
                || count > destination.Length - destinationPosition)
            {
                throw new OodleFormatException(
                    "Mermaid literal copy out of range");
            }

            if (mode != 0)
            {
                Buffer.BlockCopy(
                    literals,
                    literalPosition,
                    destination,
                    destinationPosition,
                    count);
            }
            else
            {
                int referencePosition = destinationPosition + recentOffset;
                if (referencePosition < 0
                    || count > destination.Length - referencePosition)
                {
                    throw new OodleFormatException(
                        "Mermaid additive literal source out of range");
                }
                for (int i = 0; i < count; i++)
                {
                    destination[destinationPosition + i] =
                        (byte)(literals[literalPosition + i]
                            + destination[referencePosition + i]);
                }
            }
            literalPosition += count;
        }

        private static void CopyMatch(
            byte[] destination,
            int destinationPosition,
            int recentOffset,
            int count)
        {
            int sourcePosition = destinationPosition + recentOffset;
            if (count < 0
                || sourcePosition < 0
                || count > destination.Length - destinationPosition)
            {
                throw new OodleFormatException(
                    "Mermaid match copy out of range");
            }

            for (int i = 0; i < count; i++)
            {
                destination[destinationPosition + i] =
                    destination[sourcePosition + i];
            }
        }

        private static int ReadExtendedLength(
            byte[] data, ref int position, int end)
        {
            Require(position, end, 1);
            int length = data[position++];
            if (length > 251)
            {
                Require(position, end, 2);
                length += ReadUInt16(data, position) * 4;
                position += 2;
            }
            return length;
        }

        private static int[] ReadFarOffsets(
            byte[] data,
            ref int source,
            int sourceEnd,
            int count,
            int outputOffset)
        {
            int[] result = new int[count];
            bool extended = outputOffset >= 0xC00000 - 1;
            for (int i = 0; i < count; i++)
            {
                Require(source, sourceEnd, 3);
                int value = ReadUInt24(data, source);
                source += 3;
                if (extended && value >= 0xC00000)
                {
                    Require(source, sourceEnd, 1);
                    value += data[source++] << 22;
                }
                if (value > outputOffset)
                {
                    throw new OodleFormatException(
                        "Mermaid far offset exceeds history");
                }
                result[i] = value;
            }
            return result;
        }

        private static void Require(int offset, int end, int count)
        {
            if (offset < 0 || count < 0 || count > end - offset)
            {
                throw new OodleFormatException("truncated Mermaid data");
            }
        }

        private static int ReadUInt16(byte[] data, int offset)
        {
            return data[offset] | (data[offset + 1] << 8);
        }

        private static int ReadUInt24(byte[] data, int offset)
        {
            return data[offset]
                | (data[offset + 1] << 8)
                | (data[offset + 2] << 16);
        }
    }
}
