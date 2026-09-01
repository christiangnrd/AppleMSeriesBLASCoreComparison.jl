# DGEMM timing kernel and worker entry point for the core-tier sweep.
#
# Deliberately stdlib-only: benchmark processes `include` this file directly
# (see run_point) so they never pay for loading the package and Plots.
#
# `worker_main` configuration comes from the environment:
#   BENCH_THREADS       number of OpenBLAS threads to use
#   BENCH_N             DGEMM matrix dimension
#   BENCH_TRIALS        number of timed trials (we report best and median)
#   BENCH_MODE          label for the mode (super, performance, efficiency, all)
#   BENCH_CHIP          chip ID for result collation (e.g. "Apple M5 Pro")
#   BENCH_LEVEL_INDEX   perf level index (0=fastest, 1=next, ...; -1 for all)
#   BENCH_LEVEL_NAME    perf level name (Super, Performance, Efficiency, All)
#   BENCH_OCCUPIED      number of faster cores the occupier kept busy

using LinearAlgebra
using Printf
using Statistics

"""
    dgemm_gflops(n, ntrials) -> (best, median, times)

Time `ntrials` in-place `C .= A*B` DGEMM calls on `n x n` matrices and convert
to GFLOPS using the standard 2n^3 flop count.
"""
function dgemm_gflops(n::Int, ntrials::Int)
    A = rand(Float64, n, n)
    B = rand(Float64, n, n)
    C = zeros(Float64, n, n)
    mul!(C, A, B)                       # warm up the thread pool / page in C
    times = Float64[]
    for _ in 1:ntrials
        t = @elapsed mul!(C, A, B)
        push!(times, t)
    end
    gflop = 2.0 * n^3 / 1e9
    return gflop / minimum(times), gflop / median(times), times
end

"""
    worker_main(env=ENV)

Run a single (nthreads, perf-level) measurement point configured by the
`BENCH_*` entries of `env` and print one CSV row on stdout.
"""
function worker_main(env=ENV)
    nthreads = parse(Int, get(env, "BENCH_THREADS", "1"))
    n        = parse(Int, get(env, "BENCH_N", "4096"))
    ntrials  = parse(Int, get(env, "BENCH_TRIALS", "5"))
    mode     = get(env, "BENCH_MODE", "default")
    chip     = get(env, "BENCH_CHIP", "unknown")
    level_ix = parse(Int, get(env, "BENCH_LEVEL_INDEX", "0"))
    level_nm = get(env, "BENCH_LEVEL_NAME", "unknown")
    occupied = parse(Int, get(env, "BENCH_OCCUPIED", "0"))

    BLAS.set_num_threads(nthreads)

    # Warm-up problem: in a fresh process the very first gemm pays for OpenBLAS
    # thread creation and for the threads migrating onto the cores under test.
    dgemm_gflops(512, 2)

    t0 = time()
    best, med, times = dgemm_gflops(n, ntrials)
    wall = time() - t0

    @printf("%s,%d,%s,%s,%d,%d,%d,%.4f,%.4f,%.3f,%d\n",
            chip, level_ix, level_nm, mode, nthreads, n, ntrials, best, med, wall, occupied)
end
