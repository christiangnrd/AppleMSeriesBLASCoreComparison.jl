# Plotting: single-chip results (plot_results) and multi-chip collation
# (collate_results).

using Plots
using DelimitedFiles

# ---------------------------------------------------------------- palette
const LEVEL_COLOR = Dict(
    "Super"       => "#4a3aa7",  # purple
    "Performance" => "#2a78d6",  # blue
    "Efficiency"  => "#eb6834",  # orange
)
level_color(level) = get(LEVEL_COLOR, level, "#1baf7a")  # green for unknown tiers
const SERIES_COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
const INK   = "#0b0b0b"
const INK2  = "#52514e"
const GRIDC = "#d8d7d2"

"""
    plot_results(infile="results.csv"; outbase="dgemm_cores")

Plot single-chip DGEMM results: combined view with all perf levels overlaid.

Left: GFLOPS throughput with all core types on same plot, with ideal speedup
references.  Right: parallel speedup with all core types, with perfect scaling
reference.  Writes `outbase*".png"` and `outbase*".svg"` and prints a summary
table; returns the figure.
"""
function plot_results(infile::AbstractString="results.csv"; outbase::AbstractString="dgemm_cores")
    gr()

    # ------------------------------------------------------------ load data
    raw, hdr = readdlm(infile, ',', header=true, String)
    cols = Dict(strip(h) => i for (i, h) in enumerate(vec(hdr)))
    chip_col    = raw[:, cols["chip"]]
    level_col   = raw[:, cols["level_name"]]
    mode_col    = raw[:, cols["mode"]]
    threads_col = parse.(Int, raw[:, cols["threads"]])
    gflops_col  = parse.(Float64, raw[:, cols["gflops_best"]])

    # Filter out blank rows
    valid = vec(chip_col .!= "")
    chip_col    = chip_col[valid]
    level_col   = level_col[valid]
    mode_col    = mode_col[valid]
    threads_col = threads_col[valid]
    gflops_col  = gflops_col[valid]

    levels = sort(unique(level_col))
    modes_per_level = Dict(lv => unique(mode_col[level_col .== lv]) for lv in levels)

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
                      right_margin=50Plots.px)

    plt_speedup = plot(size=(700, 400), legend=false,
                       title="Parallel Speedup within Each Cluster",
                       ylabel="speedup vs 1 thread", xlabel="threads",
                       grid=true, gridcolor=GRIDC, gridalpha=1.0,
                       foreground_color_axis=GRIDC, foreground_color_border=GRIDC,
                       tickfontcolor=INK2, guidefontcolor=INK2,
                       legendfontcolor=INK2, framestyle=:axes,
                       background_color=:white, legend_background_color=:white,
                       legend_foreground_color=GRIDC)

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

            c = level_color(level)

            peak_gflops = maximum(y)
            baselines["$level"] = y[1]

            # Plot throughput
            plot!(plt_gflops, x, y, color=c, linewidth=2.5, marker=:circle,
                  markersize=5, markerstrokecolor=:white, markerstrokewidth=1.5,
                  label="$level: $(Int(round(peak_gflops))) GFLOPS")

            # Plot speedup
            plot!(plt_speedup, x, speedup, color=c, linewidth=2.5, marker=:circle,
                  markersize=5, markerstrokecolor=:white, markerstrokewidth=1.5,
                  label="")
        end
    end

    # Add ideal speedup lines to GFLOPS plot (dashed)
    max_threads = maximum(threads_col)
    for (level, baseline) in baselines
        c = level_color(level)
        ideal_gflops = baseline .* (1:max_threads)
        plot!(plt_gflops, 1:max_threads, ideal_gflops, color=c, linewidth=1.5,
              linestyle=:dash, alpha=0.5, label="")
    end

    # Add perfect scaling reference to speedup plot
    plot!(plt_speedup, 1:max_threads, 1:max_threads, color=INK2, alpha=0.35,
          linestyle=:dot, linewidth=1.5, label="perfect scaling")

    # Set axis limits
    xlims!(plt_gflops, (0.6, max_threads + 0.8))
    xlims!(plt_speedup, (0.6, max_threads + 0.8))
    ylims!(plt_gflops, (min_gflops * 0.8, max_gflops * 1.2))
    ylims!(plt_speedup, (0.8, max_speedup_val * 1.1))

    xticks!(plt_gflops, 1:max_threads)
    xticks!(plt_speedup, 1:max_threads)

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

    return fig
end

"""
    load_results(file; level="") -> Vector of result rows

Load a CSV and return rows with chip, level, threads, gflops.  A non-empty
`level` keeps only rows from that perf level.
"""
function load_results(file; level::AbstractString="")
    raw, hdr = readdlm(file, ',', header=true, String)
    cols = Dict(strip(h) => i for (i, h) in enumerate(vec(hdr)))
    rows = []
    for i in 1:size(raw, 1)
        chip = strip(raw[i, cols["chip"]])
        level_nm = strip(raw[i, cols["level_name"]])
        threads = raw[i, cols["threads"]]
        gflops = raw[i, cols["gflops_best"]]

        # Skip blank lines
        chip == "" && continue

        # Apply filters
        if level != "" && level_nm != level
            continue
        end

        threads = parse(Int, threads)
        gflops = parse(Float64, gflops)

        push!(rows, (; chip, level_nm, threads, gflops))
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

    # Create one subplot pair (throughput + speedup) per level
    nlevel = length(unique_levels)
    plts = []

    for lvl in sort(unique_levels)
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

            c = SERIES_COLORS[mod1(chip_idx, length(SERIES_COLORS))]

            plot!(plt_top, x, y, color=c, linewidth=2, marker=:circle,
                  markersize=4, markerstrokecolor=:white, markerstrokewidth=1,
                  label=chip)
            plot!(plt_bot, x, speedup, color=c, linewidth=2, marker=:circle,
                  markersize=4, markerstrokecolor=:white, markerstrokewidth=1,
                  label="")
        end

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
        fig = plot(plts..., layout=grid(nlevel, 2), size=(1000, 320*nlevel), plot_title="")
        savefig(fig, outbase * "_by_chip.png")
        savefig(fig, outbase * "_by_chip.svg")
        println("wrote ", outbase, "_by_chip.png/svg")
    end

    # ------------------------------------------------------ summary table
    println()
    println("Summary (peak GFLOPS by level/chip):")
    println()
    for lvl in sort(unique_levels)
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
