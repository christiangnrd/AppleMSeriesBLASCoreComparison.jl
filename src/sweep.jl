# Sweep orchestration for the OpenBLAS DGEMM core-tier sweep on Apple silicon.
#
# Works for any number of perf levels: M1–M4 report Performance + Efficiency,
# M5 Pro/Max report Super + Performance (no Efficiency cores; the ten
# Performance cores of an M5 Pro are two clusters of five), and M6 is expected
# to add a third tier.  Each level is measured in isolation at normal QoS by
# keeping every faster core busy with a spinner thread (see occupier.jl), and
# an "all" mode uses the whole machine the way `BLAS.set_num_threads(n)` does.
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

Read the Apple silicon core topology.  `hw.nperflevels` reports the number of
tiers; levels are indexed from 0 (fastest) upward.  Each level gives its name
(Super, Performance, Efficiency), its logical core count and the number of
cores per cluster (`cpusperl2`, the cores sharing one L2).

Returns a list of (index, name, cores, cluster) tuples from fastest to slowest.
"""
function topology()
    brand   = sysctl_str("machdep.cpu.brand_string")
    nlevels = sysctl("hw.nperflevels")

    levels = []
    for i in 0:(nlevels-1)
        cores   = sysctl("hw.perflevel$(i).logicalcpu")
        name    = sysctl_str("hw.perflevel$(i).name")
        cluster = sysctl("hw.perflevel$(i).cpusperl2")
        cores > 0 && push!(levels, (; index=i, name, cores, cluster))
    end

    return brand, levels
end

"""
    make_modes(levels) -> Dict{String, NamedTuple}

Generate one mode per perf level plus `all`.  A level's mode sweeps 1 to that
level's core count at normal QoS while the occupier keeps every faster core
busy (`occupy` spinner threads), so the benchmark lands on the level under
test.  `all` sweeps 1 to the total core count with nothing occupied, which is
what `BLAS.set_num_threads(n)` gives a user.
"""
function make_modes(levels)
    modes = Dict{String,Any}()
    faster = 0
    for level in levels
        modes[lowercase(level.name)] = (
            desc = "$(level.name) cores only ($(level.cores) cores), normal QoS" *
                   (faster > 0 ? ", $faster faster core$(faster == 1 ? "" : "s") kept busy" : ""),
            level_index = level.index,
            level_name  = level.name,
            max_threads = level.cores,
            occupy      = faster,
        )
        faster += level.cores
    end
    if length(levels) > 1
        modes["all"] = (
            desc = "all $faster cores, normal QoS (what BLAS.set_num_threads gives)",
            level_index = -1,
            level_name  = "All",
            max_threads = faster,
            occupy      = 0,
        )
    end
    return modes
end

# Fastest level first, then all: the order the sweep runs and prints in.
mode_order(levels, modes) =
    filter(m -> haskey(modes, m), [[lowercase(l.name) for l in levels]; "all"])

const WORKER_FILE   = joinpath(@__DIR__, "worker.jl")
const OCCUPIER_FILE = joinpath(@__DIR__, "occupier.jl")

"""
    start_occupier(ncores) -> Process or nothing

Start `ncores` spinner threads at user-interactive QoS (see occupier.jl) and
return the process once they are running; `nothing` when `ncores == 0`.
"""
function start_occupier(ncores::Int)
    ncores > 0 || return nothing
    code = "include($(repr(OCCUPIER_FILE))); occupier_main()"
    proc = open(`$(Base.julia_cmd()) --startup-file=no -t $(ncores + 1) -e $code`, "r+")
    line = Ref("")
    reader = @async line[] = readline(proc)
    if timedwait(() -> istaskdone(reader), 60.0) != :ok || line[] != "ready"
        close(proc.in)  # the normal stop path; SIGKILL if the child never got that far
        timedwait(() -> !process_running(proc), 5.0) == :ok || kill(proc, Base.SIGKILL)
        error("occupier did not start (got $(repr(line[])))")
    end
    sleep(0.5)  # let the spinners settle onto the fast cores
    return proc
end

"""
    stop_occupier(proc)

