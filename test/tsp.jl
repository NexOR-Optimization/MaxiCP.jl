using JuMP
using Test
using Random
import MaxiCP
import MathOptInterface as MOI

@testset "TSP" begin
    n = 6
    Random.seed!(1234)
    x = rand(n)
    y = rand(n)
    d(i, j) = round(Int, 100hypot(x[i] - x[j], y[i] - y[j]))

    function verify(model, next, cost)
        @test termination_status(model) == MOI.OPTIMAL
        next_val = round.(Int, value.(next))
        cost_val = round.(Int, value.(cost))
        visited = falses(n)
        current = 1
        for _ in 1:n
            @test !visited[current]
            visited[current] = true
            current = next_val[current]
        end
        @test current == 1
        @test all(visited)
        for i in 1:n
            @test cost_val[i] == d(i, next_val[i])
        end
        @test objective_value(model) == sum(cost_val)
    end

    @testset "3-column table" begin
        table = reduce(
            vcat,
            [[i, j, d(i, j)]' for i in 1:n for j in 1:n if i != j],
        )
        model = GenericModel{Int}()
        @variable(model, 1 <= next[1:n] <= n, Int)
        @constraint(model, next in MOI.Circuit(n))
        @variable(model, cost[1:n], Int)
        # VAF-in-MOI.Table, will need a slack bridge
        @constraint(
            model,
            [i = 1:n],
            [i, next[i], cost[i]] in MOI.Table(table),
        )
        @objective(model, Min, sum(cost))
        set_optimizer(model, MaxiCP.Optimizer)
        optimize!(model)
        verify(model, next, cost)
    end

    @testset "2-column table" begin
        model = GenericModel{Int}()
        @variable(model, 1 <= next[1:n] <= n, Int)
        @constraint(model, next in MOI.Circuit(n))
        @variable(model, cost[1:n], Int)
        # VOV-in-MOI.Table no need for slack bridge
        for i in 1:n
            table_i = reduce(vcat, [[j  d(i, j)] for j in 1:n if j != i])
            @constraint(model, [next[i], cost[i]] in MOI.Table(table_i))
        end
        @objective(model, Min, sum(cost))
        set_optimizer(model, MaxiCP.Optimizer)
        optimize!(model)
        verify(model, next, cost)
    end
end
