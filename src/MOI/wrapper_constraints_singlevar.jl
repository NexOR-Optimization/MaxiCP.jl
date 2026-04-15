function _has_lb(model::Optimizer, index::MOI.VariableIndex)
    return _info(model, index).lb !== nothing
end

function _has_ub(model::Optimizer, index::MOI.VariableIndex)
    return _info(model, index).ub !== nothing
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VariableIndex, MOI.LessThan{T}},
) where {T <: Real}
    index = MOI.VariableIndex(c.value)
    return MOI.is_valid(model, index) && _has_ub(model, index)
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VariableIndex, MOI.GreaterThan{T}},
) where {T <: Real}
    index = MOI.VariableIndex(c.value)
    return MOI.is_valid(model, index) && _has_lb(model, index)
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VariableIndex, MOI.Interval{T}},
) where {T <: Real}
    index = MOI.VariableIndex(c.value)
    return MOI.is_valid(model, index) && _has_lb(model, index) && _has_ub(model, index)
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VariableIndex, MOI.EqualTo{T}},
) where {T <: Real}
    index = MOI.VariableIndex(c.value)
    return MOI.is_valid(model, index) &&
           _info(model, index).lb == _info(model, index).ub
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VariableIndex, MOI.ZeroOne},
)
    index = MOI.VariableIndex(c.value)
    return MOI.is_valid(model, index) && _info(model, index).is_binary
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VariableIndex, MOI.Integer},
)
    index = MOI.VariableIndex(c.value)
    return MOI.is_valid(model, index)
end

_to_int32(x::Real) = Int32(round(Int, x))
_to_int32_lb(x::Real) = Int32(ceil(Int, x))
_to_int32_ub(x::Real) = Int32(floor(Int, x))

function MOI.add_constraint(
    model::Optimizer,
    f::MOI.VariableIndex,
    s::MOI.EqualTo{T},
) where {T <: Real}
    v = _info(model, f).variable
    val = _to_int32(s.value)
    expr = jcall(MFactory, "eq", BoolExpression, (IntExpression, jint), v, val)
    _add_bool_constraint(model, expr)
    ival = Int(val)
    _info(model, f).lb = ival
    _info(model, f).ub = ival
    index = MOI.ConstraintIndex{MOI.VariableIndex, MOI.EqualTo{T}}(f.value)
    model.constraint_info[index] = ConstraintInfo(index, expr, f, s)
    return index
end

function MOI.add_constraint(
    model::Optimizer,
    f::MOI.VariableIndex,
    s::MOI.LessThan{T},
) where {T <: Real}
    v = _info(model, f).variable
    val = _to_int32_ub(s.upper)
    expr = jcall(MFactory, "le", BoolExpression, (IntExpression, jint), v, val)
    _add_bool_constraint(model, expr)
    _info(model, f).ub = Int(val)
    index = MOI.ConstraintIndex{MOI.VariableIndex, MOI.LessThan{T}}(f.value)
    model.constraint_info[index] = ConstraintInfo(index, expr, f, s)
    return index
end

function MOI.add_constraint(
    model::Optimizer,
    f::MOI.VariableIndex,
    s::MOI.GreaterThan{T},
) where {T <: Real}
    v = _info(model, f).variable
    val = _to_int32_lb(s.lower)
    expr = jcall(MFactory, "ge", BoolExpression, (IntExpression, jint), v, val)
    _add_bool_constraint(model, expr)
    _info(model, f).lb = Int(val)
    index = MOI.ConstraintIndex{MOI.VariableIndex, MOI.GreaterThan{T}}(f.value)
    model.constraint_info[index] = ConstraintInfo(index, expr, f, s)
    return index
end

function MOI.add_constraint(
    model::Optimizer,
    f::MOI.VariableIndex,
    s::MOI.Interval{T},
) where {T <: Real}
    v = _info(model, f).variable
    lb_val = _to_int32_lb(s.lower)
    ub_val = _to_int32_ub(s.upper)
    lb_expr = jcall(MFactory, "ge", BoolExpression, (IntExpression, jint), v, lb_val)
    ub_expr = jcall(MFactory, "le", BoolExpression, (IntExpression, jint), v, ub_val)
    _add_bool_constraint(model, lb_expr)
    _add_bool_constraint(model, ub_expr)
    _info(model, f).lb = Int(lb_val)
    _info(model, f).ub = Int(ub_val)
    index = MOI.ConstraintIndex{MOI.VariableIndex, MOI.Interval{T}}(f.value)
    model.constraint_info[index] = ConstraintInfo(index, nothing, f, s)
    return index
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.VariableIndex, <:Any},
)
    MOI.throw_if_not_valid(model, c)
    return MOI.VariableIndex(c.value)
end

function MOI.set(
    ::Optimizer,
    ::MOI.ConstraintFunction,
    ::MOI.ConstraintIndex{MOI.VariableIndex, S},
    ::MOI.VariableIndex,
) where {S}
    throw(MOI.SettingVariableIndexFunctionNotAllowed())
end
