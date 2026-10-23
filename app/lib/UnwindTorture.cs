// UnwindTorture — targeted, self-verifying reproducer for the crash signature seen in the kernel dumps
// (register corruption inside the stack unwinder, RtlpUnwindPrologue). ntdll carries a user-mode copy of the same
// unwinder; RtlCaptureStackBackTrace -> RtlWalkFrameChain -> RtlVirtualUnwind -> RtlpUnwindPrologue.
// Each worker is pinned to one logical processor, builds a fixed-depth call stack, captures a reference backtrace,
// then re-walks the identical stack continuously and compares every result with the reference. Any difference is a
// silent computation error; an access violation kills the (separate) test process — both count as FAIL.
using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

public static class UnwindTorture
{
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")] static extern UIntPtr SetThreadAffinityMask(IntPtr h, UIntPtr mask);
    [DllImport("kernel32.dll")] static extern ushort RtlCaptureStackBackTrace(uint skip, uint count, IntPtr[] frames, out uint hash);

    [DllImport("kernel32.dll")] static extern void RtlCaptureContext(IntPtr context);
    [DllImport("kernel32.dll")] static extern IntPtr RtlLookupFunctionEntry(ulong pc, out ulong imageBase, IntPtr history);
    [DllImport("kernel32.dll")] static extern IntPtr RtlVirtualUnwind(uint type, ulong imageBase, ulong pc, IntPtr fe, IntPtr ctx, out IntPtr handlerData, out ulong establisher, IntPtr ctxPtrs);

    public sealed class WorkerResult
    {
        public int Lp; public long Walks; public long Mismatches; public string FirstMismatch = ""; public int Depth; public double Seconds;
    }

    // v2: explicit frame-by-frame walk (RtlLookupFunctionEntry + RtlVirtualUnwind per frame), i.e. what the kernel's
    // RtlpWalkFrameChain does. Unwinds through JIT frames via the runtime's registered function tables.
    const int CtxSize = 1232, OffRsp = 0x98, OffRip = 0xF8;
    [MethodImpl(MethodImplOptions.NoInlining | MethodImplOptions.NoOptimization)]   // no tiering: code address must stay fixed
    static int ManualWalk(IntPtr ctx, ulong[] rips)
    {
        RtlCaptureContext(ctx);
        int n = 0;
        while (n < rips.Length)
        {
            ulong rip = (ulong)Marshal.ReadInt64(ctx, OffRip);
            if (rip == 0) break;
            rips[n++] = rip;
            ulong imageBase; IntPtr fe = RtlLookupFunctionEntry(rip, out imageBase, IntPtr.Zero);
            if (fe == IntPtr.Zero)
            {   // leaf function: return address is at [rsp]
                ulong rsp = (ulong)Marshal.ReadInt64(ctx, OffRsp);
                Marshal.WriteInt64(ctx, OffRip, Marshal.ReadInt64(new IntPtr((long)rsp)));
                Marshal.WriteInt64(ctx, OffRsp, (long)(rsp + 8));
            }
            else { IntPtr hd; ulong ef; RtlVirtualUnwind(0, imageBase, rip, fe, ctx, out hd, out ef, IntPtr.Zero); }
        }
        return n;
    }

    [MethodImpl(MethodImplOptions.NoInlining | MethodImplOptions.NoOptimization)]
    static long ManualLoop(WorkerResult r, long deadlineTicks, bool bursty, Random rnd)
    {
        IntPtr raw = Marshal.AllocHGlobal(CtxSize + 16);
        IntPtr ctx = new IntPtr((raw.ToInt64() + 15) & ~15L);             // CONTEXT must be 16-byte aligned
        var refRips = new ulong[128]; var rips = new ulong[128];
        int refN = -1;
        var sw = Stopwatch.StartNew();
        while (Stopwatch.GetTimestamp() < deadlineTicks)
        {
            long burstEnd = bursty ? Stopwatch.GetTimestamp() + (long)(Stopwatch.Frequency * (0.005 + rnd.NextDouble() * 0.035)) : deadlineTicks;
            while (Stopwatch.GetTimestamp() < burstEnd)
            for (int k = 0; k < 64; k++)
            {
                int n = ManualWalk(ctx, rips);          // single call site, so every walk sees an identical stack
                if (refN < 0) { refN = n; Array.Copy(rips, refRips, n); r.Depth = n; continue; }
                r.Walks++;
                bool same = n == refN;
                if (same) for (int i = 0; i < n; i++) if (rips[i] != refRips[i]) { same = false; break; }
                if (!same)
                {
                    r.Mismatches++;
                    if (r.FirstMismatch.Length == 0) r.FirstMismatch = string.Format("walk {0}: {1} frames (ref {2}) at {3:O}", r.Walks, n, refN, DateTime.Now);
                }
            }
            if (bursty && Stopwatch.GetTimestamp() < deadlineTicks) Thread.Sleep(20 + rnd.Next(100));
        }
        r.Seconds = sw.Elapsed.TotalSeconds;
        Marshal.FreeHGlobal(raw);
        return r.Walks;
    }

