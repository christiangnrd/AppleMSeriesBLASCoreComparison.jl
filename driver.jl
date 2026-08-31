#!/usr/bin/env julia
#
# Driver for the OpenBLAS DGEMM efficiency/performance core sweep on Apple silicon.
#
# Extended to support any number of perf levels (M1/M2 have 2: Performance + Efficiency;
# M6 has 3: Performance + Power + Efficiency).  For each level, measures isolated
# throughput by setting OPENBLAS_NUM_THREADS to that level's core count, and for
# E-cores uses background QoS to confine the process.
#
# The CSV output includes chip identity and perf-level info so results can be
# collated and compared across multiple architectures.
#
# Usage:
#   julia --project=. driver.jl [options]
#     --n=2048            DGEMM matrix dimension
#     --trials=5          timed DGEMM calls per point (best is reported)
#     --max-threads=N     highest thread count within each level (default: level's core count)
#     --modes=a,b         subset of modes (see topology output)
#     --out=results.csv   where to write the results
#     --no-plot           skip the plotting step

using Printf

# ---------------------------------------------------------------- CLI parsing

function getopt(args, name, default)
    pfx = "--$(name)="
    i = findfirst(a -> startswith(a, pfx), args)
    i === nothing ? default : args[i][length(pfx)+1:end]
end

const N          = parse(Int, getopt(ARGS, "n", "2048"))
const TRIALS     = parse(Int, getopt(ARGS, "trials", "5"))
const OUTFILE    = getopt(ARGS, "out", "results.csv")
const DOPLOT     = !("--no-plot" in ARGS)
const MAXTHREADS_OVERRIDE = getopt(ARGS, "max-threads", "")

# ------------------------------------------------------------- CPU topology

sysctl(key) = try
    parse(Int, strip(read(`sysctl -n $key`, String)))
catch
    0
end
sysctl_str(key) = try
    strip(read(`sysctl -n $key`, String))
catch
    ""
end

"""
    topology() -> (brand::String, levels::Vector{NamedTuple})

Read the Apple silicon core topology.  `hw.perflevels` reports the number of
tiers; levels are indexed from 0 (fastest) upward.  Each level gives its name
(Performance, Power, Efficiency) and logical core count.

Returns a list of (index, name, cores) tuples in order from fastest to slowest.
"""
function topology()
    brand   = sysctl_str("machdep.cpu.brand_string")
    nlevels = sysctl("hw.nperflevels")
    
    levels = []
    for i in 0:(nlevels-1)
        cores = sysctl("hw.perflevel$(i).logicalcpu")
        name  = sysctl_str("hw.perflevel$(i).name")
        cores > 0 && push!(levels, (; index=i, name, cores))
    end
    
    return brand, levels
end

const BRAND, LEVELS = topology()
const CHIP_ID = BRAND  # e.g., "Apple M1 Pro", "Apple M6 Max"
const TOTAL_CORES = sum(l.cores for l in LEVELS)

# ------------------------------------------------------------------ modes

"""
    make_modes(levels) -> Dict{String, NamedTuple}

Generate measurement modes for each perf level in isolation.
Each mode tests only that level and uses appropriate QoS.
"""
function make_modes(levels)
    modes = Dict()

    # Each level in isolation
    for (i, level) in enumerate(levels)
        lix = i - 1  # 0-indexed level index
        name = lowercase(level.name)
        prefix = name == "efficiency" ? ["taskpolicy", "-b"] : String[]
        modes[name] = (
            desc = "$(level.name) cores only ($(level.cores) cores), " *
                   (name == "efficiency" ? "background QoS" : "normal QoS"),
            test_levels = [lix],  # only this level
            max_threads_per_level = Dict(lix => level.cores),
            taskpolicy_cmd = prefix,
        )
    end

    return modes
end

const MODES = make_modes(LEVELS)
const SELECTED = split(getopt(ARGS, "modes", join(sort(collect(keys(MODES))), ',')), ',')
for m in SELECTED
    haskey(MODES, m) || error("unknown mode $(repr(m)); choose from $(join(sort(collect(keys(MODES))), ", "))")
end

# --------------------------------------------------------------- the sweep

"""
    run_point(mode, nthreads, level_index) -> String

Launch one worker process and return the CSV row it printed.
"""
function run_point(mode::AbstractString, nthreads::Int, level_index::Int)
    worker = joinpath(@__DIR__, "bench_worker.jl")
    cmd = `$(MODES[mode].taskpolicy_cmd) $(Base.julia_cmd()) --startup-file=no $worker`
    env = copy(ENV)
    env["BENCH_THREADS"]      = string(nthreads)
    env["BENCH_N"]            = string(N)
    env["BENCH_TRIALS"]       = string(TRIALS)
    env["BENCH_MODE"]         = mode
    env["BENCH_CHIP"]         = CHIP_ID
    env["BENCH_LEVEL_INDEX"]  = string(level_index)
    env["BENCH_LEVEL_NAME"]   = LEVELS[level_index + 1].name
    env["OPENBLAS_NUM_THREADS"] = string(nthreads)
    return strip(read(setenv(cmd, env), String))
end

# --------------------------------------------------------------------print & sweep

println("╭─ host")
println("│  chip:         ", CHIP_ID)
println("│  brand:        ", BRAND)
println("│  total:        ", TOTAL_CORES, " cores")
for level in LEVELS
    @printf("│    level %d:    %2d × %s\n", level.index, level.cores, level.name)
end
println("├─ problem")
@printf("│  DGEMM %d×%d Float64, best of %d trials\n", N, N, TRIALS)
println("│")
println("├─ modes")
for mode in sort(collect(keys(MODES)))
    println("│    $mode:")
    println("│      ", MODES[mode].desc)
end
println("│")
println("├─ results → ", OUTFILE)
println("│")

open(OUTFILE, "w") do io
    # CSV header
    println(io, "chip,level_index,level_name,mode,threads,n,trials,gflops_best,gflops_median,wall_s")

    for mode in SELECTED
        @printf("│\n│  %s\n", mode)
        @printf("│  %s\n", MODES[mode].desc)

        # For each level this mode tests
        for lix in MODES[mode].test_levels
            level = LEVELS[lix + 1]  # Julia arrays are 1-indexed
            max_t = MODES[mode].max_threads_per_level[lix]

            @printf("│    %-12s  ", level.name)
            println(io)  # blank line in CSV before each level's results

            # Sweep thread count from 1 to min(max_t, MAXTHREADS_OVERRIDE)
            maxthreads = MAXTHREADS_OVERRIDE == "" ? max_t : min(max_t, parse(Int, MAXTHREADS_OVERRIDE))
            for nt in 1:maxthreads
                row = run_point(mode, nt, lix)
                println(io, row); flush(io)
                f = split(row, ',')
                best, med = parse(Float64, f[8]), parse(Float64, f[9])
                @printf("│      %2d thr  %8.1f GFLOPS  %8.1f med  %6.1f GF/thr\n",
                        nt, best, med, best / nt)
            end
        end
    end
end

println("│")
println("╰─ wrote ", OUTFILE)
println()

if DOPLOT
    println("plotting...")
    run(`$(Base.julia_cmd()) --project=$(@__DIR__) $(joinpath(@__DIR__, "plot_results.jl")) --in=$OUTFILE`)
end
