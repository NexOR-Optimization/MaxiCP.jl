using JuMP
using Test
import MaxiCP
import MathOptInterface as MOI

@testset "VRP with SubCircuit" begin
    # 4 customers + 1 depot (node 1), 2 trucks
    # Depot copies: node 1 (truck 1 start/end), node 6 (truck 2 start/end)
    # Customers: nodes 2, 3, 4, 5
    # Distance matrix (symmetric, integer):
    #       depot  c1  c2  c3  c4
    # depot   0    10  20  30  40
    # c1     10     0  15  25  35
    # c2     20    15   0  10  20
    # c3     30    25  10   0  10
    # c4     40    35  20  10   0

    n_customers = 4
    n_trucks = 2
    n = n_customers + n_trucks  # 6 nodes: customers 2-5, depot copies 1 and 6

    # Distances (1-indexed, node 1 and 6 are depot copies at same location)
    coords = [0, 10, 20, 30, 40, 0]  # 1D for simplicity
    dist = [abs(coords[i] - coords[j]) for i in 1:n, j in 1:n]

    # Build table of (from, to, cost) for valid edges
    table = reduce(vcat, [
        [i j dist[i, j]]
        for i in 1:n for j in 1:n if i != j
    ])

    model = GenericModel{Int}()

    # Successor variables: next[i] = j means node i is followed by node j
    # next[i] = i means node i is not visited (SubCircuit self-loop)
    @variable(model, 1 <= next[1:n] <= n, Int)

    # SubCircuit: non-self-loop nodes form a single circuit
    @constraint(model, next in MaxiCP.SubCircuit(n))

    # Depot copies must be in the circuit (they are the truck start points).
    # In a SubCircuit, next[i] == i means "not visited". Force depots into circuit
    # by excluding self-loops: next[1] in {2..n}, next[n] in {1..n-1}
    @constraint(model, next[1] >= 2)
    @constraint(model, next[n] <= n - 1)

    # Edge costs via Table
    @variable(model, cost[1:n], Int)
    @constraint(model, [i = 1:n], [i, next[i], cost[i]] in MOI.Table(table))
    # Self-loop cost is 0 (for nodes not in circuit)
    # The table includes i->i with dist=0

    # Minimize total cost
    @objective(model, Min, sum(cost))

    set_optimizer(model, MaxiCP.Optimizer)
    optimize!(model)

    @test termination_status(model) == MOI.OPTIMAL

    next_val = round.(Int, value.(next))
    cost_val = round.(Int, value.(cost))

    # Verify SubCircuit property: non-self-loop nodes form exactly one circuit
    in_circuit = [i for i in 1:n if next_val[i] != i]
    if !isempty(in_circuit)
        # Follow the circuit starting from the first node in it
        start = in_circuit[1]
        visited = Set{Int}()
        current = start
        while true
            push!(visited, current)
            current = next_val[current]
            current == start && break
            @test current ∉ visited  # no revisits
        end
        @test visited == Set(in_circuit)  # all in-circuit nodes are connected
    end

    # Both depot copies should be in the circuit
    @test next_val[1] != 1
    @test next_val[n] != n

    # Verify costs
    for i in 1:n
        j = next_val[i]
        @test cost_val[i] == dist[i, j]
    end
end
