function _build_constraint(
    model::Optimizer,
    f::MOI.VectorOfVariables,
    ::MOI.AllDifferent,
)
    vars = _parse_to_vars(model, f)
    return jcall(MFactory, "allDifferent", JConstraint, (Vector{IntExpression},), vars)
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
