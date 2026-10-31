using System;

namespace OodleCleanRoom
{
    internal sealed class EntropyChunk
    {
        public int Type;
        public int HeaderSize;
        public int PayloadOffset;
        public int PayloadLength;
        public int OutputLength;
        public int TotalLength;
    }

    internal static class EntropyDecoder
    {
        public const int MaxOutputSize = 256 * 1024;
        private static readonly int[] BasePrefix =
        {
            0, 0, 2, 6, 14, 30, 62, 126, 254, 510, 766, 1022
        };

        public static EntropyChunk ParseChunk(
            byte[] data, int offset, int end)
        {
            if (offset < 0 || offset >= end)
            {
                throw new OodleFormatException("truncated entropy chunk");
            }

            int first = data[offset];
            int type = (first >> 4) & 7;
            EntropyChunk result = new EntropyChunk();
            result.Type = type;

            if (type == 0)
            {
                if (first >= 0x80)
                {
                    Require(offset, end, 2);
                    result.HeaderSize = 2;
                    result.PayloadLength =
                        ((first << 8) | data[offset + 1]) & 0xFFF;
                }
                else
                {
                    Require(offset, end, 3);
                    result.HeaderSize = 3;
                    result.PayloadLength = ReadUInt24(data, offset);
                    if ((result.PayloadLength & ~0x3FFFF) != 0)
                    {
                        throw new OodleFormatException(
                            "invalid direct entropy length "
                            + result.PayloadLength
                            + " at " + offset);
                    }
                }
                result.OutputLength = result.PayloadLength;
            }
            else
            {
                int sourceLength;
                int outputLength;
                if (first >= 0x80)
                {
                    Require(offset, end, 3);
                    int bits = ReadUInt24(data, offset);
                    sourceLength = bits & 0x3FF;
                    outputLength =
                        sourceLength + ((bits >> 10) & 0x3FF) + 1;
                    result.HeaderSize = 3;
                }
                else
                {
                    Require(offset, end, 5);
                    int bits = ReadUInt32BigEndian(data, offset + 1);
                    sourceLength = bits & 0x3FFFF;
                    outputLength =
                        (((bits >> 18) | (first << 14)) & 0x3FFFF) + 1;
                    if (sourceLength >= outputLength)
                    {
                        throw new OodleFormatException(
                            "invalid compressed entropy lengths");
                    }
                    result.HeaderSize = 5;
                }

                result.PayloadLength = sourceLength;
                result.OutputLength = outputLength;
            }

            result.PayloadOffset = offset + result.HeaderSize;
            result.TotalLength = result.HeaderSize + result.PayloadLength;
            if (result.PayloadOffset < offset
                || result.PayloadOffset > end
                || result.PayloadLength > end - result.PayloadOffset)
            {
                throw new OodleFormatException("truncated entropy payload");
            }
            if (result.OutputLength < 0
                || result.OutputLength > MaxOutputSize)
            {
                throw new OodleFormatException(
                    "entropy output exceeds 256 KiB");
            }
            return result;
        }

        public static byte[] DecodeChunk(
            byte[] data, int offset, int end, out int totalLength)
        {
            EntropyChunk chunk = ParseChunk(data, offset, end);
            totalLength = chunk.TotalLength;
            byte[] output = new byte[chunk.OutputLength];
            DecodeChunkBody(data, chunk, output, 0);
            return output;
        }

        public static void DecodeChunkInto(
            byte[] data,
            int offset,
            int end,
            byte[] destination,
            int destinationOffset,
            out int decodedLength)
        {
            EntropyChunk chunk = ParseChunk(data, offset, end);
            if (destinationOffset < 0
                || chunk.OutputLength
                    > destination.Length - destinationOffset)
            {
                throw new OodleFormatException(
                    "entropy destination is too small");
            }
            DecodeChunkBody(data, chunk, destination, destinationOffset);
            decodedLength = chunk.OutputLength;
        }

        private static void DecodeChunkBody(
            byte[] data,
            EntropyChunk chunk,
            byte[] destination,
            int destinationOffset)
        {
            switch (chunk.Type)
            {
                case 0:
                    Buffer.BlockCopy(
                        data,
                        chunk.PayloadOffset,
                        destination,
                        destinationOffset,
                        chunk.PayloadLength);
                    return;
                case 4:
                    DecodeHuffmanSplit(
                        data, chunk, destination, destinationOffset);
                    return;
                default:
                    throw new OodleFormatException(
                        "unsupported entropy mode " + chunk.Type);
            }
        }

