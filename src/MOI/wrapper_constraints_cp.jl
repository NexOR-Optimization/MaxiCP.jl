function _build_constraint(
    model::Optimizer,
    f::MOI.VectorOfVariables,
    ::MOI.AllDifferent,
)
    vars = _parse_to_vars(model, f)
    return jcall(MFactory, "allDifferent", JConstraint, (Vector{IntExpression},), vars)
end

# Circuit constraint

function MOI.supports_constraint(
    ::Optimizer,
    ::Type{MOI.VectorOfVariables},
    ::Type{MOI.Circuit},
)
    return true
end

function _build_constraint(
    model::Optimizer,
    f::MOI.VectorOfVariables,
    ::MOI.Circuit,
)
    vars = _parse_to_vars(model, f)
    # MOI uses 1-based indexing, MaxiCP uses 0-based.
    # Create x[i] - 1 expressions for the circuit constraint.
    shifted = IntExpression[
        jcall(MFactory, "minus", IntExpression, (IntExpression, jint), v, Int32(1))
        for v in vars
    ]
    return jcall(MFactory, "circuit", JConstraint, (Vector{IntExpression},), shifted)
end

# BinPacking constraint

function MOI.supports_constraint(
    ::Optimizer,
    ::Type{MOI.VectorOfVariables},
    ::Type{MOI.BinPacking{T}},
) where {T <: Real}
    return true
end

function _build_constraint(
    model::Optimizer,
    f::MOI.VectorOfVariables,
    s::MOI.BinPacking{T},
) where {T}
    n = length(s.weights)
    bin_vars = _parse_to_vars(model, f)
    weights = Int32.(round.(Int, s.weights))
    capacity = Int32(round(Int, s.capacity))
    # MOI uses 1-based bin indices; MaxiCP uses 0-based.
    # Shift bin variables: bin_maxicp[i] = bin_moi[i] - 1
    shifted = IntExpression[
        jcall(MFactory, "minus", IntExpression, (IntExpression, jint), v, Int32(1))
        for v in bin_vars
    ]
    # Determine number of bins from variable bounds.
    # Read actual domain max from the Java variable if bounds aren't tracked.
    max_bin = 0
    for vi in f.variables
        info = _info(model, vi)
        ub = info.ub
        if ub === nothing
            ub = Int(jcall(info.variable, "max", jint, ()))
        end
        max_bin = max(max_bin, ub)
    end
    n_bins = max_bin  # MOI bins are 1..max_bin, MaxiCP bins are 0..max_bin-1
    total_weight = Int32(sum(weights))
    loads = IntExpression[
        jcall(model.inner, "intVar", JIntVar, (jint, jint), Int32(0), min(capacity, total_weight))
        for _ in 1:n_bins
    ]
    return jcall(
        MFactory, "binPacking", JConstraint,
        (Vector{IntExpression}, Vector{jint}, Vector{IntExpression}),
        shifted, weights, loads,
    )
end

# SubCircuit constraint (raw CP, posted after cpInstantiate)

function MOI.supports_constraint(
    ::Optimizer,
    ::Type{MOI.VectorOfVariables},
    ::Type{SubCircuit},
)
    return true
end

# Table constraint

function MOI.supports_constraint(
    ::Optimizer,
    ::Type{MOI.VectorOfVariables},
    ::Type{MOI.Table{T}},
) where {T <: Real}
    return true
end

function _build_constraint(
    model::Optimizer,
    f::MOI.VectorOfVariables,
    s::MOI.Table{T},
) where {T <: Real}
    vars = _parse_to_vars(model, f)
    table = Int32.(s.table)
    return _call_factory_table(vars, table)
end
