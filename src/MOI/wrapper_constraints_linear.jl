## ScalarAffineFunction-in-Set

function _build_linear_expression(model::Optimizer, f::MOI.ScalarAffineFunction{T}) where {T}
    f = MOI.Utilities.canonical(f)
    terms = f.terms
    if isempty(terms)
        c = _to_int32(f.constant)
        return jcall(model.inner, "intVar", JIntVar, (jint, jint), c, c)
    end
    exprs = JavaObject[]
    for t in terms
        v = _info(model, t.variable).variable
        c = round(Int, t.coefficient)
        if c == 1
            push!(exprs, v)
        else
            scaled = jcall(MFactory, "mul", IntExpression, (IntExpression, jint), v, Int32(c))
            push!(exprs, scaled)
        end
    end
    result = if length(exprs) == 1
        exprs[1]
    else
        jcall(MFactory, "sum", IntExpression, (Vector{IntExpression},), IntExpression[e for e in exprs])
    end
    c = round(Int, f.constant)
    if c != 0
        result = jcall(MFactory, "plus", IntExpression, (IntExpression, jint), result, Int32(c))
    end
    return result
end

function _build_constraint(
    model::Optimizer,
    f::MOI.ScalarAffineFunction{T},
    s::MOI.EqualTo{T},
) where {T <: Real}
    lhs = _build_linear_expression(model, f)
    return jcall(MFactory, "eq", BoolExpression, (IntExpression, jint), lhs, _to_int32(s.value))
end

function _build_constraint(
    model::Optimizer,
    f::MOI.ScalarAffineFunction{T},
    s::MOI.LessThan{T},
) where {T <: Real}
    lhs = _build_linear_expression(model, f)
    return jcall(MFactory, "le", BoolExpression, (IntExpression, jint), lhs, _to_int32(s.upper))
end

function _build_constraint(
    model::Optimizer,
    f::MOI.ScalarAffineFunction{T},
    s::MOI.GreaterThan{T},
) where {T <: Real}
    lhs = _build_linear_expression(model, f)
    return jcall(MFactory, "ge", BoolExpression, (IntExpression, jint), lhs, _to_int32(s.lower))
end
