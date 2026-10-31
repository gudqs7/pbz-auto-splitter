# PBZ Mermaid Format Note

Status: draft for implementation and independent verification.

This note describes only the byte-level contract exercised by Phantom Blade
Zero save records. All multi-byte integers are little-endian unless explicitly
marked big-endian.

## 1. Selection

`PBZS` record payloads are passed to `OodleLZ_Decompress`. The first chunk
selector is `9` (Mermaid) for every compressed `__Advanced__` fixture in the
current corpus. The decoder must not attempt to implement other Oodle families.

## 2. Oodle block framing

The output is divided into 256 KiB blocks. Each block starts with a two-byte
header:

- low nibble of byte 0 must be `0x0C`
- bits 4..5 of byte 0 are reserved and must be zero
- bit 6 means stored/uncompressed
- bit 7 requests decoder restart
- byte 1 bits 0..6 select the decoder; Mermaid is `0x0A`
- byte 1 bit 7 means checksums follow

For a compressed 256 KiB block, a three-byte big-endian quantum header follows:

- `sizeMinusOne = value & 0x3FFFF`
- value `0x3FFFF` selects a special quantum and is not accepted in v1
- otherwise the compressed payload length is `sizeMinusOne + 1`

A stored block has no quantum header; the next `min(256 KiB, remaining)` bytes
are copied directly.

## 3. Mermaid quantum header

The compressed Mermaid payload begins with an entropy chunk describing the
literal table. A 256 KiB Mermaid quantum is decoded as a pair of 128 KiB
sub-blocks with shared history.

For a normal compressed sub-block, the first three bytes are big-endian
`chunkSelector`:

- bit 23 clear: one direct entropy chunk fills the sub-block
- bit 23 set: low 19 bits are the compressed LZ payload size
- bits 19..22 are the Mermaid mode

PBZ fixtures use one 256 KiB Oodle block, so the Mermaid quantum is one
sub-block whose output size is the declared uncompressed record size.

## 4. Mermaid table

When decoding at output offset zero, the first eight bytes of the LZ payload
are copied directly to output. This is the literal JSON prefix observed in all
compressed PBZ fixtures.

The remaining stream groups are ordered as follows:

1. literal byte stream, encoded with the shared entropy chunk format
2. command/flag stream, encoded with the shared entropy chunk format
3. optional two-byte split point for the second 128 KiB sub-block
4. 16-bit recent-offset count
5. either packed 16-bit offsets, or two entropy streams (high and low bytes)
   when the count is `0xFFFF`
6. a three-byte far-offset count pair
7. packed 24-bit far offsets for each stream
8. the length-control stream, consumed by the command phase

The PBZ corpus uses `count == 0xFFFF`; high bytes are Huffman split type 4 and
low bytes are a direct entropy chunk.

## 5. Entropy chunk envelope

Each entropy chunk starts with a type nibble `(firstByte >> 4) & 7`.

- type 0: direct bytes
  - first byte `>= 0x80`: two-byte header, length = low 12 bits
  - otherwise: three-byte header, length = header value, high bits must be zero
- type 2/4: Huffman variants
- type 1, 3, 5: tANS, RLE, and recursive variants

For types 2..5, the header also declares compressed and decoded lengths:

- short form (`firstByte >= 0x80`):
  - 24-bit big-endian value
  - compressed length = value & 0x3FF
  - decoded length = compressed length + ((value >> 10) & 0x3FF) + 1
- long form:
  - 40-bit big-endian value
  - compressed length = low 18 bits after the first byte
  - decoded length = combined 18-bit delta + 1

The first release accepts type 0 and split Huffman type 4. Other types return
`UnsupportedEntropyMode` so that fallback remains safe.

## 6. Split Huffman type 4

Type 4 is the two-way split Huffman layout:

1. Decode the canonical code lengths from the beginning of the chunk.
2. Read a three-byte split point `mid`.
3. Read a two-byte left split point `left`.
4. At `mid`, read a two-byte right split point `right`.
5. Decode the first half using three interleaved bit streams.
6. Decode the second half the same way.

For each half:

- forward stream A: from segment start to the first split
- forward stream B: from the first split to segment end
- backward stream C: from segment end toward the first split, byte-wise

Each stream consumes bits least-significant-bit first within each byte.
Symbols are emitted in repeating order A, C, B until the half is full.

The code-length alphabet uses the legacy compact form:

- first bit 0: sparse literal-length list
- first bit 1: run-length coded lengths for all 256 byte symbols

For PBZ saves the modern path is used:

1. two forced remainder bits
2. eight bits of symbol count minus one
3. a truncated-binary "fluff" count
4. quotient codes, where each value is a run of zero bits terminated by one
5. one forced-width remainder appended to each quotient
6. range descriptors that map code lengths to byte symbols

Canonical code values begin at:

```
length 1..11:
0, 2, 6, 14, 30, 62, 126, 254, 510, 766, 1022
```

Symbols assigned to the same length occupy consecutive canonical values.

## 7. Mermaid command phase

The command byte drives literal and match copies:

- `cmd >= 24`:
  - copy `cmd & 7` literals
  - if bit 7 is clear, pop the next 16-bit recent offset
  - copy `(cmd >> 3) & 0xF` bytes from the recent offset
- `cmd == 0`: extended literal run
- `cmd == 1`: recent-offset match with extended length
- `cmd == 2`: far-offset match with extended length
- `3..23`: far-offset match of length `cmd + 5`

Extended length is the next length-stream byte. If greater than 251, add
`4 * nextLittleEndianUInt16` and advance by two more bytes. Base lengths are
64 for literals, 91 for recent matches, and 29 for far matches.

The initial recent offset is `-8`. At output offset zero, the first sub-block
starts eight bytes into its destination because the literal prefix was copied
directly. After the command stream is exhausted, remaining bytes in the
sub-block are literals.

Mode `0` uses additive literal reconstruction: each literal is added to the
byte at the current recent offset. Mode `1` copies literal bytes directly.
PBZ `__Advanced__` records use mode `1`.

## 8. Validation rules

The decoder rejects:

- non-256-KiB public block sizes
- non-Mermaid selector values
- checksum-enabled blocks
- special quantum values
- entropy types outside `{0, 4}`
- truncated or overrunning streams
- invalid Huffman trees
- output writes outside the declared destination
- non-zero remaining input

## 9. Known open items

- Checksum semantics
- special quanta (whole-block match, memset)
- type 1/2/3/5 entropy variants
- multiple output blocks larger than 256 KiB
- forward compatibility with newer PBZ Oodle builds
