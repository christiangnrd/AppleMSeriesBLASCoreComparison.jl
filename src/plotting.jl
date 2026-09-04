# Plotting: single-chip results (plot_results) and multi-chip collation
# (collate_results).

using Plots
using DelimitedFiles

# ---------------------------------------------------------------- palette
# Tier hues are fixed per name (a chip's plot never repaints when a tier is
# absent) and taken from one validated categorical set; "All" is the whole
# machine rather than a tier, so it gets a neutral and a different marker.
const LEVEL_COLOR = Dict(
    "Super"       => "#e34948",  # red
    "Performance" => "#2a78d6",  # blue
    "Efficiency"  => "#eb6834",  # orange
    "All"         => "#6e6d69",  # grey
)
level_color(level)  = get(LEVEL_COLOR, level, "#1baf7a")  # aqua for unknown tiers
level_marker(level) = level == "All" ? :diamond : :circle

# Colours for the tiers of one plot: the fixed hue for known names, successive
# spare palette entries for anything else (user-supplied tiers such as
# "big"/"LITTLE"), so two custom tiers never share a colour.
function level_colors(levels)
    spare = filter(c -> !(c in values(LEVEL_COLOR)), SERIES_COLORS)
    colors, k = Dict{String,String}(), 0
    for lv in levels
        colors[lv] = haskey(LEVEL_COLOR, lv) ? LEVEL_COLOR[lv] : spare[mod1(k += 1, length(spare))]
    end
    return colors
end

# Tier order for legends and panels: fastest first, the whole machine last.
const LEVEL_ORDER = Dict("Super" => 0, "Performance" => 1, "Efficiency" => 2, "All" => 9)
level_rank(level) = (get(LEVEL_ORDER, level, 5), level)

# Plain-number ticks for a log axis (1-2-3-5-7 sequence) instead of 10^x labels.
function log_ticks(lo, hi)
    ticks = Float64[]
    for e in floor(Int, log10(lo)):ceil(Int, log10(hi)), m in (1, 2, 3, 5, 7)
        t = m * 10.0^e
        lo <= t <= hi && push!(ticks, t)
    end
    return ticks
end
const SERIES_COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
const INK   = "#0b0b0b"
const INK2  = "#52514e"
const GRIDC = "#d8d7d2"

