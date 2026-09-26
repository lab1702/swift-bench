// Multi-core benchmark: CPU-bound and memory-bound workloads.
//
// Runs a fixed amount of work with 1...maxThreads threads and reports
// throughput, speedup and efficiency, then names the thread count that gave
// the best overall throughput.
//
//   cpu - pure arithmetic in registers; scales with core count and core speed.
//   mem - streams through a buffer much larger than the caches; limited by
//         DRAM bandwidth, so it usually saturates with fewer threads.
//
// Work is handed out in small chunks from a shared atomic counter, so faster
// cores (e.g. Apple Silicon P-cores) naturally take more chunks than slower
// ones instead of everybody waiting on the slowest thread.
//
// Build:  swiftc -O main.swift -o bench
// Run:    ./bench [cpu|mem|both] [maxThreads] [runsPerCount]

import Foundation
import Synchronization

// MARK: - Configuration

let logicalCores = ProcessInfo.processInfo.activeProcessorCount
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "both"
let maxThreads = args.count > 2 ? Int(args[2]) ?? logicalCores * 2 : logicalCores * 2
let runsPerCount = args.count > 3 ? Int(args[3]) ?? 3 : 3

guard ["cpu", "mem", "both"].contains(mode) else {
    print("usage: \(args[0]) [cpu|mem|both] [maxThreads] [runsPerCount]")
    exit(1)
}

// MARK: - Workloads

struct Workload: Sendable {
    let name: String
    let description: String
    let totalChunks: Int
    let throughputLabel: String
    /// Converts one chunk into the throughput unit (chunks, GB, ...).
    let throughputPerChunk: Double
    let work: @Sendable (Int) -> UInt64
}

/// Pure CPU work: integer hashing plus some floating point, with a data
/// dependency chain so the compiler can't vectorize or skip it.
@inline(never)
@Sendable func crunch(seed: UInt64, iterations: Int) -> UInt64 {
    var x = seed &+ 0x9E37_79B9_7F4A_7C15
    var f = Double(seed & 0xFFFF) + 1.0
    for _ in 0..<iterations {
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        f = f * 1.000_000_1 + Double(x & 0xFF) * 1e-9
    }
    return x ^ UInt64(bitPattern: Int64(f))
}

func makeCPUWorkload() -> Workload {
    let iterations = 200_000
    return Workload(
        name: "CPU-bound",
        description: "4000 chunks x \(iterations) arithmetic iterations",
        totalChunks: 4_000,
        throughputLabel: "Chunks/s",
        throughputPerChunk: 1,
        work: { chunk in crunch(seed: UInt64(chunk), iterations: iterations) }
    )
}

/// Large read-only buffer shared by all threads. Read-only, so no data races.
final class Buffer: @unchecked Sendable {
    let count: Int
    let pointer: UnsafeMutablePointer<UInt64>

    init(count: Int) {
        self.count = count
        pointer = .allocate(capacity: count)
        // Touch every page up front so page faults aren't timed.
        for i in 0..<count { pointer[i] = UInt64(i) }
    }

    deinit { pointer.deallocate() }
}

/// Sums a contiguous slice. Integer adds are associative, so the compiler
/// vectorizes this and the loop runs as fast as memory can feed it.
@inline(never)
@Sendable func sumSlice(_ p: UnsafePointer<UInt64>, _ n: Int) -> UInt64 {
    var total: UInt64 = 0
    for i in 0..<n { total &+= p[i] }
    return total
}

func makeMemoryWorkload() -> Workload {
    let bufferBytes = 512 << 20   // 512 MB: far bigger than any on-chip cache
    let chunkBytes = 1 << 20      // 1 MB per chunk
    let passes = 30               // total data read = passes x buffer size
    let elementsPerChunk = chunkBytes / MemoryLayout<UInt64>.size
    let chunksPerPass = bufferBytes / chunkBytes

    print("Allocating \(bufferBytes >> 20) MB buffer for memory workload...")
    let buffer = Buffer(count: bufferBytes / MemoryLayout<UInt64>.size)

    return Workload(
        name: "Memory-bound",
        description: "\(passes) passes over \(bufferBytes >> 20) MB (\((passes * bufferBytes) >> 30) GB read)",
        totalChunks: passes * chunksPerPass,
        throughputLabel: "GB/s",
        throughputPerChunk: Double(chunkBytes) / 1e9,
        work: { chunk in
            let offset = (chunk % chunksPerPass) * elementsPerChunk
            return sumSlice(buffer.pointer + offset, elementsPerChunk)
        }
    )
}

// MARK: - Runner

final class WorkQueue: Sendable {
    let next = Atomic<Int>(0)
    let checksum = Atomic<UInt64>(0)
}