Close the occupier's stdin, which ends its spinners, and wait for it to exit.
"""
function stop_occupier(proc)
    proc === nothing && return
    close(proc.in)
    wait(proc)
end

"""
    run_point(mode, nthreads, m, chip, n, trials) -> String

Launch one worker process for mode `m` (an entry of `make_modes`) and return
the CSV row it printed.  The worker only `include`s worker.jl (no package
load) to keep startup light.
"""
function run_point(mode::AbstractString, nthreads::Int, m, chip::AbstractString,
                   n::Int, trials::Int)
    code = "include($(repr(WORKER_FILE))); worker_main()"
    cmd = `$(Base.julia_cmd()) --startup-file=no -e $code`
    env = copy(ENV)
    env["BENCH_THREADS"]      = string(nthreads)
    env["BENCH_N"]            = string(n)
    env["BENCH_TRIALS"]       = string(trials)
    env["BENCH_MODE"]         = mode
    env["BENCH_CHIP"]         = chip
    env["BENCH_LEVEL_INDEX"]  = string(m.level_index)
    env["BENCH_LEVEL_NAME"]   = m.level_name
    env["BENCH_OCCUPIED"]     = string(m.occupy)
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
  - `max_threads`: highest thread count within each mode (default: the mode's core count)
  - `plot`: run `plot_results` on the output when done

Returns the output path.
"""
function sweep(; n::Integer=2048, trials::Integer=5, out::AbstractString="results.csv",
               modes=nothing, max_threads=nothing, plot::Bool=true)
    brand, levels = topology()
    chip = brand  # e.g., "Apple M1 Pro", "Apple M5 Pro"
    total_cores = sum(l.cores for l in levels)

    allmodes = make_modes(levels)
    order = mode_order(levels, allmodes)
    selected = modes === nothing ? order : String.(collect(modes))
    for m in selected
        haskey(allmodes, m) || error("unknown mode $(repr(m)); choose from $(join(order, ", "))")
    end

    println("╭─ host")
    println("│  chip:         ", chip)
    println("│  total:        ", total_cores, " cores")
    for level in levels
        nclusters = level.cluster > 0 ? cld(level.cores, level.cluster) : 1
        @printf("│    level %d:    %2d × %-12s (%d cluster%s of %d)\n", level.index, level.cores,
                level.name, nclusters, nclusters == 1 ? "" : "s", level.cluster)
    end
    println("├─ problem")
    @printf("│  DGEMM %d×%d Float64, best of %d trials\n", n, n, trials)
    println("│")
    println("├─ modes")
    for mode in order
        println("│    $mode:")
        println("│      ", allmodes[mode].desc)
    end
    println("│")
    println("├─ results → ", out)

    open(out, "w") do io
        # CSV header
        println(io, "chip,level_index,level_name,mode,threads,n,trials,gflops_best,gflops_median,wall_s,occupied")

        for mode in selected
            m = allmodes[mode]
            @printf("│\n│  %s\n", mode)
            @printf("│  %s\n", m.desc)
            println(io)  # blank line in CSV before each mode's results

            maxthreads = max_threads === nothing ? m.max_threads : min(m.max_threads, Int(max_threads))
            occ = start_occupier(m.occupy)
            try
                for nt in 1:maxthreads
                    row = run_point(mode, nt, m, chip, Int(n), Int(trials))
                    println(io, row); flush(io)
                    f = split(row, ',')
                    best, med = parse(Float64, f[8]), parse(Float64, f[9])
                    @printf("│    %2d thr  %8.1f GFLOPS  %8.1f med  %6.1f GF/thr\n",
                            nt, best, med, best / nt)
                end
            finally
                stop_occupier(occ)
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
