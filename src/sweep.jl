# Sweep orchestration for the OpenBLAS DGEMM core-tier sweep.
#
# On Apple silicon the topology comes from sysctl and works for any number of
# perf levels: M1–M4 report Performance + Efficiency, M5 Pro/Max report Super +
# Performance (no Efficiency cores; the ten Performance cores of an M5 Pro are
# two clusters of five), and M6 is expected to add a third tier.  Each level is
# measured in isolation at normal QoS by keeping every faster core busy with a
# spinner thread (see occupier.jl), and an "all" mode uses the whole machine
# the way `BLAS.set_num_threads(n)` does.
#
# Other systems report no tiers, so detection falls back to one tier of
# `Sys.CPU_THREADS` cores.  The caller can supply the tiers instead
# (`sweep(levels=...)`, `driver.jl --levels=...`); a tier given with a cpu list
# is isolated on Linux by pinning the benchmark to it with `taskset`, which
# takes the place of the occupier there.
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
    topology(; chip=nothing, levels=nothing) -> (chip::String, levels::Vector{NamedTuple})

Return the core topology as a list of levels from fastest to slowest, each an
`(index, name, cores, cluster, cpus)` tuple: level index (0 = fastest), tier
name, logical core count, cores per cluster (0 when unknown) and the cpu list
the tier is pinned to (`nothing` unless supplied).

Detection: on Apple silicon `hw.nperflevels` gives the number of tiers and
`hw.perflevelN.{name,logicalcpu,cpusperl2}` each tier's name, core count and
cluster size.  Other systems report no tiers, so the result is a single
`Performance` level of `Sys.CPU_THREADS` cores, with the chip name taken from
`/proc/cpuinfo` on Linux.

Overrides: `levels` replaces detection entirely and is either a spec string
(see [`parse_levels`](@ref)) or a vector of named tuples with `name` and
`cores` and optionally `cluster` and `cpus` (see [`normalize_levels`](@ref)).
`chip` replaces the detected chip label.
"""
function topology(; chip=nothing, levels=nothing)
    if levels === nothing
        brand, lv = Sys.isapple() ? apple_topology() : generic_topology()
        isempty(lv) && ((brand, lv) = generic_topology())
    else
        brand, lv = detect_chip(), normalize_levels(levels)
    end
    chip === nothing || (brand = String(chip))
    return csv_safe(brand), lv
end

# Chip names go into the first CSV column unquoted.
csv_safe(s) = String(strip(replace(s, ',' => ' ')))

function apple_topology()
    brand   = detect_chip()
    nlevels = sysctl("hw.nperflevels")
    levels = []
    for i in 0:(nlevels-1)
        cores   = sysctl("hw.perflevel$(i).logicalcpu")
        name    = sysctl_str("hw.perflevel$(i).name")
        cluster = sysctl("hw.perflevel$(i).cpusperl2")
        cores > 0 && push!(levels, (; index=i, name, cores, cluster, cpus=nothing))
    end
    return brand, levels
end

# No tier information from the OS: one tier of every logical cpu.
generic_topology() =
    detect_chip(), [(; index=0, name="Performance", cores=Sys.CPU_THREADS, cluster=0, cpus=nothing)]

"""
    detect_chip() -> String

Best-effort chip label: `machdep.cpu.brand_string` on macOS, the `model name`
(x86) or `Model`/`Hardware` (ARM boards) line of `/proc/cpuinfo` on Linux,
otherwise what `Sys.cpu_info` reports; `"unknown"` if none of those work.
"""
function detect_chip()
    name = ""
    if Sys.isapple()
        name = sysctl_str("machdep.cpu.brand_string")
    elseif Sys.islinux() && isfile("/proc/cpuinfo")
        for line in eachline("/proc/cpuinfo")
            m = match(r"^(model name|Model|Hardware)\s*:\s*(.+)$", line)
            m === nothing && continue
            name = strip(m.captures[2])
            break
        end
    end
    if isempty(name)
        name = try strip(Sys.cpu_info()[1].model) catch; "" end
    end
    return isempty(name) ? "unknown" : String(name)
end

"""
    parse_levels(spec::AbstractString) -> Vector{NamedTuple}