    [MethodImpl(MethodImplOptions.NoInlining | MethodImplOptions.NoOptimization)]
    static long DescendManual(int n, WorkerResult r, long deadlineTicks, bool bursty, Random rnd)
    {
        if (n > 0) return DescendManual(n - 1, r, deadlineTicks, bursty, rnd) + 1;
        return ManualLoop(r, deadlineTicks, bursty, rnd);
    }

    public static WorkerResult[] RunManual(int[] logicalProcessors, double seconds, int depth, bool bursty)
    {
        var results = new WorkerResult[logicalProcessors.Length];
        var threads = new Thread[logicalProcessors.Length];
        long deadline = Stopwatch.GetTimestamp() + (long)(Stopwatch.Frequency * seconds);
        for (int i = 0; i < logicalProcessors.Length; i++)
        {
            int idx = i, lp = logicalProcessors[i];
            results[idx] = new WorkerResult { Lp = lp };
            threads[idx] = new Thread(() =>
            {
                SetThreadAffinityMask(GetCurrentThread(), new UIntPtr(1UL << lp));
                DescendManual(depth, results[idx], deadline, bursty, new Random(lp * 7919 + 17));
            }, 16 * 1024 * 1024);
            threads[idx].IsBackground = true;
            threads[idx].Start();
        }
        foreach (var t in threads) t.Join();
        return results;
    }

    // Build 'depth' managed frames, then run the walk loop at the bottom so every walk sees the same stack.
    [MethodImpl(MethodImplOptions.NoInlining | MethodImplOptions.NoOptimization)]
    static long Descend(int n, WorkerResult r, long deadlineTicks, bool bursty, Random rnd)
    {
        if (n > 0) return Descend(n - 1, r, deadlineTicks, bursty, rnd) + 1;
        return WalkLoop(r, deadlineTicks, bursty, rnd);
    }

    [MethodImpl(MethodImplOptions.NoInlining | MethodImplOptions.NoOptimization)]
    static long WalkLoop(WorkerResult r, long deadlineTicks, bool bursty, Random rnd)
    {
        var refFrames = new IntPtr[62]; uint refHash;
        int refCount = RtlCaptureStackBackTrace(0, 62, refFrames, out refHash);
        r.Depth = refCount;
        var buf = new IntPtr[62]; uint hash;
        var sw = Stopwatch.StartNew();
        while (Stopwatch.GetTimestamp() < deadlineTicks)
        {
            // bursty: 5-40 ms of work, then 20-120 ms idle (core cools a little, drops to a C-state, and re-boosts to its top bin)
            long burstEnd = bursty ? Stopwatch.GetTimestamp() + (long)(Stopwatch.Frequency * (0.005 + rnd.NextDouble() * 0.035)) : deadlineTicks;
            while (Stopwatch.GetTimestamp() < burstEnd)
            for (int k = 0; k < 256; k++)
            {
                int c = RtlCaptureStackBackTrace(0, 62, buf, out hash);
                r.Walks++;
                bool same = (c == refCount) && (hash == refHash);
                if (same) { for (int i = 0; i < c; i++) if (buf[i] != refFrames[i]) { same = false; break; } }
                if (!same)
                {
                    r.Mismatches++;
                    if (r.FirstMismatch.Length == 0)
                        r.FirstMismatch = string.Format("walk {0}: frames {1} (ref {2}) hash 0x{3:X8} (ref 0x{4:X8}) at {5:O}", r.Walks, c, refCount, hash, refHash, DateTime.Now);
                }
            }
            if (bursty && Stopwatch.GetTimestamp() < deadlineTicks) Thread.Sleep(20 + rnd.Next(100));   // idle gap -> C-state + frequency ramp
        }
        r.Seconds = sw.Elapsed.TotalSeconds;
        return r.Walks;
    }

    public static WorkerResult[] Run(int[] logicalProcessors, double seconds, int depth, bool bursty)
    {
        var results = new WorkerResult[logicalProcessors.Length];
        var threads = new Thread[logicalProcessors.Length];
        long deadline = Stopwatch.GetTimestamp() + (long)(Stopwatch.Frequency * seconds);
        for (int i = 0; i < logicalProcessors.Length; i++)
        {
            int idx = i, lp = logicalProcessors[i];
            results[idx] = new WorkerResult { Lp = lp };
            threads[idx] = new Thread(() =>
            {
                SetThreadAffinityMask(GetCurrentThread(), new UIntPtr(1UL << lp));
                Descend(depth, results[idx], deadline, bursty, new Random(lp * 7919 + 17));
            }, 16 * 1024 * 1024);
            threads[idx].IsBackground = true;
            threads[idx].Start();
        }
        foreach (var t in threads) t.Join();
        return results;
    }
}