        private static void DecodeHuffmanSplit(
            byte[] data,
            EntropyChunk chunk,
            byte[] destination,
            int destinationOffset)
        {
            int end = chunk.PayloadOffset + chunk.PayloadLength;
            MsbBitReader bits =
                new MsbBitReader(data, chunk.PayloadOffset, end);
            bits.Refill();

            bool legacy = !bits.ReadBitNoRefill();
            bool modern = false;
            if (!legacy)
            {
                modern = !bits.ReadBitNoRefill();
                if (!modern)
                {
                    throw new OodleFormatException(
                        "invalid Huffman code-length mode");
                }
            }

            byte[] rawSymbols = new byte[1280];
            int[] prefixEnd = (int[])BasePrefix.Clone();
            int symbolCount;
            int payloadPosition;
            int payloadBitPosition;
            if (legacy)
            {
                symbolCount = ReadLegacySparseLengths(
                    bits, rawSymbols, prefixEnd);
                payloadPosition = bits.Position;
                payloadBitPosition = bits.BitPosition;
            }
            else
            {
                symbolCount = ReadModernLengths(
                    data,
                    end,
                    bits,
                    rawSymbols,
                    prefixEnd,
                    out payloadPosition,
                    out payloadBitPosition);
            }

            int compressedStart =
                payloadPosition - ((24 - payloadBitPosition) / 8);
            if (compressedStart < chunk.PayloadOffset
                || compressedStart > end)
            {
                throw new OodleFormatException(
                    "invalid Huffman payload position "
                    + compressedStart
                    + " position=" + payloadPosition
                    + " bit=" + payloadBitPosition);
            }

            if (symbolCount == 1)
            {
                for (int i = 0; i < chunk.OutputLength; i++)
                {
                    destination[destinationOffset + i] = rawSymbols[0];
                }
                return;
            }

            HuffmanCodebook codebook =
                HuffmanCodebook.FromLengths(rawSymbols, prefixEnd);
            DecodeSplitStreams(
                data,
                compressedStart,
                end,
                destination,
                destinationOffset,
                chunk.OutputLength,
                codebook);
        }

        private static int ReadLegacySparseLengths(
            MsbBitReader bits,
            byte[] symbols,
            int[] prefixEnd)
        {
            if (bits.ReadBitNoRefill())
            {
                throw new OodleFormatException(
                    "legacy run-length Huffman tables are unsupported");
            }

            int count = bits.ReadBitsNoRefill(8);
            if (count == 0)
            {
                throw new OodleFormatException(
                    "empty sparse Huffman table");
            }
            if (count == 1)
            {
                symbols[0] = (byte)bits.ReadBitsNoRefill(8);
                return 1;
            }

            int lengthBits = bits.ReadBitsNoRefill(3);
            if (lengthBits > 4)
            {
                throw new OodleFormatException(
                    "invalid sparse Huffman length width");
            }
            for (int i = 0; i < count; i++)
            {
                bits.Refill();
                byte symbol = (byte)bits.ReadBitsNoRefill(8);
                int length =
                    bits.ReadBitsNoRefillZero(lengthBits) + 1;
                if (length < 1 || length > 11)
                {
                    throw new OodleFormatException(
                        "invalid Huffman code length " + length);
                }
                int slot = prefixEnd[length];
                if (slot >= symbols.Length)
                {
                    throw new OodleFormatException(
                        "Huffman symbol table overflow");
                }
                symbols[slot] = symbol;
                prefixEnd[length] = slot + 1;
            }
            return count;
        }

