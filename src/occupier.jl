# Occupier: keeps the faster cores busy so a concurrently launched benchmark is
# scheduled onto the perf level under test.
#
# macOS has no thread-affinity API.  Normal-QoS threads are placed on the
# fastest idle cores first, so to measure a slower level in isolation we run
# one spinner thread per faster core at user-interactive QoS (which the
# scheduler keeps on the fastest cores) and launch the benchmark at normal QoS
# while they spin; its threads then land on the level under test at that
# level's normal clocks.
#
# The previous mechanism, background QoS (`taskpolicy -b`), is not a fair
# measurement: the scheduler confines background work to a single cluster of
# the lowest level and runs it at a reduced clock.  On an M5 Pro it made the
# ten Performance cores look like five cores at a third of their speed.
#
# Deliberately stdlib-only.  Launched by start_occupier (sweep.jl) as
#   julia -t <ncores+1> --startup-file=no -e 'include("occupier.jl"); occupier_main()'
# Thread 1 prints "ready" and blocks on stdin; threads 2..N spin until stdin
# reaches EOF (the parent closes the pipe), then the process exits normally.

const QOS_CLASS_USER_INTERACTIVE = 0x21

function occupier_main()
    stop = Threads.Atomic{Bool}(false)
    Threads.@threads :static for i in 1:Threads.nthreads()
        if i == 1
            println("ready"); flush(stdout)
            read(stdin)                 # returns when the parent closes the pipe
            stop[] = true
        else
            # QoS classes exist only on macOS; elsewhere the spinner is a plain
            # thread (the sweep does not use the occupier there, see make_modes).
            Sys.isapple() && ccall(:pthread_set_qos_class_self_np, Cint, (Cuint, Cint),
                                   QOS_CLASS_USER_INTERACTIVE, 0)
            x = UInt64(i)
            while !stop[]
                for _ in 1:2000
                    x = hash(x)         # cheap integer work LLVM cannot fold away
                end
            end
            Base.donotdelete(x)
        end
    end
end
