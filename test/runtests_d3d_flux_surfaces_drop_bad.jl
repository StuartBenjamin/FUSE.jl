using FUSE
using Test

@testset "d3d_flux_surfaces_drop_bad!" begin
    # slices at 0.1:0.1:0.8 s; the `bad` ones get a rectangular grid with no ψ, so flux_surfaces throws on them
    # (the others have no profiles_2d and are skipped)
    function eq_with_bad(bad)
        eq = IMAS.dd().equilibrium
        eq.time = collect(0.1:0.1:0.8)
        eq.vacuum_toroidal_field.b0 = collect(1.0:8.0)
        resize!(eq.time_slice, length(eq.time))
        for (k, eqt) in enumerate(eq.time_slice)
            eqt.time = eq.time[k]
            if k in bad
                resize!(eqt.profiles_2d, 1)
                eqt.profiles_2d[1].grid_type.index = 1
            end
        end
        return eq
    end
    wall = (Float64[], Float64[])

    # runs at the start and end, and a single slice in between, are dropped
    eq = eq_with_bad([1, 2, 5, 8])
    @test FUSE.d3d_flux_surfaces_drop_bad!(eq, wall...) ≈ [0.1, 0.2, 0.5, 0.8]
    @test eq.time ≈ [0.3, 0.4, 0.6, 0.7] && [eqt.time for eqt in eq.time_slice] == eq.time
    @test eq.vacuum_toroidal_field.b0 == [3.0, 4.0, 6.0, 7.0]

    @test isempty(FUSE.d3d_flux_surfaces_drop_bad!(eq_with_bad(Int[]), wall...))

    # two in a row in between end the equilibrium there
    eq = eq_with_bad([1, 4, 5])
    @test FUSE.d3d_flux_surfaces_drop_bad!(eq, wall...) ≈ [0.1, 0.4, 0.5, 0.6, 0.7, 0.8]
    @test eq.time ≈ [0.2, 0.3] && eq.vacuum_toroidal_field.b0 == [2.0, 3.0]

    # fewer than two slices left: an error
    @test_throws ErrorException FUSE.d3d_flux_surfaces_drop_bad!(eq_with_bad([2, 3]), wall...)
    @test_throws ErrorException FUSE.d3d_flux_surfaces_drop_bad!(eq_with_bad(1:8), wall...)
end
