# Sweep orchestration for the OpenBLAS DGEMM efficiency/performance core sweep
# on Apple silicon.
#
# Supports any number of perf levels (M1–M4 have 2: Performance + Efficiency;
# M5+ has 3: Super + Performance + Efficiency).  For each level, measures
# isolated throughput by setting OPENBLAS_NUM_THREADS to that level's core
# count, and for E-cores uses background QoS to confine the process.
#
# The CSV output includes chip identity and perf-level info so results can be
# collated and compared across multiple architectures.

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
(Super, Performance, Efficiency) and logical core count.

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

const WORKER_FILE = joinpath(@__DIR__, "worker.jl")

"""
    run_point(modes, mode, nthreads, level_index, levels, chip, n, trials) -> String

Launch one worker process and return the CSV row it printed.  The worker only
`include`s worker.jl (no package load) to keep startup light.
"""
function run_point(modes, mode::AbstractString, nthreads::Int, level_index::Int,
                   levels, chip::AbstractString, n::Int, trials::Int)
    code = "include($(repr(WORKER_FILE))); worker_main()"
    cmd = `$(modes[mode].taskpolicy_cmd) $(Base.julia_cmd()) --startup-file=no -e $code`
    env = copy(ENV)
    env["BENCH_THREADS"]      = string(nthreads)
    env["BENCH_N"]            = string(n)
    env["BENCH_TRIALS"]       = string(trials)
    env["BENCH_MODE"]         = mode
    env["BENCH_CHIP"]         = chip
    env["BENCH_LEVEL_INDEX"]  = string(level_index)
    env["BENCH_LEVEL_NAME"]   = levels[level_index + 1].name
    env["OPENBLAS_NUM_THREADS"] = string(nthreads)
    return strip(read(setenv(cmd, env), String))
end

"""
    sweep(; n=2048, trials=5, out="results.csv", modes=nothing,
          max_threads=nothing, plot=true) -> String

Run the DGEMM sweep on this machine's core topology and write results to `out`.

  - `n`: DGEMM matrix dimension
  - `trials`: timed DGEMM calls per point (best is reported)
  - `modes`: subset of modes to run (default: all; see `make_modes`)
  - `max_threads`: highest thread count within each level (default: level's core count)
  - `plot`: run `plot_results` on the output when done

Returns the output path.
"""
function sweep(; n::Integer=2048, trials::Integer=5, out::AbstractString="results.csv",
               modes=nothing, max_threads=nothing, plot::Bool=true)
    brand, levels = topology()
    chip = brand  # e.g., "Apple M1 Pro", "Apple M6 Max"
    total_cores = sum(l.cores for l in levels)

    allmodes = make_modes(levels)
    selected = modes === nothing ? sort(collect(keys(allmodes))) : String.(collect(modes))
    for m in selected
        haskey(allmodes, m) || error("unknown mode $(repr(m)); choose from $(join(sort(collect(keys(allmodes))), ", "))")
    end

    println("╭─ host")
    println("│  chip:         ", chip)
    println("│  brand:        ", brand)
    println("│  total:        ", total_cores, " cores")
    for level in levels
        @printf("│    level %d:    %2d × %s\n", level.index, level.cores, level.name)
    end
    println("├─ problem")
    @printf("│  DGEMM %d×%d Float64, best of %d trials\n", n, n, trials)
    println("│")
    println("├─ modes")
    for mode in sort(collect(keys(allmodes)))
        println("│    $mode:")
        println("│      ", allmodes[mode].desc)
    end
    println("│")
    println("├─ results → ", out)
    println("│")

    open(out, "w") do io
        # CSV header
        println(io, "chip,level_index,level_name,mode,threads,n,trials,gflops_best,gflops_median,wall_s")

        for mode in selected
            @printf("│\n│  %s\n", mode)
            @printf("│  %s\n", allmodes[mode].desc)

            # For each level this mode tests
            for lix in allmodes[mode].test_levels
                level = levels[lix + 1]  # Julia arrays are 1-indexed
                max_t = allmodes[mode].max_threads_per_level[lix]

                @printf("│    %-12s  ", level.name)
                println(io)  # blank line in CSV before each level's results

                # Sweep thread count from 1 to min(max_t, max_threads)
                maxthreads = max_threads === nothing ? max_t : min(max_t, Int(max_threads))
                for nt in 1:maxthreads
                    row = run_point(allmodes, mode, nt, lix, levels, chip, Int(n), Int(trials))
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
    println("╰─ wrote ", out)
    println()

    if plot
        println("plotting...")
        plot_results(out)
    end

    return out
end
