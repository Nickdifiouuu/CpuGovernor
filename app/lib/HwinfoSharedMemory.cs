// Read-only reader for HWiNFO's sensor shared memory ("Global\HWiNFO_SENS_SM2").
// Layout per the public HWiNFO shared-memory SDK (hwisenssm2.h, #pragma pack(1)).
using System;
using System.Collections.Generic;
using System.IO.MemoryMappedFiles;
using System.Text;

public class HwinfoReading
{
    public int Type;            // 1 temp, 2 volt, 3 fan, 4 current, 5 power, 6 clock, 7 usage, 8 other
    public uint SensorIndex;
    public uint ReadingId;
    public string Sensor;
    public string Label;
    public string Unit;
    public double Value, Min, Max, Avg;
}

public static class HwinfoSharedMemory
{
    const string MapName = "Global\\HWiNFO_SENS_SM2";
    const uint Signature = 0x53695748; // "HWiS"

    public static bool IsAvailable()
    {
        try { using (var m = MemoryMappedFile.OpenExisting(MapName, MemoryMappedFileRights.Read)) return true; }
        catch { return false; }
    }

    public static List<HwinfoReading> Read()
    {
        var list = new List<HwinfoReading>();
        using (var mmf = MemoryMappedFile.OpenExisting(MapName, MemoryMappedFileRights.Read))
        using (var acc = mmf.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read))
        {
            uint sig = acc.ReadUInt32(0);
            if (sig != Signature) throw new InvalidOperationException("HWiNFO shared memory signature mismatch (0x" + sig.ToString("X8") + "); sharing may have expired");
            uint offS = acc.ReadUInt32(20), sizeS = acc.ReadUInt32(24), numS = acc.ReadUInt32(28);
            uint offR = acc.ReadUInt32(32), sizeR = acc.ReadUInt32(36), numR = acc.ReadUInt32(40);

            var sensors = new string[numS];
            for (uint i = 0; i < numS; i++)
            {
                long b = offS + (long)i * sizeS;
                string user = Str(acc, b + 136, 128);
                sensors[i] = user.Length > 0 ? user : Str(acc, b + 8, 128);
            }
            for (uint i = 0; i < numR; i++)
            {
                long b = offR + (long)i * sizeR;
                var r = new HwinfoReading();
                r.Type = acc.ReadInt32(b);
                r.SensorIndex = acc.ReadUInt32(b + 4);
                r.ReadingId = acc.ReadUInt32(b + 8);
                string user = Str(acc, b + 140, 128);
                r.Label = user.Length > 0 ? user : Str(acc, b + 12, 128);
                r.Unit = Str(acc, b + 268, 16);
                r.Value = acc.ReadDouble(b + 284);
                r.Min = acc.ReadDouble(b + 292);
                r.Max = acc.ReadDouble(b + 300);
                r.Avg = acc.ReadDouble(b + 308);
                r.Sensor = r.SensorIndex < numS ? sensors[r.SensorIndex] : "?";
                list.Add(r);
            }
        }
        return list;
    }

    static string Str(MemoryMappedViewAccessor a, long off, int len)
    {
        var bytes = new byte[len];
        a.ReadArray(off, bytes, 0, len);
        int n = Array.IndexOf(bytes, (byte)0);
        if (n < 0) n = len;
        return Encoding.Latin1.GetString(bytes, 0, n).Trim();
    }
}
