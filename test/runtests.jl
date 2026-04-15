using MaxiCP
using JavaCall
using Test

@testset "MaxiCP" begin
    @testset "JVM initialisation" begin
        @test MaxiCP.maxicp_jar isa String
        @test isfile(MaxiCP.maxicp_jar)
    end

    @testset "Create model, add constraint, instantiate" begin
        Factory = @jimport org.maxicp.modeling.Factory
        ModelDispatcher = @jimport org.maxicp.ModelDispatcher
        ConcreteCPModel = @jimport org.maxicp.cp.modeling.ConcreteCPModel
        JIntVar = @jimport org.maxicp.modeling.IntVar
        IntExpression = @jimport org.maxicp.modeling.algebra.integer.IntExpression
        BoolExpression = @jimport org.maxicp.modeling.algebra.bool.BoolExpression

        # Create model and variable
        model = jcall(Factory, "makeModelDispatcher", ModelDispatcher, ())
        @test model !== nothing

        x = jcall(model, "intVar", JIntVar, (jint, jint), 1, 10)
        @test x !== nothing

        # Add constraint: x == 5
        eq_expr = jcall(Factory, "eq", BoolExpression, (IntExpression, jint), x, 5)
        jcall(model, "add", Nothing, (BoolExpression,), eq_expr)

        # Instantiate as a CP model
        cp = jcall(model, "cpInstantiate", ConcreteCPModel, ())
        @test cp !== nothing
    end

    include("MOI_wrapper.jl")
    include("sudoku.jl")
end
