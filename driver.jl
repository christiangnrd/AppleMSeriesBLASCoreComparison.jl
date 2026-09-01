#!/usr/bin/env julia
#
# Driver for the OpenBLAS DGEMM efficiency/performance core sweep on Apple
# silicon.  Thin CLI wrapper around AppleMSeriesBLASCoreComparison.sweep.
#
# Usage:
#   julia --project=. driver.jl [options]
#     --n=2048            DGEMM matrix dimension
#     --trials=5          timed DGEMM calls per point (best is reported)
#     --max-threads=N     highest thread count within each level (default: level's core count)
#     --modes=a,b         subset of modes, e.g. super,all (see topology output)
#     --out=results.csv   where to write the results
#     --no-plot           skip the plotting step

using AppleMSeriesBLASCoreComparison

function getopt(args, name, default)
    pfx = "--$(name)="
    i = findfirst(a -> startswith(a, pfx), args)
    i === nothing ? default : args[i][length(pfx)+1:end]
end

const MODES_ARG      = getopt(ARGS, "modes", "")
const MAXTHREADS_ARG = getopt(ARGS, "max-threads", "")

sweep(
    n           = parse(Int, getopt(ARGS, "n", "2048")),
    trials      = parse(Int, getopt(ARGS, "trials", "5")),
    out         = getopt(ARGS, "out", "results.csv"),
    modes       = MODES_ARG == "" ? nothing : split(MODES_ARG, ','),
    max_threads = MAXTHREADS_ARG == "" ? nothing : parse(Int, MAXTHREADS_ARG),
    plot        = !("--no-plot" in ARGS),
)
