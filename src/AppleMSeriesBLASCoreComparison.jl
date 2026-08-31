module AppleMSeriesBLASCoreComparison

export sweep, topology, make_modes, dgemm_gflops, plot_results, collate_results

include("worker.jl")    # dgemm_gflops, worker_main (stdlib-only)
include("sweep.jl")     # topology, make_modes, run_point, sweep
include("plotting.jl")  # plot_results, collate_results

end # module AppleMSeriesBLASCoreComparison
