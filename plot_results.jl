#!/usr/bin/env julia
#
# Plot single-chip DGEMM results: combined view with efficiency and performance overlaid.
#
# Left: GFLOPS throughput with both core types on same plot, with ideal speedup references
# Right: Parallel speedup with both core types, with perfect scaling reference
#
# Usage: julia --project=. plot_results.jl [--in=results.csv] [--out=dgemm_cores]

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

const INFILE  = getopt(ARGS, "in", "results.csv")
const OUTBASE = getopt(ARGS, "out", "dgemm_cores")

# ---------------------------------------------------------------- palette
const SERIES_COLOR = ["#2a78d6", "#eb6834"]  # blue for performance, orange for efficiency
const INK          = "#0b0b0b"
const INK2         = "#52514e"
const GRIDC        = "#d8d7d2"

# ---------------------------------------------------------------- load data

raw, hdr = readdlm(INFILE, ',', header=true, String)
cols = Dict(strip(h) => i for (i, h) in enumerate(vec(hdr)))
chip_col    = raw[:, cols["chip"]]
level_col   = raw[:, cols["level_name"]]
mode_col    = raw[:, cols["mode"]]
threads_col = parse.(Int, raw[:, cols["threads"]])
gflops_col  = parse.(Float64, raw[:, cols["gflops_best"]])
n           = parse(Int, raw[1, cols["n"]])

# Filter out blank rows
valid = vec(chip_col .!= "")
chip_col    = chip_col[valid]
level_col   = level_col[valid]
mode_col    = mode_col[valid]
threads_col = threads_col[valid]
gflops_col  = gflops_col[valid]

levels = sort(unique(level_col))
modes_per_level = Dict(lv => unique(mode_col[level_col .== lv]) for lv in levels)

sysctl_i(k) = try parse(Int, strip(read(`sysctl -n $k`, String))) catch; 0 end
sysctl_s(k) = try strip(read(`sysctl -n $k`, String)) catch; "" end
const BRAND  = sysctl_s("machdep.cpu.brand_string")

# ------------------------------------------------- plot

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
                  title="DGEMM Throughput: Efficiency vs Performance Cores",
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
for (level_idx, level) in enumerate(levels)
    sel = level_col .== level
    lvl_threads = threads_col[sel]
    lvl_gflops = gflops_col[sel]
    lvl_modes = mode_col[sel]

    # Get all modes for this level and sort
    modes_list = sort(unique(lvl_modes))

    for mode in modes_list
        mode_sel = (level_col .== level) .& (mode_col .== mode)
        x = threads_col[mode_sel]
        y = gflops_col[mode_sel]

        # Sort by thread count
        perm = sortperm(x)
        x = x[perm]
        y = y[perm]

        speedup = y ./ y[1]

        # Use performance=blue, efficiency=orange
        c = level == "Performance" ? SERIES_COLOR[1] : SERIES_COLOR[2]

        peak_gflops = maximum(y)
        baseline = y[1]
        baselines["$level"] = baseline

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
    c = level == "Performance" ? SERIES_COLOR[1] : SERIES_COLOR[2]
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

savefig(fig, OUTBASE * ".png")
savefig(fig, OUTBASE * ".svg")
println("wrote ", OUTBASE, ".png and ", OUTBASE, ".svg")

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
