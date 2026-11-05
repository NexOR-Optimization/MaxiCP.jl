# MathOptVRP sets. A model with a `MathOptVRP.Partition` is solved by the routing
# engine of `deps/java/maxicpjl`: the sets are recorded while the model is built,
# and the whole model is translated to a `VrpSpec` in `optimize!`.

const _ROUTE_SETS = Union{
    MathOptVRP.RouteCompatibility,
    MathOptVRP.RouteOrder,
    MathOptVRP.RouteExtremities,
    MathOptVRP.Capacity,
    MathOptVRP.IsEmpty,
    MathOptVRP.SumGetIndex,
    MathOptVRP.SumDistances,
    MathOptVRP.VehicleSchedule,
}

const _VECTOR_FUNCTIONS = Union{
    MOI.VectorOfVariables,
    MOI.VectorAffineFunction{Float64},
    MOI.VectorAffineFunction{Int},
}

function MOI.supports_constraint(
    ::Optimizer,
    ::Type{<:_VECTOR_FUNCTIONS},
    ::Type{<:_ROUTE_SETS},
)
    return true
end

MOI.supports_add_constrained_variables(::Optimizer, ::Type{<:_ROUTE_SETS}) = false

function MOI.supports_add_constrained_variables(::Optimizer, ::Type{MathOptVRP.Partition})
    return true
end

function MOI.supports_constraint(
    ::Optimizer,
    ::Type{<:Union{MOI.VectorAffineFunction{Float64},MOI.VectorAffineFunction{Int}}},
    ::Type{<:MOI.Indicator{A,S}},
) where {A,T<:Real,S<:Union{MOI.EqualTo{T},MOI.LessThan{T},MOI.GreaterThan{T}}}
    return true
end

function MOI.add_constrained_variables(model::Optimizer, set::MathOptVRP.Partition)
    model.partition === nothing ||
        error("MaxiCP: a model can only have one MathOptVRP.Partition.")
    model.partition = set
    n = set.num_clients
    indices = MOI.VariableIndex[]
    for route in 1:set.num_trucks, position in 1:n
        vi = _make_var(model, _make_intvar(model, Int32(0), Int32(n)))
        model.route_of[vi] = (route, position)
        push!(indices, vi)
    end
    f = MOI.VectorOfVariables(indices)
    index = MOI.ConstraintIndex{MOI.VectorOfVariables,MathOptVRP.Partition}(
        length(model.constraint_info) + 1,
    )
    model.constraint_info[index] = ConstraintInfo(index, nothing, f, set)
    return indices, index
end

# Recorded only: `_vrp_spec` translates them.
function MOI.add_constraint(
    model::Optimizer,
    f::F,
    s::S,
) where {F<:_VECTOR_FUNCTIONS,S<:Union{_ROUTE_SETS,MOI.Indicator}}
    index = MOI.ConstraintIndex{F,S}(length(model.constraint_info) + 1)
    model.constraint_info[index] = ConstraintInfo(index, nothing, f, s)
    return index
end

# The rows of `f`: a variable, a constant, or an affine function.
function _items(f::_VECTOR_FUNCTIONS)
    return map(MOI.Utilities.scalarize(f)) do g
        g isa MOI.VariableIndex && return g
        g = MOI.Utilities.canonical(g)
        isempty(g.terms) && return round(Int, g.constant)
        if length(g.terms) == 1 && isone(g.terms[1].coefficient) && iszero(g.constant)
            return g.terms[1].variable
        end
        return g
    end
end

_items(f::MOI.VectorOfVariables) = Any[vi for vi in f.variables]

# The 0-based route whose proxy variables are `items`, in order.
function _route(model::Optimizer, items)
    first_item = items[1]
    first_item isa MOI.VariableIndex && haskey(model.route_of, first_item) ||
        error("MaxiCP: expected the variables of a column of the MathOptVRP.Partition.")
    route = model.route_of[first_item][1]
    for (position, item) in enumerate(items)
        get(model.route_of, item, nothing) == (route, position) || error(
            "MaxiCP: expected the variables of a column of the MathOptVRP.Partition, in order.",
        )
    end
    return Int32(route - 1)
end

_ints(x) = jint[round(Int, v) for v in x]
_flat(m::AbstractMatrix) = _ints(vec(permutedims(m)))

