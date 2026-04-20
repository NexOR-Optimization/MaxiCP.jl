using JuMP
using Test
import MaxiCP
import MathOptInterface as MOI

@testset "TSP" begin
    n = 6
    using Random
    Random.seed!(1234)
    x = rand(n)
    y = rand(n)

    table = reduce(
        vcat,
        [
            [i, j, round(Int, 100hypot(x[i] - x[j], y[i] - y[j]))]' for
            i in 1:n for j in 1:n if i != j
        ],
    )

    model = GenericModel{Int}()
    @variable(model, 1 <= next[1:n] <= n, Int)
    @constraint(model, next in MOI.Circuit(n))
    @variable(model, cost[1:n], Int)
    @constraint(
        model,
        [i = 1:n],
        [i, next[i], cost[i]] in MOI.Table(table),
    )
    @objective(model, Min, sum(cost))
    set_optimizer(model, MaxiCP.Optimizer)
    optimize!(model)

    @test termination_status(model) == MOI.OPTIMAL

    next_val = round.(Int, value.(next))
    cost_val = round.(Int, value.(cost))

    # Verify circuit: visit every node exactly once
    visited = falses(n)
    current = 1
    for _ in 1:n
        @test !visited[current]
        visited[current] = true
        current = next_val[current]
    end
    @test current == 1
    @test all(visited)

    # Verify costs match the distance table
    for i in 1:n
        j = next_val[i]
        expected = round(Int, 100hypot(x[i] - x[j], y[i] - y[j]))
        @test cost_val[i] == expected
    end

    # Verify objective
    @test objective_value(model) == sum(cost_val)
end