/// Runs the whole workload on `threadCount` threads, returns elapsed seconds.
func runBenchmark(_ workload: Workload, threadCount: Int) -> Double {
    let queue = WorkQueue()
    let group = DispatchGroup()
    let startGate = DispatchSemaphore(value: 0)

    for _ in 0..<threadCount {
        group.enter()
        let t = Thread {
            startGate.wait()
            var local: UInt64 = 0
            while true {
                let chunk = queue.next.wrappingAdd(1, ordering: .relaxed).oldValue
                if chunk >= workload.totalChunks { break }
                local &+= workload.work(chunk)
            }
            queue.checksum.wrappingAdd(local, ordering: .relaxed)
            group.leave()
        }
        t.qualityOfService = .userInitiated
        t.stackSize = 1 << 20
        t.start()
    }

    // Release all threads at once so thread creation isn't timed.
    let start = DispatchTime.now()
    for _ in 0..<threadCount { startGate.signal() }
    group.wait()
    let end = DispatchTime.now()

    // Keep the result observable so the work can't be optimized away.
    if queue.checksum.load(ordering: .relaxed) == 42 { print("") }
    return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
}

struct Result {
    let threads: Int
    let seconds: Double
}

struct Summary {
    let name: String
    let bestThreads: Int
    let nearBestThreads: Int
    let speedup: Double
    let peakThroughput: String
}

func benchmark(_ workload: Workload) -> Summary {
    print("")
    print("== \(workload.name): \(workload.description) ==")

    _ = runBenchmark(workload, threadCount: logicalCores)  // warm-up

    var results: [Result] = []
    for n in 1...maxThreads {
        let best = (0..<runsPerCount).map { _ in runBenchmark(workload, threadCount: n) }.min()!
        results.append(Result(threads: n, seconds: best))
        print("  \(n) thread\(n == 1 ? " " : "s") ... \(String(format: "%.3f s", best))")
    }

    let baseline = results[0].seconds
    let bestResult = results.min { $0.seconds < $1.seconds }!
    let maxSpeedup = baseline / bestResult.seconds
    let barWidth = 40

    print("")
    let label = workload.throughputLabel.padding(toLength: 9, withPad: " ", startingAt: 0)
    print("Threads    Time(s)  \(label)  Speedup   Efficiency")
    print(String(repeating: "-", count: 56 + barWidth))
    for r in results {
        let speedup = baseline / r.seconds
        let efficiency = speedup / Double(r.threads) * 100
        let throughput = Double(workload.totalChunks) * workload.throughputPerChunk / r.seconds
        let bar = String(repeating: "█", count: Int((speedup / maxSpeedup * Double(barWidth)).rounded()))
        let marker = r.threads == bestResult.threads ? " ◀ best" : ""
        print(String(format: "%7d  %9.3f  %9.1f  %7.2fx  %10.1f%%   ", r.threads, r.seconds, throughput, speedup, efficiency) + bar + marker)
    }

    // Smallest thread count within 2% of the best: same performance, fewer threads.
    let nearBest = results.first { $0.seconds <= bestResult.seconds * 1.02 }!
    let peak = Double(workload.totalChunks) * workload.throughputPerChunk / bestResult.seconds

    print("")
    print("Best throughput : \(bestResult.threads) threads (\(String(format: "%.2fx", maxSpeedup)) vs 1 thread)")
    if nearBest.threads != bestResult.threads {
        print("Within 2% of best with only \(nearBest.threads) threads")
    }

    return Summary(
        name: workload.name,
        bestThreads: bestResult.threads,
        nearBestThreads: nearBest.threads,
        speedup: maxSpeedup,
        peakThroughput: String(format: "%.1f %@", peak, workload.throughputLabel)
    )
}

// MARK: - Main

func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
}

print("Multi-core benchmark")
print("--------------------")
print("Logical cores : \(logicalCores)")
if let p = sysctlInt("hw.perflevel0.physicalcpu") {
    let e = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
    print("P-cores       : \(p)")
    if e > 0 { print("E-cores       : \(e)") }
}
print("Thread range  : 1...\(maxThreads)")
print("Runs per count: \(runsPerCount) (best time kept)")

var summaries: [Summary] = []
if mode == "cpu" || mode == "both" { summaries.append(benchmark(makeCPUWorkload())) }
if mode == "mem" || mode == "both" { summaries.append(benchmark(makeMemoryWorkload())) }

if summaries.count > 1 {
    print("")
    print("== Summary ==")
    for s in summaries {
        let name = s.name.padding(toLength: 13, withPad: " ", startingAt: 0)
        print("\(name) best at \(s.bestThreads) threads (≈\(s.nearBestThreads) within 2%), " +
              "\(String(format: "%.2fx", s.speedup)) speedup, peak \(s.peakThroughput)")
    }
}
