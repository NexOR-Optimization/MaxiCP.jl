function _build_constraint(
    model::Optimizer,
    f::MOI.VectorOfVariables,
    ::MOI.AllDifferent,
)
    vars = _parse_to_vars(model, f)
    return jcall(MFactory, "allDifferent", JConstraint, (Vector{IntExpression},), vars)
end
