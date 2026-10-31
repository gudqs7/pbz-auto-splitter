using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace PBZ
{
    public static partial class SaveReader
    {
        private static readonly byte[] KeyMaterialA = FromHex(
            "ec88a5760acdfb3b30d9f0b8ad07c52a"
            + "c6da79183761234af91e8b7108287c7b");
        private static readonly byte[] KeyMaterialB = FromHex(
            "f9295b795f2d1012bea564d9f9849443"
            + "acf07e18da4c34f0e6999f26e0d14256");

        private static IntPtr _aesAlgorithm = IntPtr.Zero;
        private static IntPtr _aesKey = IntPtr.Zero;

        private static byte[] DecryptRecord(byte[] blob)
        {
            if (blob.Length < RecordHeaderSize || !HasMagic(blob, 0))
            {
                throw new InvalidDataException("not a PBZS encrypted record");
            }
            if (blob[4] != 1)
            {
                throw new InvalidDataException(
                    "unsupported record version " + blob[4]);
            }
            if (blob[5] != 1)
            {
                throw new InvalidDataException(
                    "unsupported key id " + blob[5]);
            }

            byte[] nonce = new byte[12];
            byte[] tag = new byte[16];
            byte[] ciphertext = new byte[blob.Length - RecordHeaderSize];
            Buffer.BlockCopy(blob, 8, nonce, 0, 12);
            Buffer.BlockCopy(blob, 20, tag, 0, 16);
            Buffer.BlockCopy(
                blob, RecordHeaderSize, ciphertext, 0, ciphertext.Length);
            return AesGcmDecrypt(ciphertext, nonce, tag);
        }

        private static byte[] AesGcmDecrypt(
            byte[] ciphertext, byte[] nonce, byte[] tag)
        {
            EnsureAes();

            byte[] plaintext = new byte[ciphertext.Length];
            BcryptAuthInfo info = new BcryptAuthInfo();
            info.cbSize = Marshal.SizeOf(typeof(BcryptAuthInfo));
            info.dwInfoVersion = 1;

            GCHandle nonceHandle = default(GCHandle);
            GCHandle tagHandle = default(GCHandle);
            try
            {
                nonceHandle = GCHandle.Alloc(nonce, GCHandleType.Pinned);
                tagHandle = GCHandle.Alloc(tag, GCHandleType.Pinned);
                info.pbNonce = nonceHandle.AddrOfPinnedObject();
                info.cbNonce = nonce.Length;
                info.pbAuthData = IntPtr.Zero;
                info.cbAuthData = 0;
                info.pbTag = tagHandle.AddrOfPinnedObject();
                info.cbTag = tag.Length;
                info.pbMacContext = IntPtr.Zero;
                info.cbMacContext = 0;
                info.cbAAD = 0;
                info.cbData = 0;
                info.dwFlags = 0;

                int written;
                int status = BCryptDecrypt(
                    _aesKey,
                    ciphertext,
                    ciphertext.Length,
                    ref info,
                    null,
                    0,
                    plaintext,
                    plaintext.Length,
                    out written,
                    0);
                if (status != 0)
                {
                    throw new InvalidDataException(
                        "AES-GCM decrypt failed: 0x"
                        + status.ToString("X8", CultureInfo.InvariantCulture));
                }
                if (written != plaintext.Length)
                {
                    throw new InvalidDataException(
                        "AES-GCM short output: "
                        + written + "/" + plaintext.Length);
                }
            }
            finally
            {
                if (nonceHandle.IsAllocated)
                {
                    nonceHandle.Free();
                }
                if (tagHandle.IsAllocated)
                {
                    tagHandle.Free();
                }
            }
            return plaintext;
        }

        private static void EnsureAes()
        {
            if (_aesKey != IntPtr.Zero)
            {
                return;
            }

            IntPtr algorithm;
            int status = BCryptOpenAlgorithmProvider(
                out algorithm, "AES", null, 0);
            if (status != 0)
            {
                throw new InvalidDataException(
                    "BCryptOpenAlgorithmProvider failed: 0x"
                    + status.ToString("X8"));
            }

            byte[] mode = Encoding.Unicode.GetBytes("ChainingModeGCM\0");
            status = BCryptSetProperty(
                algorithm, "ChainingMode", mode, mode.Length, 0);
            if (status != 0)
            {
                BCryptCloseAlgorithmProvider(algorithm, 0);
                throw new InvalidDataException(
                    "BCryptSetProperty(ChainingModeGCM) failed: 0x"
                    + status.ToString("X8"));
            }

            byte[] key = new byte[KeyMaterialA.Length];
            for (int i = 0; i < key.Length; i++)
            {
                key[i] = (byte)(KeyMaterialA[i] ^ KeyMaterialB[i]);
            }

            IntPtr keyHandle;
            status = BCryptGenerateSymmetricKey(
                algorithm,
                out keyHandle,
                IntPtr.Zero,
                0,
                key,
                key.Length,
                0);
            if (status != 0)
            {
                BCryptCloseAlgorithmProvider(algorithm, 0);
                throw new InvalidDataException(
                    "BCryptGenerateSymmetricKey failed: 0x"
                    + status.ToString("X8"));
            }

            _aesAlgorithm = algorithm;
            _aesKey = keyHandle;
        }

        private static byte[] FromHex(string hex)
        {
            byte[] result = new byte[hex.Length / 2];
            for (int i = 0; i < result.Length; i++)
            {
                result[i] = byte.Parse(
                    hex.Substring(i * 2, 2),
                    NumberStyles.HexNumber,
                    CultureInfo.InvariantCulture);
            }
            return result;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BcryptAuthInfo
        {
            public int cbSize;
            public int dwInfoVersion;
            public IntPtr pbNonce;
            public int cbNonce;
            public IntPtr pbAuthData;
            public int cbAuthData;
            public IntPtr pbTag;
            public int cbTag;
            public IntPtr pbMacContext;
            public int cbMacContext;
            public int cbAAD;
            public long cbData;
            public int dwFlags;
        }

        [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)]
        private static extern int BCryptOpenAlgorithmProvider(
            out IntPtr algorithm, string algorithmId,
            string implementation, int flags);

        [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)]
        private static extern int BCryptSetProperty(
            IntPtr handle, string property, byte[] input,
            int inputLength, int flags);

        [DllImport("bcrypt.dll")]
        private static extern int BCryptGenerateSymmetricKey(
            IntPtr algorithm,
            out IntPtr key,
            IntPtr keyObject,
            int keyObjectLength,
            byte[] secret,
            int secretLength,
            int flags);

        [DllImport("bcrypt.dll")]
        private static extern int BCryptDecrypt(
            IntPtr key,
            byte[] input,
            int inputLength,
            ref BcryptAuthInfo paddingInfo,
            byte[] iv,
            int ivLength,
            byte[] output,
            int outputLength,
            out int resultLength,
            int flags);

        [DllImport("bcrypt.dll")]
        private static extern int BCryptDestroyKey(IntPtr key);

        [DllImport("bcrypt.dll")]
        private static extern int BCryptCloseAlgorithmProvider(
            IntPtr algorithm, int flags);
    }
}