        private static int ReadModernLengths(
            byte[] data,
            int end,
            MsbBitReader bits,
            byte[] symbols,
            int[] prefixEnd,
            out int finalPosition,
            out int finalBitPosition)
        {
            int forcedBits = bits.ReadBitsNoRefill(2);
            int symbolCount = bits.ReadBitsNoRefill(8) + 1;
            int fluff = bits.ReadFluff(symbolCount);
            int valueCount = symbolCount + fluff;
            if (valueCount > 512)
            {
                throw new OodleFormatException(
                    "modern Huffman length table is too large");
            }

            int ricePosition =
                bits.Position - ((24 - bits.BitPosition + 7) >> 3);
            int riceBitPosition =
                ((bits.BitPosition - 24) & 7);
            RiceBitCursor rice =
                new RiceBitCursor(
                    data, end, ricePosition, riceBitPosition);

            int[] rawLengths = new int[valueCount];
            DecodeRiceLengths(rice, rawLengths);
            DecodeRiceRemainders(
                rice, rawLengths, symbolCount, forcedBits);

            MsbBitReader rangeBits =
                new MsbBitReader(data, rice.Position, end);
            rangeBits.Refill();
            rangeBits.Skip(rice.BitPosition);

            int runningSum = 0x1E;
            for (int i = 0; i < symbolCount; i++)
            {
                int raw = rawLengths[i];
                int delta = (raw >> 1) ^ -(raw & 1);
                int length = delta + (runningSum >> 2) + 1;
                if (length < 1 || length > 11)
                {
                    throw new OodleFormatException(
                        "invalid modern Huffman length " + length
                        + " raw=" + raw
                        + " running=" + runningSum
                        + " index=" + i
                        + " symbols=" + symbolCount
                        + " fluff=" + fluff);
                }
                rawLengths[i] = length;
                runningSum += delta;
            }

            int[] rangeSymbols = ConvertToRanges(
                symbolCount, fluff, rawLengths, rangeBits);
            int sourceIndex = 0;
            for (int rangeIndex = 0;
                rangeIndex < rangeSymbols.Length;
                rangeIndex += 2)
            {
                int symbol = rangeSymbols[rangeIndex];
                int count = rangeSymbols[rangeIndex + 1];
                for (int i = 0; i < count; i++)
                {
                    int length = rawLengths[sourceIndex++];
                    int slot = prefixEnd[length];
                    if (slot >= symbols.Length)
                    {
                        throw new OodleFormatException(
                            "Huffman symbol table overflow");
                    }
                    symbols[slot] = (byte)symbol;
                    prefixEnd[length] = slot + 1;
                    symbol++;
                }
            }
            if (sourceIndex != symbolCount)
            {
                throw new OodleFormatException(
                    "Huffman range symbol mismatch");
            }
            finalPosition = rangeBits.Position;
            finalBitPosition = rangeBits.BitPosition;
            return symbolCount;
        }

        private static void DecodeRiceLengths(
            RiceBitCursor cursor, int[] destination)
        {
            for (int i = 0; i < destination.Length; i++)
            {
                int zeros = 0;
                while (cursor.ReadBit() == 0)
                {
                    zeros++;
                    if (zeros > 0x10000)
                    {
                        throw new OodleFormatException(
                            "Rice unary run is too long");
                    }
                }
                destination[i] = zeros;
            }
        }

        private static void DecodeRiceRemainders(
            RiceBitCursor cursor,
            int[] values,
            int count,
            int bitCount)
        {
            if (bitCount == 0)
            {
                return;
            }
            if (bitCount < 1 || bitCount > 4)
            {
                throw new OodleFormatException(
                    "invalid Rice remainder width " + bitCount);
            }
            for (int i = 0; i < count; i++)
            {
                values[i] =
                    (values[i] << bitCount)
                    | cursor.ReadBits(bitCount);
            }
        }

        private static int[] ConvertToRanges(
            int symbolCount,
            int fluff,
            int[] lengths,
            MsbBitReader bits)
        {
            int symbolIndex = 0;
            int lengthIndex = symbolCount;
            if ((fluff & 1) != 0)
            {
                bits.Refill();
                int width = lengths[lengthIndex++];
                if (width >= 8)
                {
                    throw new OodleFormatException(
                        "invalid initial Huffman range width");
                }
                symbolIndex =
                    bits.ReadBitsNoRefill(width + 1)
                    + (1 << (width + 1)) - 1;
            }

            int usedSymbols = 0;
            int rangeCount = fluff >> 1;
            int[] result = new int[(rangeCount + 1) * 2];
            int resultIndex = 0;
            for (int i = 0; i < rangeCount; i++)
            {
                bits.Refill();
                int countWidth = lengths[lengthIndex++];
                if (countWidth >= 9)
                {
                    throw new OodleFormatException(
                        "invalid Huffman range count width");
                }
                int count =
                    bits.ReadBitsNoRefillZero(countWidth)
                    + (1 << countWidth);

                bits.Refill();
                int spaceWidth = lengths[lengthIndex++];
                if (spaceWidth >= 8)
                {
                    throw new OodleFormatException(
                        "invalid Huffman range space width");
                }
                int space =
                    bits.ReadBitsNoRefill(spaceWidth + 1)
                    + (1 << (spaceWidth + 1)) - 1;

                result[resultIndex++] = symbolIndex;
                result[resultIndex++] = count;
                usedSymbols += count;
                symbolIndex += count + space;
            }

            if (symbolIndex < 0 || symbolIndex >= 256)
            {
                throw new OodleFormatException(
                    "Huffman range symbol out of range "
                    + symbolIndex
                    + " ranges=" + rangeCount
                    + " fluff=" + fluff
                    + " used=" + usedSymbols);
            }
            if (usedSymbols > symbolCount)
            {
                throw new OodleFormatException(
                    "Huffman ranges exceed symbol count");
            }
            result[resultIndex++] = symbolIndex;
            result[resultIndex++] = symbolCount - usedSymbols;
            if (resultIndex != result.Length)
            {
                throw new OodleFormatException(
                    "Huffman range table mismatch");
            }
            return result;
        }

