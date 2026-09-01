#!/usr/bin/env julia
#
# Worker process for the Apple silicon core-tier DGEMM sweep.
#
# Runs a single (nthreads, perf-level) measurement point and prints
# one CSV row on stdout.  Configuration comes from the BENCH_* environment
# variables documented in src/worker.jl.
#
# Thin wrapper that `include`s the stdlib-only implementation so that
# benchmark processes never load the package (and its Plots dependency).

include(joinpath(@__DIR__, "src", "worker.jl"))
worker_main()
