# swift-perf

A small multi-core benchmark written in Swift. It runs the same amount of work
with 1, 2, 3, … threads and shows which thread count gives the best overall
throughput. It has two workloads:

- **CPU-bound**: pure arithmetic that stays in registers. It shows how
  performance scales with the number and speed of your cores.
- **Memory-bound**: reads through a 512 MB buffer, far larger than any cache.
  It shows how many threads it takes to use up your memory bandwidth.

## Requirements

- macOS 15 or later (uses the `Synchronization` module's `Atomic`)
- Swift 6 toolchain (Xcode 16+ or the Command Line Tools)
- About 600 MB of free RAM for the memory test

## Build

```sh
swiftc -O main.swift -o bench
```

Always build with `-O`. Without optimization the numbers are meaningless.

## Run

```sh
./bench [cpu|mem|both] [maxThreads] [runsPerCount]
```

| Argument       | Default              | Meaning                                         |
|----------------|----------------------|-------------------------------------------------|
| `cpu\|mem\|both` | `both`               | Which workload(s) to run                        |
| `maxThreads`   | 2 × logical cores    | Tests every thread count from 1 up to this      |
| `runsPerCount` | `3`                  | Runs per thread count; the fastest one is kept |

Examples:

```sh
./bench              # both workloads, 1…2×cores threads, 3 runs each
./bench cpu          # CPU workload only
./bench mem 12       # memory workload, 1…12 threads
./bench both 16 5    # both workloads, 1…16 threads, 5 runs each
```

A full run of both workloads takes about 25 seconds on a 10-core Mac. For the
most stable numbers, close other busy apps and keep the machine plugged in.

## Reading the output

For each workload you get one table row per thread count:

```
Threads    Time(s)  Chunks/s   Speedup   Efficiency
      1      1.047     3819.6     1.00x       100.0%   █████
      4      0.283    14117.5     3.70x        92.4%   ████████████████████
     10      0.140    28479.1     7.46x        74.6%   ████████████████████████████████████████
```

- **Time**: time to finish all the work (the best of the runs).
- **Chunks/s** or **GB/s**: throughput. The CPU test counts work chunks per
  second. The memory test shows read bandwidth.
- **Speedup**: throughput compared to 1 thread.
- **Efficiency**: speedup divided by thread count, showing how much each added
  thread contributes. 100% means perfect scaling.
- **Bar**: speedup relative to the best result.

Under each table:

- **Best throughput**: the thread count with the fastest time.
- **Within 2% of best**: the smallest thread count that gets almost the same
  result. **This is usually the more useful number.** Once performance levels
  off, the "best" count is decided by run-to-run noise of well under 1%.

When both workloads run, a short summary at the end puts them side by side.

## What to expect

Example from a 10-core Apple Silicon Mac (4 performance + 6 efficiency cores):

| Workload     | Speedup vs 1 thread | Levels off at             | Peak          |
|--------------|---------------------|---------------------------|---------------|
| CPU-bound    | 7.5×                | 10 threads (one per core) | 28.8k chunks/s |
| Memory-bound | 1.8×                | ~7 threads                | ~137 GB/s     |

- **CPU-bound** work scales almost perfectly across the performance cores.
  It keeps improving, by less per thread, on the slower efficiency cores and
  stops at one thread per core. More threads than cores gain nothing.
- **Memory-bound** work runs out of memory bandwidth much earlier. A single
  thread already gets more than half the peak, so adding threads helps less.

Rule of thumb: use one thread per core for computation-heavy work. For work
that mostly streams through memory, fewer threads get nearly all the benefit.

## How it works

- All threads take work from one shared atomic counter, in small chunks. Faster
  cores simply take more chunks, so no thread sits idle waiting for a slow one.
- Threads are created first and then released together, so thread start-up
  time isn't measured.
- One warm-up run happens before measuring. The memory buffer is filled before
  timing starts, so the one-time cost of first touching memory isn't measured.
- Each thread's results are combined into a checksum, so the compiler can't
  skip the work.

To change how much work each test does, edit the constants in
`makeCPUWorkload()` and `makeMemoryWorkload()` in `main.swift`.

## License

MIT. See [LICENSE](LICENSE).