"""
    plot_results(infile="results.csv"; outbase="dgemm_cores")

Plot single-chip DGEMM results: combined view with all perf levels overlaid,
plus the `All` (whole machine) curve when the sweep recorded one.

Left: GFLOPS throughput with all core types on same plot, with ideal speedup
references and, on the `All` curve, a marker where each tier's cores run out.
Right: parallel speedup with all core types, with perfect scaling reference.  Writes `outbase*".png"` and `outbase*".svg"` and prints a summary
table; returns the figure.
"""
function plot_results(infile::AbstractString="results.csv"; outbase::AbstractString="dgemm_cores")
    gr()

    # ------------------------------------------------------------ load data
    raw, hdr = readdlm(infile, ',', header=true, String)
    cols = Dict(strip(h) => i for (i, h) in enumerate(vec(hdr)))
    chip_col    = raw[:, cols["chip"]]
    lindex_col  = raw[:, cols["level_index"]]
    level_col   = raw[:, cols["level_name"]]
    mode_col    = raw[:, cols["mode"]]
    threads_col = parse.(Int, raw[:, cols["threads"]])
    gflops_col  = parse.(Float64, raw[:, cols["gflops_best"]])
    median_col  = parse.(Float64, raw[:, cols["gflops_median"]])

    # Filter out blank rows
    valid = vec(chip_col .!= "")
    chip_col    = chip_col[valid]
    lindex_col  = parse.(Int, lindex_col[valid])
    level_col   = level_col[valid]
    mode_col    = mode_col[valid]
    threads_col = threads_col[valid]
    gflops_col  = gflops_col[valid]
    median_col  = median_col[valid]

    # Tier order as the sweep recorded it (level index 0 = fastest), so custom
    # tier names sort correctly too; the whole machine goes last.
    first_index = Dict(lv => minimum(lindex_col[level_col .== lv]) for lv in unique(level_col))
    levels = sort(unique(level_col), by = lv -> (lv == "All" ? typemax(Int) : first_index[lv], lv))
    colors = level_colors(levels)
    modes_per_level = Dict(lv => unique(mode_col[level_col .== lv]) for lv in levels)

    # Tier sizes as the isolated sweeps saw them.  The tier markers and the
    # candidate table trust them only if the all-cores sweep reached their sum,
    # i.e. nothing was capped with max_threads.
    tiers = sort([(minimum(lindex_col[level_col .== lv]), lv, maximum(threads_col[level_col .== lv]))
                  for lv in levels if lv != "All"])
    has_all = "All" in levels
    all_uncapped = has_all && maximum(threads_col[level_col .== "All"]) == sum(t[3] for t in tiers)

    # ------------------------------------------------------------------ plot
    default(fontfamily="Helvetica", grid=true, gridcolor=GRIDC, gridalpha=1.0,
            gridlinewidth=0.6, foreground_color_axis=GRIDC,
            foreground_color_border=GRIDC, tickfontcolor=INK2,
            guidefontcolor=INK2, legendfontcolor=INK2, framestyle=:axes)

    # Compute ranges
    min_gflops = minimum(gflops_col[gflops_col .> 0])
    max_gflops = maximum(gflops_col)

    speedups = []
    for i in 1:length(mode_col)
        level_val = level_col[i]
        level_data_idx = (level_col .== level_val)
        level_gflops = gflops_col[level_data_idx]
        if length(level_gflops) > 0
            speedup = gflops_col[i] / level_gflops[1]
            push!(speedups, speedup)
        end
    end
    max_speedup_val = length(speedups) > 0 ? maximum(speedups) : 1.0

    # Create two main subplots
    plt_gflops = plot(size=(700, 400), legend=:topleft,
                      title="DGEMM Throughput by Core Type",
                      ylabel="GFLOPS (log scale)", xlabel="threads",
                      grid=true, gridcolor=GRIDC, gridalpha=1.0,
                      foreground_color_axis=GRIDC, foreground_color_border=GRIDC,
                      tickfontcolor=INK2, guidefontcolor=INK2,
                      legendfontcolor=INK2, framestyle=:axes,
                      background_color=:white, legend_background_color=:white,
                      legend_foreground_color=GRIDC, yscale=:log10,
                      left_margin=6Plots.mm, right_margin=50Plots.px)

    plt_speedup = plot(size=(700, 400), legend=false,
                       title="Parallel Speedup vs 1 Thread",
                       ylabel="speedup vs 1 thread", xlabel="threads",
                       grid=true, gridcolor=GRIDC, gridalpha=1.0,
                       foreground_color_axis=GRIDC, foreground_color_border=GRIDC,
                       tickfontcolor=INK2, guidefontcolor=INK2,
                       legendfontcolor=INK2, framestyle=:axes,
                       background_color=:white, legend_background_color=:white,
                       legend_foreground_color=GRIDC, left_margin=4Plots.mm)

    # Track baseline GFLOPS for ideal speedup lines
    baselines = Dict()

    # Plot data for each level
    for level in levels
        # Get all modes for this level and sort
        modes_list = sort(unique(mode_col[level_col .== level]))

        for mode in modes_list
            mode_sel = (level_col .== level) .& (mode_col .== mode)
            x = threads_col[mode_sel]
            y = gflops_col[mode_sel]

            # Sort by thread count
            perm = sortperm(x)
            x = x[perm]
            y = y[perm]

            speedup = y ./ y[1]

            c = colors[level]
            mk = level_marker(level)

            peak_gflops = maximum(y)
            baselines[level] = (y[1], maximum(x))

            # Plot throughput
            plot!(plt_gflops, x, y, color=c, linewidth=2.5, marker=mk,
                  markersize=5, markerstrokecolor=:white, markerstrokewidth=1.5,
                  label="$(level == "All" ? "All cores" : level): $(Int(round(peak_gflops))) GFLOPS")

            # Plot speedup
            plot!(plt_speedup, x, speedup, color=c, linewidth=2.5, marker=mk,
                  markersize=5, markerstrokecolor=:white, markerstrokewidth=1.5,
                  label="")
        end
    end

    # Add ideal speedup lines to GFLOPS plot (dashed), each over its own tier's range
    max_threads = maximum(threads_col)
    for (level, (baseline, mx)) in baselines
        c = colors[level]
        plot!(plt_gflops, 1:mx, baseline .* (1:mx), color=c, linewidth=1.5,
              linestyle=:dash, alpha=0.5, label="")
    end

    # Add perfect scaling reference to speedup plot
    plot!(plt_speedup, 1:max_threads, 1:max_threads, color=INK2, alpha=0.35,
          linestyle=:dot, linewidth=1.5, label="perfect scaling")

    # On the all-cores curve, mark where each tier's cores run out (normal-QoS
    # threads fill the fastest tier first).
    if all_uncapped
        for b in cumsum(getindex.(tiers, 3))[1:end-1]
            vline!(plt_gflops, [b + 0.5], color=INK2, alpha=0.3, linestyle=:dot, linewidth=1.2, label="")
            vline!(plt_speedup, [b + 0.5], color=INK2, alpha=0.3, linestyle=:dot, linewidth=1.2, label="")
        end
    end

    # Set axis limits
    xlims!(plt_gflops, (0.6, max_threads + 0.8))
    xlims!(plt_speedup, (0.6, max_threads + 0.8))
    ylims!(plt_gflops, (min_gflops * 0.8, max_gflops * 1.2))
    ylims!(plt_speedup, (0.8, max_speedup_val * 1.1))

    xticks!(plt_gflops, 1:max_threads)
    xticks!(plt_speedup, 1:max_threads)
    yt = log_ticks(min_gflops * 0.8, max_gflops * 1.2)
    yticks!(plt_gflops, yt, string.(round.(Int, yt)))

    # Combine into single figure
    fig = plot(plt_gflops, plt_speedup, layout=grid(1, 2), size=(1400, 420), plot_title="")

    savefig(fig, outbase * ".png")
    savefig(fig, outbase * ".svg")
    println("wrote ", outbase, ".png and ", outbase, ".svg")

    # Print summary table
    println()
    println("Summary (peak GFLOPS by level):")
    println()
    for level in levels
        println("  $level cores:")
        for mode in sort(modes_per_level[level])
            sel = (level_col .== level) .& (mode_col .== mode)
            y = gflops_col[sel]
            x = threads_col[sel]
            peak = maximum(y)
            peak_threads = x[argmax(y)]
            @printf("    %-12s  %8.1f GFLOPS @ %d threads\n", mode, peak, peak_threads)
        end
        println()
    end

    # The question for LinearAlgebra's default: what does the whole machine give
    # at each candidate thread count?  Candidates are the tier boundaries (fastest
    # tier only, fastest two, ...), total-1 and total, plus the measured peak.
    if has_all && !all_uncapped
        println("  All cores: sweep was capped below the machine total, candidate table skipped")
        println()
    elseif has_all
        sel = level_col .== "All"
        x, y, ymed = threads_col[sel], gflops_col[sel], median_col[sel]
        total = maximum(x)
        candidates = Dict{Int,String}()
        for k in 1:length(tiers)-1
            candidates[sum(t[3] for t in tiers[1:k])] = join((t[2] for t in tiers[1:k]), "+") * " only"
        end
        candidates[total - 1] = get(candidates, total - 1, "") * " total-1"
        candidates[total]     = "total"
        candidates[x[argmax(y)]] = get(candidates, x[argmax(y)], "") * " peak"
        println("  All cores (what BLAS.set_num_threads(n) gives):")
        for k in sort(collect(keys(candidates)))
            i = findfirst(==(k), x)
            i === nothing && continue
            @printf("    %2d threads  %8.1f GFLOPS best  %8.1f median   %s\n", k, y[i], ymed[i], strip(candidates[k]))
        end
        println()
    end

    return fig
