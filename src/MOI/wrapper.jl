const _DEFAULT_INT_LB = Int32(-1_000_000)
const _DEFAULT_INT_UB = Int32(1_000_000)

"""
    SubCircuit(dimension::Int)

The set of successor vectors `x ∈ {1..d}^d` such that the non-fixed-point
elements (`x[i] ≠ i`) form a single Hamiltonian circuit.
Nodes with `x[i] == i` are not part of the circuit.

Uses 1-based indexing (like `MOI.Circuit`).

## Example

A VRP with 3 trucks can be modeled with 3 depot copies. Each truck's route
is a sub-circuit through its depot and assigned customers:

```julia
model = GenericModel{Int}()
@variable(model, 1 <= next[1:n] <= n, Int)
@constraint(model, next in MaxiCP.SubCircuit(n))
```
"""
struct SubCircuit <: MOI.AbstractVectorSet
    dimension::Int
end

MOI.dimension(set::SubCircuit) = set.dimension

mutable struct VariableInfo
    index::MOI.VariableIndex
    variable::JavaObject  # modeling IntVar (implements IntExpression)
    name::String
    lb::Union{Nothing, Int}
    ub::Union{Nothing, Int}
    is_binary::Bool
end

function VariableInfo(index::MOI.VariableIndex, variable::JavaObject)
    return VariableInfo(index, variable, "", nothing, nothing, false)
end

mutable struct ConstraintInfo
    index::MOI.ConstraintIndex
    constraint::Union{JavaObject, Nothing}
    f::Union{MOI.AbstractScalarFunction, MOI.AbstractVectorFunction}
    set::MOI.AbstractSet
    name::String
end

function ConstraintInfo(
    index::MOI.ConstraintIndex,
    constraint::Union{JavaObject, Nothing},
    f::Union{MOI.AbstractScalarFunction, MOI.AbstractVectorFunction},
    set::MOI.AbstractSet,
)
    return ConstraintInfo(index, constraint, f, set, "")
end

mutable struct Optimizer <: MOI.AbstractOptimizer
    inner::ModelDispatcher
    variable_info::MOI.Utilities.CleverDicts.CleverDict{MOI.VariableIndex, VariableInfo}
    constraint_info::Dict{MOI.ConstraintIndex, ConstraintInfo}
    # Constraints that must be posted after cpInstantiate (raw CP constraints)
    deferred_constraints::Vector{Function}
    name::String
    objective_sense::MOI.OptimizationSense
    objective_function_type::Union{Nothing, DataType}
    objective_function::Union{Nothing, MOI.VariableIndex, MOI.ScalarAffineFunction}
    termination_status::MOI.TerminationStatusCode
    primal_status::MOI.ResultStatusCode
    cached_solution::Dict{MOI.VariableIndex, Int}
    cached_objective_value::Union{Nothing, Int}

    function Optimizer()
        model = new()
        model.inner = jcall(MFactory, "makeModelDispatcher", ModelDispatcher, ())
        model.variable_info = MOI.Utilities.CleverDicts.CleverDict{MOI.VariableIndex, VariableInfo}()
        model.constraint_info = Dict{MOI.ConstraintIndex, ConstraintInfo}()
        model.deferred_constraints = Function[]
        model.name = ""
        model.objective_sense = MOI.FEASIBILITY_SENSE
        model.objective_function_type = nothing
        model.objective_function = nothing
        model.termination_status = MOI.OPTIMIZE_NOT_CALLED
        model.primal_status = MOI.NO_SOLUTION
        model.cached_solution = Dict{MOI.VariableIndex, Int}()
        model.cached_objective_value = nothing
        return model
    end
end

function MOI.empty!(model::Optimizer)
    model.inner = jcall(MFactory, "makeModelDispatcher", ModelDispatcher, ())
    model.name = ""
    empty!(model.variable_info)
    empty!(model.constraint_info)
    empty!(model.deferred_constraints)
    model.objective_sense = MOI.FEASIBILITY_SENSE
    model.objective_function_type = nothing
    model.objective_function = nothing
    model.termination_status = MOI.OPTIMIZE_NOT_CALLED
    model.primal_status = MOI.NO_SOLUTION
    empty!(model.cached_solution)
    model.cached_objective_value = nothing
    return
end

function MOI.is_empty(model::Optimizer)
    !isempty(model.name) && return false
    !isempty(model.variable_info) && return false
    !isempty(model.constraint_info) && return false
    !isempty(model.deferred_constraints) && return false
    model.objective_sense != MOI.FEASIBILITY_SENSE && return false
    model.objective_function_type !== nothing && return false
    model.objective_function !== nothing && return false
    model.termination_status != MOI.OPTIMIZE_NOT_CALLED && return false
    return true
end

MOI.get(::Optimizer, ::MOI.SolverName) = "MaxiCP"

# Objective support

function MOI.supports(
    ::Optimizer,
    ::MOI.ObjectiveFunction{F},
) where {F <: Union{MOI.VariableIndex, MOI.ScalarAffineFunction}}
    return true
end

MOI.supports(::Optimizer, ::MOI.ObjectiveSense) = true

function MOI.get(model::Optimizer, ::MOI.ObjectiveSense)
    return model.objective_sense
end

function MOI.set(model::Optimizer, ::MOI.ObjectiveSense, sense::MOI.OptimizationSense)
    model.objective_sense = sense
    return
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveFunctionType)
    return model.objective_function_type
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveFunction{F}) where {F}
    if model.objective_function_type !== F
        error("Objective function type is $(model.objective_function_type), not $F.")
    end
    return model.objective_function::F
end

function MOI.set(
    model::Optimizer,
    ::MOI.ObjectiveFunction{F},
    f::F,
) where {F <: Union{MOI.VariableIndex, MOI.ScalarAffineFunction}}
    model.objective_function_type = F
    model.objective_function = f
    return
