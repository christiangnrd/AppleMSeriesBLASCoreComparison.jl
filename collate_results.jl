#!/usr/bin/env julia
#
# Collate DGEMM results from multiple architectures and create comparison
# plots.  Thin CLI wrapper around AppleMSeriesBLASCoreComparison.collate_results.
#
# Usage:
#   julia --project=. collate_results.jl results-m1pro.csv results-m6max.csv ...
#   julia --project=. collate_results.jl results-*.csv [--out=base] [--level=LEVEL]

using AppleMSeriesBLASCoreComparison

function getopt(args, name, default)
    pfx = "--$(name)="
    i = findfirst(a -> startswith(a, pfx), args)
    i === nothing ? default : args[i][length(pfx)+1:end]
end

infiles = filter(a -> endswith(a, ".csv") && !startswith(a, "--"), ARGS)
length(infiles) > 0 || error("no CSV files provided")

collate_results(infiles;
                outbase=getopt(ARGS, "out", "dgemm_collated"),
                level=getopt(ARGS, "level", ""))
