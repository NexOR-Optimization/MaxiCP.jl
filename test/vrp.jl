using JuMP
using Test
import MaxiCP
import MathOptInterface as MOI
import ConstraintProgrammingExtensions as CP

@testset "VRP with SubCircuit" begin
    # 5 customers, 2 trucks, 1 depot
    # Depot copies: nodes 6, 7 (same location as node 1 would be, at coord 0)
    # Customers: nodes 1..5
    # We must visit all customers (enforce next[i] != i for customers)
    # The two depot copies split the circuit into two truck routes.

    n_customers = 5
    n_trucks = 2
    n = n_customers + n_trucks  # 7 total nodes

    # 1D coordinates for simplicity
    # Customers at positions 10, 20, 30, 40, 50; depot copies at 0
    coords = [10, 20, 30, 40, 50, 0, 0]
    dist = [abs(coords[i] - coords[j]) for i in 1:n, j in 1:n]

    # Build table: (from, to, cost) for all edges including self-loops (cost 0)
    table = reduce(vcat, [
        [i, j, (i == j ? 0 : dist[i, j])]'
        for i in 1:n for j in 1:n
    ])

    model = GenericModel{Int}()

    @variable(model, 1 <= next[1:n] <= n, Int)
    @constraint(model, next in MaxiCP.SubCircuit(n))

    # All customers must be visited (no self-loops)
    @constraint(model, [i = 1:n_customers], next[i] in CP.DifferentFrom(i))
    # Both depot copies must be in the circuit
    depot1 = n_customers + 1
    depot2 = n_customers + 2
    @constraint(model, next[depot1] in CP.DifferentFrom(depot1))
    @constraint(model, next[depot2] in CP.DifferentFrom(depot2))

    # Edge costs via Table
    @variable(model, cost[1:n], Int)
    @constraint(model, [i = 1:n], [i, next[i], cost[i]] in MOI.Table(table))

    @objective(model, Min, sum(cost))

    set_optimizer(model, MaxiCP.Optimizer)
    optimize!(model)

    @test termination_status(model) == MOI.OPTIMAL

    next_val = round.(Int, value.(next))
    cost_val = round.(Int, value.(cost))

    # Verify all customers + depots are in the circuit
    for i in 1:n
        @test next_val[i] != i
    end

    # Verify single circuit through all nodes
    visited = Set{Int}()
    current = 1
    for _ in 1:n
        @test current ∉ visited
        push!(visited, current)
        current = next_val[current]
    end
    @test current == 1  # back to start
    @test length(visited) == n

    # Verify costs match distances
    for i in 1:n
        @test cost_val[i] == dist[i, next_val[i]]
    end

    # The two depot copies create two "routes":
    # Route 1: depot1 → ... → depot2
    # Route 2: depot2 → ... → depot1
    # Extract routes
    route1 = Int[]
    current = depot1
    while true
        current = next_val[current]
        current == depot2 && break
        push!(route1, current)
    end
    route2 = Int[]
    current = depot2
    while true
        current = next_val[current]
        current == depot1 && break
        push!(route2, current)
    end
    # All customers assigned to exactly one route
    @test sort(vcat(route1, route2)) == 1:n_customers
end
