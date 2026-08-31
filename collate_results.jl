#!/usr/bin/env julia
#
# Collate DGEMM results from multiple architectures and create comparison plots.
#
# Usage:
#   julia --project=. collate_results.jl results-m1pro.csv results-m6max.csv ...
#   julia --project=. collate_results.jl results-*.csv
#
# Reads CSV files, groups by perf level, and creates comparison plots with one
# curve per chip overlaid on each level.

using Plots
using Printf
using DelimitedFiles
using Statistics

gr()

function getopt(args, name, default)
    pfx = "--$(name)="
    i = findfirst(a -> startswith(a, pfx), args)
    i === nothing ? default : args[i][length(pfx)+1:end]
end

const OUTBASE = getopt(ARGS, "out", "dgemm_collated")
const LEVEL_FILTER = getopt(ARGS, "level", "")

infiles = filter(a -> endswith(a, ".csv") && !startswith(a, "--"), ARGS)
length(infiles) > 0 || error("no CSV files provided")

# ---------------------------------------------------------------- palette
const SERIES_COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
const INK = "#0b0b0b"
const INK2 = "#52514e"
const GRIDC = "#d8d7d2"

# ----------------------------------------------------------- load all data

"""
    load_results(file) -> Vector of result rows

Load a CSV and return rows with chip, level, threads, gflops.
"""
function load_results(file)
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
        if LEVEL_FILTER != "" && level_nm != LEVEL_FILTER
            continue
        end

        threads = parse(Int, threads)
        gflops = parse(Float64, gflops)

        push!(rows, (; chip, level_nm, threads, gflops))
    end
    return rows
end

# Combine all results
allrows = []
for file in infiles
    @printf("loading %s...\n", file)
    append!(allrows, load_results(file))
end

println("total rows: ", length(allrows))
unique_chips = unique(r.chip for r in allrows)
unique_levels = unique(r.level_nm for r in allrows)

@printf("chips: %s\n", join(unique_chips, ", "))
@printf("levels: %s\n", join(unique_levels, ", "))
println()

# ------------------------------------------------- plot: throughput by chip & level

default(fontfamily="Helvetica", grid=true, gridcolor=GRIDC, gridalpha=1.0,
        gridlinewidth=0.6, foreground_color_axis=GRIDC,
        foreground_color_border=GRIDC, tickfontcolor=INK2,
        guidefontcolor=INK2, legendfontcolor=INK2, framestyle=:axes)

# Create one subplot pair (throughput + speedup) per level
nlevel = length(unique_levels)
plts = []

for (lv_idx, level) in enumerate(sort(unique_levels))
    # Filter to this level's data across all chips
    subset = [r for r in allrows if r.level_nm == level]
    isempty(subset) && continue

    chips_in_level = unique(r.chip for r in subset)

    # Top subplot: throughput
    plt_top = plot(size=(500, 320), legend=:bottomright,
                   title="$level cores",
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
if length(plts) > 0
    fig = plot(plts..., layout=grid(nlevel, 2), size=(1000, 320*nlevel), plot_title="")
    savefig(fig, OUTBASE * "_by_chip.png")
    savefig(fig, OUTBASE * "_by_chip.svg")
    println("wrote ", OUTBASE, "_by_chip.png/svg")
end

# ---------------------------------------------------------- summary table

println()
println("Summary (peak GFLOPS by level/chip):")
println()
for level in sort(unique_levels)
    println("  $level cores:")
    for chip in sort(unique_chips)
        subset = [r for r in allrows if r.chip == chip && r.level_nm == level]
        isempty(subset) && continue
        peak = maximum(r.gflops for r in subset)
        peak_threads = [r.threads for r in subset if r.gflops ≈ peak][1]
        @printf("    %-20s  %8.1f GFLOPS @ %d threads\n", chip, peak, peak_threads)
    end
    println()
end
