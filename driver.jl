#!/usr/bin/env julia
#
# Driver for the OpenBLAS DGEMM core-tier sweep (Apple silicon, Linux, or any
# machine with --levels).  Thin CLI wrapper around AppleMSeriesBLASCoreComparison.sweep.
#
# Usage:
#   julia --project=. driver.jl [options]
#     --n=2048            DGEMM matrix dimension
#     --trials=5          timed DGEMM calls per point (best is reported)
#     --max-threads=N     highest thread count within each level (default: level's core count)
#     --modes=a,b         subset of modes, e.g. super,all (see topology output)
#     --out=results.csv   where to write the results
#     --no-plot           skip the plotting step
#     --levels=SPEC       supply the core tiers instead of detecting them, fastest
#                         first, as name:cores[:cpus],...  e.g.
#                         --levels=Performance:8:0-15,Efficiency:8:16-23
#                         (cpu lists use + for unions: 0-3+8-11; on Linux the
#                         benchmark is pinned to them with taskset; Linux tiers
#                         are otherwise detected from sysfs, cpu lists included)
#     --chip=NAME         chip label written to the CSV (default: detected)

using AppleMSeriesBLASCoreComparison

function getopt(args, name, default)
    pfx = "--$(name)="
    i = findfirst(a -> startswith(a, pfx), args)
    i === nothing ? default : args[i][length(pfx)+1:end]
end

const MODES_ARG      = getopt(ARGS, "modes", "")
const MAXTHREADS_ARG = getopt(ARGS, "max-threads", "")
const LEVELS_ARG     = getopt(ARGS, "levels", "")
const CHIP_ARG       = getopt(ARGS, "chip", "")

sweep(
    n           = parse(Int, getopt(ARGS, "n", "2048")),
    trials      = parse(Int, getopt(ARGS, "trials", "5")),
    out         = getopt(ARGS, "out", "results.csv"),
    modes       = MODES_ARG == "" ? nothing : split(MODES_ARG, ','),
    max_threads = MAXTHREADS_ARG == "" ? nothing : parse(Int, MAXTHREADS_ARG),
    plot        = !("--no-plot" in ARGS),
    levels      = LEVELS_ARG == "" ? nothing : LEVELS_ARG,
    chip        = CHIP_ARG == "" ? nothing : CHIP_ARG,
)
