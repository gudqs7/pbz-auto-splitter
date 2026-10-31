using System;

namespace OodleCleanRoom
{
    public sealed class OodleFormatException : InvalidOperationException
    {
        public OodleFormatException(string message)
            : base(message)
        {
        }
    }
}
