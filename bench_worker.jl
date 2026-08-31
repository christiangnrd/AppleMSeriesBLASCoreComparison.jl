#!/usr/bin/env julia
#
# Worker process for the E-core/P-core/Super-core DGEMM sweep.
#
# Runs a single (nthreads, QoS-mode, perf-level) measurement point and prints
# one CSV row on stdout.  It is launched by driver.jl, optionally wrapped in
# taskpolicy so that the process is confined to a specific perf level.
#
# Configuration comes from the environment:
#   BENCH_THREADS       number of OpenBLAS threads to use
#   BENCH_N             DGEMM matrix dimension
#   BENCH_TRIALS        number of timed trials (we report best and median)
#   BENCH_MODE          label for the mode (default, efficiency, performance, super)
#   BENCH_CHIP          chip ID for result collation (e.g. "Apple M1")
#   BENCH_LEVEL_INDEX   perf level index (0=fastest, 1=next, ...)
#   BENCH_LEVEL_NAME    perf level name (Super, Performance, Efficiency)

using LinearAlgebra
using Printf
using Statistics

const nthreads = parse(Int, get(ENV, "BENCH_THREADS", "1"))
const n        = parse(Int, get(ENV, "BENCH_N", "4096"))
const ntrials  = parse(Int, get(ENV, "BENCH_TRIALS", "5"))
const mode     = get(ENV, "BENCH_MODE", "default")
const chip     = get(ENV, "BENCH_CHIP", "unknown")
const level_ix = parse(Int, get(ENV, "BENCH_LEVEL_INDEX", "0"))
const level_nm = get(ENV, "BENCH_LEVEL_NAME", "unknown")

BLAS.set_num_threads(nthreads)

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

# Warm-up problem: in a fresh process the very first gemm pays for OpenBLAS
# thread creation, and under background QoS that cost is significant.
dgemm_gflops(512, 2)

t0 = time()
best, med, times = dgemm_gflops(n, ntrials)
wall = time() - t0

@printf("%s,%d,%s,%s,%d,%d,%d,%.4f,%.4f,%.3f\n",
        chip, level_ix, level_nm, mode, nthreads, n, ntrials, best, med, wall)