Parse a tier list written as `name:cores[:cpus],name:cores[:cpus],...`, fastest
tier first.  `cores` is the thread count the tier's sweep goes up to.  `cpus`
is optional: the cpus the tier consists of, in `taskset` syntax with `+` in
place of `,` (`0-7`, `0+2+4+6`, `0-3+8-11`).  On Linux the benchmark is pinned
to those cpus, which is how a lower tier is measured in isolation there.

    parse_levels("Performance:8:0-15,Efficiency:8:16-23")
    parse_levels("big:4,LITTLE:4")
"""
function parse_levels(spec::AbstractString)
    levels = []
    for item in split(spec, ',')
        f = split(strip(item), ':')
        2 <= length(f) <= 3 || error("bad tier $(repr(strip(item))): expected name:cores[:cpus]")
        cores = tryparse(Int, strip(f[2]))
        cores === nothing && error("bad core count in tier $(repr(strip(item)))")
        cpus = length(f) == 3 ? replace(strip(f[3]), '+' => ',') : nothing
        push!(levels, (; name=strip(f[1]), cores, cpus))
    end
    return normalize_levels(levels)
end

"""
    normalize_levels(levels) -> Vector{NamedTuple}

Bring caller-supplied tiers into the form `topology` returns.  A string goes
through `parse_levels`.  A vector of named tuples needs `name` and `cores` and
may give `cluster` (cores per cluster, informational) and `cpus` (a
`taskset`-style string such as `"0-7"`, or a range/vector of cpu numbers).
Levels are indexed in the order given, fastest first.
"""
function normalize_levels(levels)
    levels isa AbstractString && return parse_levels(levels)
    isempty(levels) && error("no tiers given")
    out = []
    for (i, l) in enumerate(levels)
        name    = String(strip(String(l.name)))
        cores   = Int(l.cores)
        cluster = hasproperty(l, :cluster) ? Int(l.cluster) : 0
        cpus    = hasproperty(l, :cpus) ? cpu_list(l.cpus) : nothing
        isempty(name) && error("tier $i has no name")
        occursin(r"[,:]", name) && error("tier name $(repr(name)) must not contain ',' or ':'")
        lowercase(name) == "all" && error("tier name \"All\" is reserved for the whole-machine mode")
        cores >= 1 || error("tier $(repr(name)): cores must be at least 1")
        if cpus !== nothing && cores > cpu_count(cpus)
            error("tier $(repr(name)): $cores cores but cpu list $(repr(cpus)) has only $(cpu_count(cpus))")
        end
        push!(out, (; index=i-1, name, cores, cluster, cpus))
    end
    names = [lowercase(l.name) for l in out]
    allunique(names) || error("tier names must be unique (case-insensitive): $(join(names, ", "))")
    return out
end

cpu_list(::Nothing) = nothing
cpu_list(s::AbstractString) = String(strip(s))
cpu_list(cpus) = join(Int.(collect(cpus)), ",")   # range or vector of cpu numbers

# Number of cpus in a taskset-style list ("0-3,8,10-11" -> 7); validates it.
function cpu_count(list::AbstractString)
    n = 0
    for part in split(list, ',')
        m = match(r"^\s*(\d+)(?:-(\d+))?\s*$", part)
        m === nothing && error("bad cpu list $(repr(list)): use e.g. 0-7 or 0,2,4")
        lo = parse(Int, m.captures[1])
        hi = m.captures[2] === nothing ? lo : parse(Int, m.captures[2])
        hi >= lo || error("bad cpu range $(repr(strip(part))) in $(repr(list))")
        n += hi - lo + 1
    end
    return n
end

# `taskset` pins a process to a cpu list (Linux); `nothing` where unavailable.
pin_command() = Sys.islinux() ? Sys.which("taskset") : nothing

"""
    make_modes(levels) -> Dict{String, NamedTuple}

Generate one mode per perf level plus `all`.  A level's mode sweeps 1 to that
level's core count; `all` sweeps 1 to the total core count with nothing
occupied or pinned, which is what `BLAS.set_num_threads(n)` gives a user.