        private static void DecodeSplitStreams(
            byte[] data,
            int source,
            int sourceEnd,
            byte[] destination,
            int destinationOffset,
            int outputLength,
            HuffmanCodebook codebook)
        {
            if (sourceEnd - source < 6)
            {
                throw new OodleFormatException(
                    "truncated split Huffman header");
            }

            int halfLength = (outputLength + 1) >> 1;
            int middleDelta = ReadUInt24LittleEndian(data, source);
            int middle = source + 3 + middleDelta;
            if (middle < source + 3
                || middle > sourceEnd
                || sourceEnd - middle < 3)
            {
                throw new OodleFormatException(
                    "invalid split Huffman midpoint "
                    + middleDelta
                    + " source=" + source
                    + " end=" + sourceEnd);
            }

            int leftSplit = ReadUInt16(data, source + 3);
            int leftStart = source + 5;
            if (leftSplit > middle - leftStart)
            {
                throw new OodleFormatException(
                    "invalid left Huffman split");
            }

            int rightSplit = ReadUInt16(data, middle);
            int rightStart = middle + 2;
            if (rightSplit > sourceEnd - rightStart)
            {
                throw new OodleFormatException(
                    "invalid right Huffman split "
                    + rightSplit
                    + " at " + middle
                    + " source=" + source);
            }

            DecodeThreeStreams(
                data,
                leftStart,
                leftStart + leftSplit,
                middle,
                destination,
                destinationOffset,
                halfLength,
                codebook);

            DecodeThreeStreams(
                data,
                rightStart,
                rightStart + rightSplit,
                sourceEnd,
                destination,
                destinationOffset + halfLength,
                outputLength - halfLength,
                codebook);
        }

        private static void DecodeThreeStreams(
            byte[] data,
            int firstStart,
            int firstEnd,
            int segmentEnd,
            byte[] destination,
            int destinationOffset,
            int outputLength,
            HuffmanCodebook codebook)
        {
            if (firstEnd < firstStart
                || segmentEnd < firstEnd
                || segmentEnd > data.Length)
            {
                throw new OodleFormatException(
                    "invalid interleaved Huffman streams");
            }

            HuffmanBitCursor forwardA =
                new HuffmanBitCursor(data, firstStart, firstEnd, false);
            HuffmanBitCursor forwardB =
                new HuffmanBitCursor(data, firstEnd, segmentEnd, false);
            HuffmanBitCursor backwardC =
                new HuffmanBitCursor(data, firstEnd, segmentEnd, true);

            int written = 0;
            while (written < outputLength)
            {
                destination[destinationOffset + written++] =
                    codebook.ReadSymbol(forwardA);
                if (written >= outputLength)
                {
                    break;
                }
                destination[destinationOffset + written++] =
                    codebook.ReadSymbol(backwardC);
                if (written >= outputLength)
                {
                    break;
                }
                destination[destinationOffset + written++] =
                    codebook.ReadSymbol(forwardB);
            }
        }

        private static void Require(int offset, int end, int count)
        {
            if (offset < 0 || count > end - offset)
            {
                throw new OodleFormatException(
                    "truncated entropy header");
            }
        }

        private static int ReadUInt16(byte[] data, int offset)
        {
            return data[offset] | (data[offset + 1] << 8);
        }

        private static int ReadUInt24(byte[] data, int offset)
        {
            return (data[offset] << 16)
                | (data[offset + 1] << 8)
                | data[offset + 2];
        }

        private static int ReadUInt24LittleEndian(byte[] data, int offset)
        {
            return data[offset]
                | (data[offset + 1] << 8)
                | (data[offset + 2] << 16);
        }

        private static int ReadUInt32BigEndian(byte[] data, int offset)
        {
            return (data[offset] << 24)
                | (data[offset + 1] << 16)
                | (data[offset + 2] << 8)
                | data[offset + 3];
        }
    }
}