function _var(ids, item)
    item isa MOI.VariableIndex && haskey(ids, item) ||
        error("MaxiCP: expected a variable, got $item.")
    return ids[item]
end

function _linear(ids, f::MOI.ScalarAffineFunction)
    f = MOI.Utilities.canonical(f)
    vars = jint[_var(ids, t.variable) for t in f.terms]
    coefs = jint[]
    for t in f.terms
        isinteger(t.coefficient) ||
            error("MaxiCP: non-integer coefficient $(t.coefficient).")
        push!(coefs, round(Int, t.coefficient))
    end
    isinteger(f.constant) || error("MaxiCP: non-integer constant $(f.constant).")
    return vars, coefs, round(Int, f.constant)
end

_linear(ids, vi::MOI.VariableIndex) = (jint[_var(ids, vi)], jint[1], 0)

# The senses of `VrpSpec.addLinear`.
_sense(s::MOI.LessThan) = (-1, s.upper)
_sense(s::MOI.GreaterThan) = (1, s.lower)
_sense(s::MOI.EqualTo) = (0, s.value)

function _add_linear(spec, ids, f, s, activation = nothing)
    vars, coefs, constant = _linear(ids, f)
    sense, rhs = _sense(s)
    isinteger(rhs) || error("MaxiCP: non-integer right-hand side $rhs.")
    rhs = round(Int, rhs) - constant
    if activation === nothing
        jcall(spec, "addLinear", Nothing, (Vector{jint}, Vector{jint}, jint, jint),
            vars, coefs, sense, rhs)
    else
        jcall(spec, "addIndicator", Nothing,
            (jint, jint, Vector{jint}, Vector{jint}, jint, jint),
            activation..., vars, coefs, sense, rhs)
    end
    return
end

function _add(model, spec, ids, f, s::MathOptVRP.RouteCompatibility)
    route = _route(model, _items(f))
    jcall(spec, "addCompatibility", Nothing, (jint, Vector{jint}), route, _ints(s.allowed))
end

function _add(model, spec, ids, f, s::MathOptVRP.RouteOrder)
    route = _route(model, _items(f))
    jcall(spec, "addRouteOrder", Nothing, (jint, Vector{jint}, Vector{jint}),
        route, _ints(s.before), _ints(s.after))
end

function _add(model, spec, ids, f, s::MathOptVRP.RouteExtremities)
    route = _route(model, _items(f))
    jcall(spec, "addRouteExtremities", Nothing, (jint, Vector{jint}), route, _ints(s.members))
end

function _add(model, spec, ids, f, s::MathOptVRP.Capacity)
    route = _route(model, _items(f))
    jcall(spec, "addCapacity", Nothing, (jint, Vector{jint}, jint),
        route, _ints(s.delta), round(Int, s.capacity))
end

function _add(model, spec, ids, f, s::MathOptVRP.IsEmpty)
    items = _items(f)
    jcall(spec, "defineIsEmpty", Nothing, (jint, jint),
        _var(ids, items[1]), _route(model, items[2:end]))
end

function _add(model, spec, ids, f, s::MathOptVRP.SumGetIndex)
    items = _items(f)
    jcall(spec, "defineSumGetIndex", Nothing, (jint, jint, Vector{jint}),
        _var(ids, items[1]), _route(model, items[2:end]), _ints(s.values))
end

function _add(model, spec, ids, f, s::MathOptVRP.SumDistances)
    items = _items(f)
    jcall(spec, "defineSumDistances", Nothing, (jint, jint, Vector{jint}, jint, jint),
        _var(ids, items[1]), _route(model, items[2:end]), _flat(s.distance),
        s.first - 1, s.last - 1)
end

