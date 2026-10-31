using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace PBZ
{
    /// <summary>
    /// Streams the two BossRecord maps needed by the splitter. Unknown JSON
    /// values are skipped instead of materialized as dictionaries.
    /// </summary>
    internal sealed class JsonBossParser
    {
        private readonly string _text;
        private int _position;

        private JsonBossParser(string text)
        {
            _text = text;
        }

        public static SortedDictionary<string, int> ExtractBossKills(string text)
        {
            if (text == null)
            {
                throw new ArgumentNullException("text");
            }

            JsonBossParser parser = new JsonBossParser(text);
            parser.SkipWhitespace();
            parser.Expect('{');
            parser.SkipWhitespace();

            if (parser.Peek() == '}')
            {
                throw new InvalidDataException("BossRecord missing from Advanced JSON");
            }

            SortedDictionary<string, int> result = null;
            while (true)
            {
                string key = parser.ReadString();
                parser.SkipWhitespace();
                parser.Expect(':');
                parser.SkipWhitespace();

                if (string.Equals(key, "BossRecord", StringComparison.Ordinal))
                {
                    result = parser.ReadBossRecord();
                }
                else
                {
                    parser.SkipValue();
                }
                parser.SkipWhitespace();
                char separator = parser.Peek();
                if (separator == ',')
                {
                    parser._position++;
                    parser.SkipWhitespace();
                    continue;
                }
                if (separator == '}')
                {
                    parser._position++;
                    break;
                }
                throw new FormatException(
                    "expected ',' or '}' at " + parser._position);
            }

            parser.SkipWhitespace();
            if (parser._position != parser._text.Length)
            {
                throw new FormatException(
                    "trailing JSON at offset " + parser._position);
            }
            if (result == null)
            {
                throw new InvalidDataException(
                    "BossRecord missing from Advanced JSON");
            }
            return result;
        }

        private SortedDictionary<string, int> ReadBossRecord()
        {
            SortedDictionary<string, int> result =
                new SortedDictionary<string, int>(StringComparer.Ordinal);
            Expect('{');
            SkipWhitespace();
            if (Peek() == '}')
            {
                _position++;
                return result;
            }

            while (true)
            {
                string bossKey = ReadString();
                SkipWhitespace();
                Expect(':');
                SkipWhitespace();
                result[bossKey] = ReadBossValue();
                SkipWhitespace();
                char separator = Peek();
                if (separator == ',')
                {
                    _position++;
                    SkipWhitespace();
                    continue;
                }
                if (separator == '}')
                {
                    _position++;
                    return result;
                }
                throw new FormatException(
                    "expected ',' or '}' at " + _position);
            }
        }

        private int ReadBossValue()
        {
            int total = 0;
            Expect('{');
            SkipWhitespace();
            if (Peek() == '}')
            {
                _position++;
                return total;
            }

            while (true)
            {
                string key = ReadString();
                SkipWhitespace();
                Expect(':');
                SkipWhitespace();
                if (string.Equals(key, "Records", StringComparison.Ordinal))
                {
                    total += ReadRecords();
                }
                else
                {
                    SkipValue();
                }
                SkipWhitespace();
                char separator = Peek();
                if (separator == ',')
                {
                    _position++;
                    SkipWhitespace();
                    continue;
                }
                if (separator == '}')
                {
                    _position++;
                    return total;
                }
                throw new FormatException(
                    "expected ',' or '}' at " + _position);
            }
        }

        private int ReadRecords()
        {
            int total = 0;
            Expect('{');
            SkipWhitespace();
            if (Peek() == '}')
            {
                _position++;
                return total;
            }

            while (true)
            {
                ReadString();
                SkipWhitespace();
                Expect(':');
                SkipWhitespace();
                total += ReadRecord();
                SkipWhitespace();
                char separator = Peek();
                if (separator == ',')
                {
                    _position++;
                    SkipWhitespace();
                    continue;
                }
                if (separator == '}')
                {
                    _position++;
                    return total;
                }
                throw new FormatException(
                    "expected ',' or '}' at " + _position);
            }
        }

        private int ReadRecord()
        {
            int kills = 0;
            Expect('{');
            SkipWhitespace();
            if (Peek() == '}')
            {
                _position++;
                return kills;
            }

            while (true)
            {
                string key = ReadString();
                SkipWhitespace();
                Expect(':');
                SkipWhitespace();
                if (string.Equals(key, "KillCount", StringComparison.Ordinal))
                {
                    kills = ReadInt32();
                }
                else
                {
                    SkipValue();
                }
                SkipWhitespace();
                char separator = Peek();
                if (separator == ',')
                {
                    _position++;
                    SkipWhitespace();
                    continue;
                }
                if (separator == '}')
                {
                    _position++;
                    return kills;
                }
                throw new FormatException(
                    "expected ',' or '}' at " + _position);
            }
        }

        private int ReadInt32()
        {
            int start = _position;
            if (Peek() == '-')
            {
                _position++;
            }
            while (_position < _text.Length && char.IsDigit(_text[_position]))
            {
                _position++;
            }
            if (_position == start)
            {
                throw new FormatException(
                    "expected integer at " + _position);
            }

            int value;
            if (!int.TryParse(
                _text.Substring(start, _position - start),
                NumberStyles.Integer,
                CultureInfo.InvariantCulture,
                out value))
            {
                throw new FormatException(
                    "invalid integer at " + start);
            }
            return value;
        }

        private void SkipValue()
        {
            SkipWhitespace();
            if (_position >= _text.Length)
            {
                throw new FormatException("unexpected end of JSON");
            }

            char value = _text[_position];
            if (value == '"')
            {
                ReadString();
                return;
            }
            if (value == '{')
            {
                SkipObject();
                return;
            }
            if (value == '[')
            {
                SkipArray();
                return;
            }
            if (value == 't')
            {
                ExpectLiteral("true");
                return;
            }
            if (value == 'f')
            {
                ExpectLiteral("false");
                return;
            }
            if (value == 'n')
            {
                ExpectLiteral("null");
                return;
            }
            if (value == '-' || char.IsDigit(value))
            {
                SkipNumber();
                return;
            }
            throw new FormatException(
                "unexpected JSON character '" + value + "' at " + _position);
        }

        private void SkipObject()
        {
            Expect('{');
            SkipWhitespace();
            if (Peek() == '}')
            {
                _position++;
                return;
            }
            while (true)
            {
                ReadString();
                SkipWhitespace();
                Expect(':');
                SkipValue();
                SkipWhitespace();
                char separator = Peek();
                if (separator == ',')
                {
                    _position++;
                    SkipWhitespace();
                    continue;
                }
                if (separator == '}')
                {
                    _position++;
                    return;
                }
                throw new FormatException(
                    "expected ',' or '}' at " + _position);
            }
        }

        private void SkipArray()
        {
            Expect('[');
            SkipWhitespace();
            if (Peek() == ']')
            {
                _position++;
                return;
            }
            while (true)
            {
                SkipValue();
                SkipWhitespace();
                char separator = Peek();
                if (separator == ',')
                {
                    _position++;
                    SkipWhitespace();
                    continue;
                }
                if (separator == ']')
                {
                    _position++;
                    return;
                }
                throw new FormatException(
                    "expected ',' or ']' at " + _position);
            }
        }

        private void SkipNumber()
        {
            int start = _position;
            while (_position < _text.Length)
            {
                char value = _text[_position];
                if (char.IsDigit(value)
                    || value == '-'
                    || value == '+'
                    || value == '.'
                    || value == 'e'
                    || value == 'E')
                {
                    _position++;
                    continue;
                }
                break;
            }
            if (_position == start)
            {
                throw new FormatException("expected number at " + start);
            }
        }

        private string ReadString()
        {
            SkipWhitespace();
            Expect('"');
            StringBuilder value = new StringBuilder();
            while (_position < _text.Length)
            {
                char current = _text[_position++];
                if (current == '"')
                {
                    return value.ToString();
                }
                if (current != '\\')
                {
                    value.Append(current);
                    continue;
                }
                if (_position >= _text.Length)
                {
                    throw new FormatException("unterminated escape");
                }
                char escape = _text[_position++];
                switch (escape)
                {
                    case '"': value.Append('"'); break;
                    case '\\': value.Append('\\'); break;
                    case '/': value.Append('/'); break;
                    case 'b': value.Append('\b'); break;
                    case 'f': value.Append('\f'); break;
                    case 'n': value.Append('\n'); break;
                    case 'r': value.Append('\r'); break;
                    case 't': value.Append('\t'); break;
                    case 'u':
                        if (_position + 4 > _text.Length)
                        {
                            throw new FormatException(
                                "truncated unicode escape");
                        }
                        value.Append((char)ushort.Parse(
                            _text.Substring(_position, 4),
                            NumberStyles.HexNumber,
                            CultureInfo.InvariantCulture));
                        _position += 4;
                        break;
                    default:
                        throw new FormatException(
                            "invalid escape '\\" + escape + "'");
                }
            }
            throw new FormatException("unterminated string");
        }

        private void SkipWhitespace()
        {
            while (_position < _text.Length && char.IsWhiteSpace(_text[_position]))
            {
                _position++;
            }
        }

        private void Expect(char expected)
        {
            if (Peek() != expected)
            {
                throw new FormatException(
                    "expected '" + expected + "' at " + _position);
            }
            _position++;
        }

        private void ExpectLiteral(string literal)
        {
            if (_position + literal.Length > _text.Length
                || string.CompareOrdinal(
                    _text, _position, literal, 0, literal.Length) != 0)
            {
                throw new FormatException(
                    "expected '" + literal + "' at " + _position);
            }
            _position += literal.Length;
        }

        private char Peek()
        {
            return _position < _text.Length ? _text[_position] : '\0';
        }
    }
}