How a lower level is isolated depends on the platform.  On macOS the occupier
keeps every faster core busy (`occupy` spinner threads at user-interactive
QoS) so the normal-QoS benchmark lands on the level under test.  On Linux a
level given with a cpu list is pinned to it with `taskset` (`cpus`); a level
without one cannot be isolated and is measured wherever the scheduler puts it,
which its description says.
"""
function make_modes(levels)
    modes = Dict{String,Any}()
    pinner = pin_command()
    qos = Sys.isapple() ? ", normal QoS" : ""
    faster = 0
    for level in levels
        pinned = level.cpus !== nothing && pinner !== nothing
        if level.cpus !== nothing && !pinned
            @warn "cpu list for tier $(repr(level.name)) ignored: " *
                  (Sys.isapple() ? "macOS has no cpu affinity" : "taskset not found")
        end
        how = if pinned
            ", pinned to cpus $(level.cpus)"
        elseif faster == 0
            ""
        elseif Sys.isapple()
            ", $faster faster core$(faster == 1 ? "" : "s") kept busy"
        else
            ", NOT isolated (give this tier a cpu list to pin it)"
        end
        modes[lowercase(level.name)] = (
            desc = "$(level.name) cores only ($(level.cores) cores)" * qos * how,
            level_index = level.index,
            level_name  = level.name,
            max_threads = level.cores,
            occupy      = (Sys.isapple() && !pinned) ? faster : 0,
            cpus        = pinned ? level.cpus : nothing,
        )
        faster += level.cores
    end
    if length(levels) > 1
        modes["all"] = (
            desc = "all $faster cores" * qos * " (what BLAS.set_num_threads gives)",
            level_index = -1,
            level_name  = "All",
            max_threads = faster,
            occupy      = 0,
            cpus        = nothing,
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
load) to keep startup light.  When the mode carries a cpu list the worker is
pinned to it with `taskset`.
"""
function run_point(mode::AbstractString, nthreads::Int, m, chip::AbstractString,
                   n::Int, trials::Int)
    code = "include($(repr(WORKER_FILE))); worker_main()"
    cmd = `$(Base.julia_cmd()) --startup-file=no -e $code`
    cpus, pinner = get(m, :cpus, nothing), pin_command()
    if cpus !== nothing && pinner !== nothing
        cmd = `$pinner -c $cpus $cmd`
    end
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
          max_threads=nothing, plot=true, chip=nothing, levels=nothing) -> String

Run the DGEMM sweep on this machine's core topology and write results to `out`.

  - `n`: DGEMM matrix dimension
  - `trials`: timed DGEMM calls per point (best is reported)
  - `modes`: subset of modes to run (default: all; see `make_modes`)
  - `max_threads`: highest thread count within each mode (default: the mode's core count)
  - `plot`: run `plot_results` on the output when done
  - `chip`: label for the chip in the CSV (default: detected)
  - `levels`: the core tiers to sweep instead of detecting them, as a spec
    string `"name:cores[:cpus],..."` or a vector of named tuples (see
    [`topology`](@ref)); on Linux a tier with a cpu list is pinned to it

Returns the output path.
"""
function sweep(; n::Integer=2048, trials::Integer=5, out::AbstractString="results.csv",
               modes=nothing, max_threads=nothing, plot::Bool=true,
               chip=nothing, levels=nothing)
    supplied = levels !== nothing
    chip, levels = topology(; chip, levels)  # e.g., "Apple M1 Pro", "Apple M5 Pro"
    total_cores = sum(l.cores for l in levels)

    allmodes = make_modes(levels)
    order = mode_order(levels, allmodes)
    selected = modes === nothing ? order : String.(collect(modes))
    for m in selected
        haskey(allmodes, m) || error("unknown mode $(repr(m)); choose from $(join(order, ", "))")
    end

    println("╭─ host")
    println("│  chip:         ", chip)
    println("│  topology:     ", supplied ? "supplied" : "detected")
    println("│  total:        ", total_cores, " cores")
    for level in levels
        notes = String[]
        if level.cluster > 0
            nclusters = cld(level.cores, level.cluster)
            push!(notes, "$nclusters cluster$(nclusters == 1 ? "" : "s") of $(level.cluster)")
        end
        level.cpus === nothing || push!(notes, "cpus $(level.cpus)")
        @printf("│    level %d:    %2d × %-12s%s\n", level.index, level.cores, level.name,
                isempty(notes) ? "" : " (" * join(notes, ", ") * ")")
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