end

function MOI.get(model::Optimizer, ::MOI.ListOfModelAttributesSet)
    attributes = Any[MOI.ObjectiveSense()]
    typ = model.objective_function_type
    if typ !== nothing
        push!(attributes, MOI.ObjectiveFunction{typ}())
    end
    return attributes
end

# Constraint support declarations

function MOI.supports_constraint(
    ::Optimizer,
    ::Type{MOI.VariableIndex},
    ::Type{S},
) where {T <: Union{Int, Float64}, S <: Union{MOI.EqualTo{T}, MOI.LessThan{T}, MOI.GreaterThan{T}, MOI.Interval{T}}}
    return true
end

function MOI.supports_constraint(
    ::Optimizer,
    ::Type{MOI.ScalarAffineFunction{T}},
    ::Type{S},
) where {T <: Union{Int, Float64}, S <: Union{MOI.EqualTo{T}, MOI.LessThan{T}, MOI.GreaterThan{T}}}
    return true
end

function MOI.supports_constraint(
    ::Optimizer,
    ::Type{MOI.VectorOfVariables},
    ::Type{MOI.AllDifferent},
)
    return true
end

# Incremental interface

MOI.supports_incremental_interface(::Optimizer) = true

function MOI.copy_to(dest::Optimizer, src::MOI.ModelLike)
    return MOI.Utilities.default_copy_to(dest, src)
end

# Build objective expression from MOI objective function

function _build_objective_expression(model::Optimizer)
    f = model.objective_function
    if f isa MOI.VariableIndex
        return _info(model, f).variable
    else
        return _build_linear_expression(model, f)
    end
end

# Optimize

function MOI.optimize!(model::Optimizer)
    empty!(model.cached_solution)
    model.cached_objective_value = nothing

    # Collect variables in a stable order (by index value)
    vis = sort!(collect(keys(model.variable_info)), by = v -> v.value)
    vars = IntExpression[model.variable_info[vi].variable for vi in vis]

    if isempty(vars)
        model.termination_status = MOI.OPTIMAL
        model.primal_status = MOI.FEASIBLE_POINT
        return
    end

    # Instantiate to concrete CP model.
    # MaxiCP throws InconsistencyException during instantiation if the model
    # is infeasible at the root (e.g., empty domains after propagation).
    local cp
    try
        cp = jcall(model.inner, "cpInstantiate", ConcreteCPModel, ())
        for post_fn in model.deferred_constraints
            post_fn(model)
        end
    catch e
        if e isa JavaCall.JavaCallError
            model.termination_status = MOI.INFEASIBLE
            model.primal_status = MOI.NO_SOLUTION
            return
        end
        rethrow()
    end

    # Create default branching strategy (first-fail)
    branching = jcall(JSearches, "firstFail", JSupplier, (Vector{IntExpression},), vars)

    # Create search
    dfs = jcall(model.inner, "dfSearch", DFSearch, (JSupplier,), branching)

    # Use SearchHelper to solve and capture solution values via onSolution callback
    local result
    if model.objective_sense == MOI.FEASIBILITY_SENSE
        result = jcall(SearchHelper, "solveAndCapture", Vector{jint},
                       (DFSearch, Vector{IntExpression}), dfs, vars)
    else
        obj_expr = _build_objective_expression(model)
        sym_obj = if model.objective_sense == MOI.MIN_SENSE
            jcall(MFactory, "minimize", SymObjective, (IntExpression,), obj_expr)
        else
            jcall(MFactory, "maximize", SymObjective, (IntExpression,), obj_expr)
        end
        result = jcall(SearchHelper, "optimizeAndCapture", Vector{jint},
                       (DFSearch, SymObjective, Vector{IntExpression}), dfs, sym_obj, vars)
    end

    if result !== nothing
        model.termination_status = MOI.OPTIMAL
        model.primal_status = MOI.FEASIBLE_POINT
        for (i, vi) in enumerate(vis)
            model.cached_solution[vi] = Int(result[i])
        end
        if model.objective_function !== nothing && model.objective_sense != MOI.FEASIBILITY_SENSE
            model.cached_objective_value = _evaluate_objective(model)
        end
    else
        model.termination_status = MOI.INFEASIBLE
        model.primal_status = MOI.NO_SOLUTION
    end
    return
end

function _evaluate_objective(model::Optimizer)
    f = model.objective_function
    if f isa MOI.VariableIndex
        return model.cached_solution[f]
    else
        val = round(Int, f.constant)
        for t in f.terms
            val += round(Int, t.coefficient) * model.cached_solution[t.variable]
        end
        return val
    end
end

# Solution getters

function MOI.get(model::Optimizer, ::MOI.TerminationStatus)
    return model.termination_status
end

function MOI.get(model::Optimizer, ::MOI.PrimalStatus)
    return model.primal_status
end

function MOI.get(model::Optimizer, ::MOI.DualStatus)
    return MOI.NO_SOLUTION
end

function MOI.get(model::Optimizer, ::MOI.RawStatusString)
    return string(model.termination_status)
end

function MOI.get(model::Optimizer, ::MOI.ResultCount)
    return model.primal_status == MOI.FEASIBLE_POINT ? 1 : 0
end

function MOI.get(model::Optimizer, attr::MOI.VariablePrimal, vi::MOI.VariableIndex)
    MOI.check_result_index_bounds(model, attr)
    return model.cached_solution[vi]
end

function MOI.get(model::Optimizer, attr::MOI.ObjectiveValue)
    MOI.check_result_index_bounds(model, attr)
    if model.cached_objective_value !== nothing
        return model.cached_objective_value
    end
    # For feasibility sense, return 0
    return 0
end
