using System;

namespace OodleCleanRoom
{
    internal sealed class MsbBitReader
    {
        private readonly byte[] _data;
        private readonly int _end;
        private int _position;
        private int _bitPosition;
        private uint _bits;

        public MsbBitReader(byte[] data, int position, int end)
        {
            _data = data;
            _position = position;
            _end = end;
            _bitPosition = 24;
        }

        public int Position
        {
            get { return _position; }
        }

        public int BitPosition
        {
            get { return _bitPosition; }
        }

        public void Refill()
        {
            if (_bitPosition > 24)
            {
                throw new OodleFormatException("bit reader refill overrun");
            }

            while (_bitPosition > 0)
            {
                if (_position < _end)
                {
                    _bits |= (uint)_data[_position] << _bitPosition;
                }
                _bitPosition -= 8;
                _position++;
            }
        }

        public bool ReadBit()
        {
            Refill();
            return ReadBitNoRefill();
        }

        public bool ReadBitNoRefill()
        {
            bool result = (_bits & 0x80000000u) != 0;
            _bits <<= 1;
            _bitPosition++;
            return result;
        }

        public int ReadBitsNoRefill(int count)
        {
            if (count < 0 || count > 31)
            {
                throw new OodleFormatException("invalid bit count " + count);
            }
            if (count == 0)
            {
                return 0;
            }

            int result = (int)(_bits >> (32 - count));
            _bits <<= count;
            _bitPosition += count;
            return result;
        }

        public int ReadBitsNoRefillZero(int count)
        {
            if (count == 0)
            {
                return 0;
            }
            return ReadBitsNoRefill(count);
        }

        public int LeadingZeros()
        {
            return LeadingZeroCount(_bits);
        }

        public int ReadFluff(int symbolCount)
        {
            if (symbolCount == 256)
            {
                return 0;
            }
            if (symbolCount <= 0 || symbolCount > 256)
            {
                throw new OodleFormatException(
                    "invalid Huffman symbol count " + symbolCount);
            }

            int x = 257 - symbolCount;
            if (x > symbolCount)
            {
                x = symbolCount;
            }
            x *= 2;

            int y = 0;
            int t = x - 1;
            while (t > 0)
            {
                y++;
                t >>= 1;
            }

            uint value = _bits >> (32 - y);
            uint threshold = (1u << y) - (uint)x;
            if ((value >> 1) >= threshold)
            {
                _bits <<= y;
                _bitPosition += y;
                return (int)(value - threshold);
            }

            _bits <<= y - 1;
            _bitPosition += y - 1;
            return (int)(value >> 1);
        }

        public void Skip(int count)
        {
            if (count < 0 || count > 31)
            {
                throw new OodleFormatException("invalid skip count " + count);
            }
            _bits <<= count;
            _bitPosition += count;
        }

        internal static int LeadingZeroCount(uint value)
        {
            if (value == 0)
            {
                return 32;
            }
            int count = 0;
            while ((value & 0x80000000u) == 0)
            {
                count++;
                value <<= 1;
            }
            return count;
        }
    }

    internal sealed class RiceBitCursor
    {
        private readonly byte[] _data;
        private readonly int _end;
        private long _bitIndex;

        public RiceBitCursor(byte[] data, int end, int position, int bitPosition)
        {
            if (position < 0 || position > end)
            {
                throw new OodleFormatException("Rice cursor out of range");
            }
            if (bitPosition < 0 || bitPosition > 7)
            {
                throw new OodleFormatException("Rice bit position out of range");
            }
            _data = data;
            _end = end;
            _bitIndex = ((long)position << 3) + bitPosition;
        }

        public int Position
        {
            get { return (int)(_bitIndex >> 3); }
        }

        public int BitPosition
        {
            get { return (int)(_bitIndex & 7); }
        }

        public int ReadBit()
        {
            int result = PeekBit();
            Advance();
            return result;
        }

        public int PeekBit()
        {
            if (_bitIndex >= (long)_end << 3)
            {
                throw new OodleFormatException("truncated Rice bit stream");
            }
            int byteIndex = (int)(_bitIndex >> 3);
            int bitIndex = 7 - (int)(_bitIndex & 7);
            return (_data[byteIndex] >> bitIndex) & 1;
        }

        public void Advance()
        {
            if (_bitIndex >= (long)_end << 3)
            {
                throw new OodleFormatException("truncated Rice bit stream");
            }
            _bitIndex++;
        }

        public int ReadBits(int count)
        {
            int value = 0;
            for (int i = 0; i < count; i++)
            {
                value = (value << 1) | ReadBit();
            }
            return value;
        }
    }
}
