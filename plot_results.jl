#!/usr/bin/env julia
#
# Plot single-chip DGEMM results: combined view with efficiency and performance
# overlaid.  Thin CLI wrapper around AppleMSeriesBLASCoreComparison.plot_results.
#
# Usage: julia --project=. plot_results.jl [--in=results.csv] [--out=dgemm_cores]

using AppleMSeriesBLASCoreComparison

function getopt(args, name, default)
    pfx = "--$(name)="
    i = findfirst(a -> startswith(a, pfx), args)
    i === nothing ? default : args[i][length(pfx)+1:end]
end

plot_results(getopt(ARGS, "in", "results.csv");
             outbase=getopt(ARGS, "out", "dgemm_cores"))
