using System;

namespace OodleCleanRoom
{
    internal sealed class HuffmanCodebook
    {
        private static readonly int[] BasePrefix =
        {
            0, 0, 2, 6, 14, 30, 62, 126, 254, 510, 766, 1022
        };

        private readonly byte[] _lengthsByCode = new byte[2048];
        private readonly byte[] _symbolsByCode = new byte[2048];

        private HuffmanCodebook()
        {
        }

        public static HuffmanCodebook FromLengths(
            byte[] symbols, int[] prefixEnd)
        {
            HuffmanCodebook result = new HuffmanCodebook();
            byte[] sequentialLengths = new byte[2048];
            byte[] sequentialSymbols = new byte[2048];
            int cursor = 0;

            for (int length = 1; length <= 10; length++)
            {
                int start = BasePrefix[length];
                int end = prefixEnd[length];
                if (end < start || end > 1280)
                {
                    throw new OodleFormatException(
                        "invalid Huffman prefix table");
                }

                int count = end - start;
                int step = 1 << (11 - length);
                if (count < 0 || count > 0x10000
                    || cursor + count * step > 2048)
                {
                    throw new OodleFormatException(
                        "invalid Huffman lookup table size");
                }
                for (int i = 0; i < count; i++)
                {
                    int destination = cursor + i * step;
                    for (int j = 0; j < step; j++)
                    {
                        sequentialLengths[destination + j] = (byte)length;
                        sequentialSymbols[destination + j] = symbols[start + i];
                    }
                }
                cursor += count * step;
            }

            int finalStart = BasePrefix[11];
            int finalEnd = prefixEnd[11];
            if (finalEnd < finalStart || finalEnd > 1280)
            {
                throw new OodleFormatException(
                    "invalid Huffman terminal prefix");
            }
            int finalCount = finalEnd - finalStart;
            if (cursor + finalCount != 2048)
            {
                throw new OodleFormatException(
                    "incomplete Huffman lookup table");
            }
            for (int i = 0; i < finalCount; i++)
            {
                sequentialLengths[cursor + i] = 11;
                sequentialSymbols[cursor + i] = symbols[finalStart + i];
            }

            for (int i = 0; i < 2048; i++)
            {
                int reversed = ReverseBits(i, 11);
                result._lengthsByCode[i] = sequentialLengths[reversed];
                result._symbolsByCode[i] = sequentialSymbols[reversed];
            }
            return result;
        }

        public byte ReadSymbol(HuffmanBitCursor cursor)
        {
            int value = cursor.PeekBits(11);
            int length = _lengthsByCode[value];
            if (length == 0)
            {
                throw new OodleFormatException("invalid Huffman symbol");
            }
            cursor.Advance(length);
            return _symbolsByCode[value];
        }

        private static int ReverseBits(int value, int count)
        {
            int result = 0;
            for (int i = 0; i < count; i++)
            {
                result = (result << 1) | (value & 1);
                value >>= 1;
            }
            return result;
        }
    }

    internal sealed class HuffmanBitCursor
    {
        private readonly byte[] _data;
        private readonly bool _backward;
        private int _byteIndex;
        private int _bitIndex;

        public HuffmanBitCursor(
            byte[] data, int start, int end, bool backward)
        {
            if (start < 0 || end < start || end > data.Length)
            {
                throw new OodleFormatException("Huffman stream out of range");
            }
            _data = data;
            _backward = backward;
            _byteIndex = backward ? end - 1 : start;
            _bitIndex = 0;
            Start = start;
            End = end;
        }

        public int Start { get; private set; }

        public int End { get; private set; }

        public int ReadBit()
        {
            if (_backward)
            {
                if (_byteIndex < Start)
                {
                    throw new OodleFormatException(
                        "truncated reverse Huffman stream");
                }
            }
            else if (_byteIndex >= End)
            {
                throw new OodleFormatException(
                    "truncated forward Huffman stream");
            }

            int bit = (_data[_byteIndex] >> _bitIndex) & 1;
            _bitIndex++;
            if (_bitIndex == 8)
            {
                _bitIndex = 0;
                _byteIndex += _backward ? -1 : 1;
            }
            return bit;
        }

        public int PeekBits(int count)
        {
            if (count < 0 || count > 24)
            {
                throw new OodleFormatException("invalid Huffman peek size");
            }
            int byteIndex = _byteIndex;
            int bitIndex = _bitIndex;
            int value = 0;
            for (int i = 0; i < count; i++)
            {
                bool available;
                if (_backward)
                {
                    available = byteIndex >= Start && byteIndex < End;
                }
                else
                {
                    available = byteIndex >= Start && byteIndex < End;
                }

                if (available)
                {
                    value |= ((_data[byteIndex] >> bitIndex) & 1) << i;
                }
                bitIndex++;
                if (bitIndex == 8)
                {
                    bitIndex = 0;
                    byteIndex += _backward ? -1 : 1;
                }
            }
            return value;
        }

        public void Advance(int count)
        {
            for (int i = 0; i < count; i++)
            {
                ReadBit();
            }
        }
    }
}