end

"""
    load_results(file; level="") -> Vector of result rows

Load a CSV and return rows with chip, level index and name, threads, gflops.  A non-empty
`level` keeps only rows from that perf level.
"""
function load_results(file; level::AbstractString="")
    raw, hdr = readdlm(file, ',', header=true, String)
    cols = Dict(strip(h) => i for (i, h) in enumerate(vec(hdr)))
    rows = []
    for i in 1:size(raw, 1)
        chip = strip(raw[i, cols["chip"]])
        level_ix = raw[i, cols["level_index"]]
        level_nm = strip(raw[i, cols["level_name"]])
        threads = raw[i, cols["threads"]]
        gflops = raw[i, cols["gflops_best"]]

        # Skip blank lines
        chip == "" && continue

        # Apply filters
        if level != "" && level_nm != level
            continue
        end

        level_ix = parse(Int, level_ix)
        threads = parse(Int, threads)
        gflops = parse(Float64, gflops)

        push!(rows, (; chip, level_ix, level_nm, threads, gflops))
    end
    return rows
end

"""
    collate_results(infiles; outbase="dgemm_collated", level="")

Collate DGEMM results from multiple architectures and create comparison plots:
one throughput + speedup subplot pair per perf level, with one curve per chip
overlaid.  A non-empty `level` filters to that level only.  Writes
`outbase*"_by_chip.png"`/`.svg` and prints a summary table; returns the figure
(or `nothing` if there was nothing to plot).
"""
function collate_results(infiles::AbstractVector{<:AbstractString};
                         outbase::AbstractString="dgemm_collated", level::AbstractString="")
    gr()

    # Combine all results
    allrows = []
    for file in infiles
        @printf("loading %s...\n", file)
        append!(allrows, load_results(file; level))
    end

    println("total rows: ", length(allrows))
    unique_chips = unique(r.chip for r in allrows)
    unique_levels = unique(r.level_nm for r in allrows)

    @printf("chips: %s\n", join(unique_chips, ", "))
    @printf("levels: %s\n", join(unique_levels, ", "))
    println()

    # ------------------------------------- plot: throughput by chip & level
    default(fontfamily="Helvetica", grid=true, gridcolor=GRIDC, gridalpha=1.0,
            gridlinewidth=0.6, foreground_color_axis=GRIDC,
            foreground_color_border=GRIDC, tickfontcolor=INK2,
            guidefontcolor=INK2, legendfontcolor=INK2, framestyle=:axes)

    # One colour per chip, fixed across panels
    chip_colors = Dict(chip => SERIES_COLORS[mod1(i, length(SERIES_COLORS))]
                       for (i, chip) in enumerate(sort(unique_chips)))

    # Create one subplot pair (throughput + speedup) per level
    nlevel = length(unique_levels)
    plts = []

    for lvl in sort(unique_levels, by=level_rank)
        # Filter to this level's data across all chips
        subset = [r for r in allrows if r.level_nm == lvl]
        isempty(subset) && continue

        chips_in_level = unique(r.chip for r in subset)

        # Top subplot: throughput
        plt_top = plot(size=(500, 320), legend=:bottomright,
                       title="$lvl cores",
                       ylabel="GFLOPS (log scale)",
                       grid=true, gridcolor=GRIDC, gridalpha=1.0,
                       foreground_color_axis=GRIDC, foreground_color_border=GRIDC,
                       tickfontcolor=INK2, guidefontcolor=INK2,
                       legendfontcolor=INK2, framestyle=:axes,
                       background_color=:white, legend_background_color=:white,
                       legend_foreground_color=GRIDC, yscale=:log10)

        # Bottom subplot: speedup
        plt_bot = plot(size=(500, 320), legend=false,
                       xlabel="threads", ylabel="speedup",
                       grid=true, gridcolor=GRIDC, gridalpha=1.0,
                       foreground_color_axis=GRIDC, foreground_color_border=GRIDC,
                       tickfontcolor=INK2, guidefontcolor=INK2,
                       legendfontcolor=INK2, framestyle=:axes,
                       background_color=:white, legend_background_color=:white,
                       legend_foreground_color=GRIDC)

        # Plot each chip as a separate curve on this level
        for (chip_idx, chip) in enumerate(sort(chips_in_level))
            chip_data = [r for r in subset if r.chip == chip]
            sort!(chip_data, by=r -> r.threads)
            x = [r.threads for r in chip_data]
            y = [r.gflops for r in chip_data]

            speedup = y ./ y[1]

            c = chip_colors[chip]

            plot!(plt_top, x, y, color=c, linewidth=2, marker=:circle,
                  markersize=4, markerstrokecolor=:white, markerstrokewidth=1,
                  label=chip)
            plot!(plt_bot, x, speedup, color=c, linewidth=2, marker=:circle,
                  markersize=4, markerstrokecolor=:white, markerstrokewidth=1,
                  label="")
        end

        ys = [r.gflops for r in subset]
        ylims!(plt_top, (minimum(ys) * 0.8, maximum(ys) * 1.2))
        yt = log_ticks(minimum(ys) * 0.8, maximum(ys) * 1.2)
        yticks!(plt_top, yt, string.(round.(Int, yt)))

        # Add perfect scaling reference on speedup panel
        maxthreads = maximum(r.threads for r in subset)
        plot!(plt_bot, 1:maxthreads, 1:maxthreads, color=INK2, alpha=0.35,
              linestyle=:dot, linewidth=1.2, label="")

        xlims!(plt_top, (0.6, maxthreads + 0.6))
        xlims!(plt_bot, (0.6, maxthreads + 0.6))
        xticks!(plt_top, 1:maxthreads)
        xticks!(plt_bot, 1:maxthreads)

        push!(plts, plt_top)
        push!(plts, plt_bot)
    end

    # Combine into grid
    fig = nothing
    if length(plts) > 0
        fig = plot(plts..., layout=grid(nlevel, 2), size=(1000, 320*nlevel), plot_title="",
                   left_margin=6Plots.mm)
        savefig(fig, outbase * "_by_chip.png")
        savefig(fig, outbase * "_by_chip.svg")
        println("wrote ", outbase, "_by_chip.png/svg")
    end

    # ------------------------------------------------------ summary table
    println()
    println("Summary (peak GFLOPS by level/chip):")
    println()
    for lvl in sort(unique_levels, by=level_rank)
        println("  $lvl cores:")
        for chip in sort(unique_chips)
            subset = [r for r in allrows if r.chip == chip && r.level_nm == lvl]
            isempty(subset) && continue
            peak = maximum(r.gflops for r in subset)
            peak_threads = [r.threads for r in subset if r.gflops ≈ peak][1]
            @printf("    %-20s  %8.1f GFLOPS @ %d threads\n", chip, peak, peak_threads)
        end
        println()
    end

    return fig
end
