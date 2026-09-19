#!/bin/bash
set -eu

# Builds FUSE from this local checkout into fuse_build_local/ (gitignored):
# a private Pkg depot with FUSE `develop`-ed from source (not `Pkg.add`-ed from
# the registry, so it tracks whatever is currently checked out here) plus a
# PackageCompiler sysimage (sys_fuse.so) for fast startup.
#
# Run this FROM AN INTERACTIVE COMPUTE NODE -- sysimage builds need RAM/time
# that login nodes won't give you. Human steps you must do yourself in
# separate terminals are commented out below; uncomment/copy-paste them
# there, then run the rest of this script on the node they give you.

# ── STEP 0 (human, separate terminal): get a fat interactive node ──────────
# This is a memory request, not a parallelism one -- JULIA_NUM_THREADS and
# JULIA_NUM_PRECOMPILE_TASKS below cap concurrency at 10, so --cpus-per-task
# only needs to be in that ballpark. Request total memory directly (--mem)
# rather than --mem-per-cpu/--exclusive: this cluster only has one fully-idle
# node at a time (sinfo), so --exclusive restricts you to whatever that one
# node's free shape happens to be and can fail with "node configuration not
# available" even though plenty of memory is free cluster-wide. --mem lets
# Slurm place you on any node (medium partition: 128 cpu / 512G nodes) with
# enough headroom instead.
# create_sysimage's trace-compile is NOT incremental -- if the time limit
# hits mid-build, that entire phase restarts from scratch (only the earlier
# Pkg.precompile step is cached). Run this inside `tmux`/`screen` so a
# dropped SSH connection doesn't kill it, and give it real headroom:
# tmux new -s fusebuild
# salloc -p medium -N 1 --cpus-per-task=16 -n 1 --mem=128G -t 08:00:00

# ── STEP 0b (human, separate terminal): open the somega SSH master ─────────
# The precompile workload below (time_dependent_d3d.jl) fetches a real DIII-D
# shot, which needs a live master (persists ~4h via ControlPersist) to avoid
# tripping fail2ban on the cybele bastion:
# ssh somega.gat.com

# ── toolchain -- same versions the working sys_fuse.so builds use ──────────
module purge
module load default-paths
module load julia/1.11.7      # matches FUSE's Project.toml: julia = "1.11"
module load env/gcc11.x

# ── private project dir + depot, gitignored, lives next to this script ─────
FUSE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUSE_BUILD="$FUSE_SRC/fuse_build_local"
mkdir -p "$FUSE_BUILD"
export FUSE_SRC FUSE_BUILD

export JULIA_DEPOT_PATH="$FUSE_BUILD/.julia:"
export JULIA_PKG_USE_CLI_GIT=1
export JULIA_CC="gcc -O3"
export JULIA_NUM_THREADS=10
export JULIA_NUM_PRECOMPILE_TASKS=10
# A single "generic" target -- not the official installer's multi-target
# clone_all string. That string makes create_sysimage's final ahead-of-time
# object-file compile crash on HiGHS_jll ("undefined symbol: Highs_create",
# transitively pulled in via ONNXNaiveNASflux) -- HiGHS loads and runs fine
# on this cluster otherwise (verified standalone), so the trigger is the
# CPU-multiversioning codegen for that step, not a broken artifact. A single
# generic target sidesteps it and still runs safely on both node families in
# `medium` (omega[10-13] and omega[20-25] are different CPU generations),
# just without per-arch SIMD tuning.
export JULIA_CPU_TARGET="generic"

# ── develop FUSE from this checkout, not from the registry ─────────────────
# Pkg.resolve() first: a git pull in the checkout can add a dep to FUSE's own
# Project.toml (e.g. CoordinateConventions, 2026-08-24) that the Manifest's
# deved-FUSE deps list doesn't know about, and FUSE then fails to precompile
# with "Package FUSE does not have X in its dependencies". Skip the whole block
# with SKIP_INSTANTIATE=1 ./fuse_build.sh only when the checkout has not moved
# since the last run -- it avoids re-verifying ~900 packages each retry, but
# also skips that re-resolve.
if [ "${SKIP_INSTANTIATE:-0}" != "1" ]; then
julia --project="$FUSE_BUILD" -e '
    import Pkg
    Pkg.Registry.add(Pkg.RegistrySpec(url="https://github.com/ProjectTorreyPines/FuseRegistry.jl.git"))
    Pkg.Registry.add("General")
    Pkg.develop(path=ENV["FUSE_SRC"])
    # IMAS alongside PackageCompiler: fuse_driver.jl does `using FUSE, IMAS`, and
    # Julia only allows `using` on DIRECT deps of the active project -- IMAS comes in
    # as an indirect dep of FUSE otherwise, and the driver fails with "Package IMAS
    # not found in current path". (The official v1.1.5 environment lists it directly.)
    Pkg.add(["PackageCompiler", "IMAS"])
    Pkg.resolve()
    Pkg.instantiate()
    Pkg.precompile()
'
fi

# ── build the sysimage ──────────────────────────────────────────────────────
# Warms the real StudyPostdictive code path (needs the SSH master from step
# 0b). If you'd rather skip the network fetch during the build, delete the
# `include(...)` line below -- the sysimage still builds, first real run just
# pays some extra JIT.
julia --project="$FUSE_BUILD" -e '
    using PackageCompiler
    precompile_file = joinpath(ENV["FUSE_BUILD"], "precompile_script.jl")
    write(precompile_file, """
        using FUSE
        include(joinpath(pkgdir(FUSE), "deploy", "omega", "time_dependent_d3d.jl"))
    """)
    create_sysimage(["FUSE"];
        project = ENV["FUSE_BUILD"],
        sysimage_path = joinpath(ENV["FUSE_BUILD"], "sys_fuse.so"),
        precompile_execution_file = precompile_file,
        cpu_target = ENV["JULIA_CPU_TARGET"])
'

echo "Built: $FUSE_BUILD/sys_fuse.so"