function _add(model, spec, ids, f, s::MathOptVRP.VehicleSchedule)
    items = _items(f)
    n, T = length(s.service), s.num_trips
    vars(range) = jint[_var(ids, items[i]) for i in range]
    routes = jint[_route(model, items[(2T+2+n*t+1):(2T+2+n*(t+1))]) for t in 1:T]
    jcall(spec, "addSchedule", Nothing,
        (Vector{jint}, Vector{jint}, Vector{jint}, jint, jint, Vector{jint},
            Vector{jint}, jint, Vector{jint}, Vector{jint}, Vector{jint}, jint, jint,
            jint, jint, Vector{jint}, jint, jint, jint),
        routes, vars(1:T), vars((T+1):(2T)), _var(ids, items[2T+1]),
        _var(ids, items[2T+2]), vars((2T+3):(2T+2+n)), _flat(s.travel), s.depot - 1,
        _ints(s.earliest), _ints(s.latest), _ints(s.service),
        round(Int, s.day_earliest), round(Int, s.day_latest),
        round(Int, s.first_service), round(Int, s.reload_fixed), _ints(s.reload),
        round(Int, s.break_length), round(Int, s.break_from), round(Int, s.break_to))
end

function _add(model, spec, ids, f, s::MOI.Indicator{A}) where {A}
    items = MOI.Utilities.scalarize(f)
    activation = _var(ids, only(MOI.Utilities.canonical(items[1]).terms).variable)
    value = A == MOI.ACTIVATE_ON_ONE ? 1 : 0
    _add_linear(spec, ids, items[2], s.set, (activation, value))
end

_add(model, spec, ids, f::MOI.ScalarAffineFunction, s) = _add_linear(spec, ids, f, s)

# Bounds are read from the variables.
_add(model, spec, ids, ::MOI.VariableIndex, s) = nothing
_add(model, spec, ids, f, ::MathOptVRP.Partition) = nothing

function _add(model, spec, ids, f, s)
    return error("MaxiCP: $(typeof(s)) is not supported with MathOptVRP.Partition.")
end

function _vrp_spec(model::Optimizer)
    partition = model.partition
    spec = VrpSpec((jint, jint), partition.num_clients, partition.num_trucks)
    ids = Dict{MOI.VariableIndex,jint}()
    for vi in sort!(collect(keys(model.variable_info)); by = v -> v.value)
        haskey(model.route_of, vi) && continue
        info = model.variable_info[vi]
        lb = something(info.lb, Int(_DEFAULT_INT_LB))
        ub = something(info.ub, Int(_DEFAULT_INT_UB))
        ids[vi] = jcall(spec, "addVar", jint, (jint, jint), lb, ub)
    end
    for (_, info) in sort!(collect(model.constraint_info); by = p -> p[1].value)
        _add(model, spec, ids, info.f, info.set)
    end
    f = model.objective_function
    if f !== nothing && model.objective_sense != MOI.FEASIBILITY_SENSE
        vars, coefs, constant = _linear(ids, f)
        jcall(spec, "setObjective", Nothing, (Vector{jint}, Vector{jint}, jint, jboolean),
            vars, coefs, constant, model.objective_sense == MOI.MIN_SENSE)
    end
    return spec, ids
end

function _optimize_vrp!(model::Optimizer)
    spec, ids = _vrp_spec(model)
    time_limit = something(model.time_limit, _DEFAULT_TIME_LIMIT)
    seed = get(model.options, "seed", 0)
    workers = get(model.options, "workers", max(1, min(6, Sys.CPU_THREADS - 2)))
    status = jcall(spec, "solve", JString, (jdouble, jlong, jint, jboolean),
        time_limit, seed, workers, !model.silent)
    if status == "INFEASIBLE"
        model.termination_status = MOI.INFEASIBLE
        model.primal_status = MOI.NO_SOLUTION
        return
    end
    # The search stops at the time limit, without a proof of optimality.
    model.termination_status = MOI.TIME_LIMIT
    if status != "SOLVED"
        model.primal_status = MOI.NO_SOLUTION
        return
    end
    model.primal_status = MOI.FEASIBLE_POINT
    values = jcall(spec, "values", Vector{jint}, ())
    for (vi, id) in ids
        model.cached_solution[vi] = Int(values[id+1])
    end
    n = model.partition.num_clients
    proxy = Dict(position => vi for (vi, position) in model.route_of)
    for route in 1:model.partition.num_trucks
        nodes = jcall(spec, "routeNodes", Vector{jint}, (jint,), route - 1)
        for position in 1:n
            vi = proxy[(route, position)]
            model.cached_solution[vi] = position <= length(nodes) ? nodes[position] + 1 : 0
        end
    end
    if model.objective_function !== nothing &&
       model.objective_sense != MOI.FEASIBILITY_SENSE
        model.cached_objective_value = _evaluate_objective(model)
    end
    return
end
