if (!('RINtHash' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RINtHash {
    [DllImport("bcrypt.dll", CharSet=CharSet.Unicode)]
    private static extern int BCryptOpenAlgorithmProvider(out IntPtr h, string name, string implementation, int flags);
    [DllImport("bcrypt.dll")]
    private static extern int BCryptHash(IntPtr h, byte[] secret, int secretLength, byte[] input, int inputLength, byte[] output, int outputLength);
    [DllImport("bcrypt.dll")]
    private static extern int BCryptCloseAlgorithmProvider(IntPtr h, int flags);
    public static byte[] Compute(byte[] input) {
        IntPtr h;
        int status = BCryptOpenAlgorithmProvider(out h, "MD4", null, 0);
        if (status != 0) throw new InvalidOperationException("Cannot initialize NT hash provider");
        try {
            byte[] result = new byte[16];
            status = BCryptHash(h, null, 0, input, input.Length, result, result.Length);
            if (status != 0) throw new InvalidOperationException("NT hash derivation failed");
            return result;
        } finally { BCryptCloseAlgorithmProvider(h, 0); }
    }
}
'@
}
