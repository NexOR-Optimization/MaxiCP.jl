function _info(model::Optimizer, key::MOI.ConstraintIndex)
    if haskey(model.constraint_info, key)
        return model.constraint_info[key]
    end
    throw(MOI.InvalidIndex(key))
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{F, S},
) where {F <: MOI.AbstractFunction, S <: MOI.AbstractSet}
    info = get(model.constraint_info, c, nothing)
    return info !== nothing && typeof(info.set) == S
end

function _add_bool_constraint(model::Optimizer, expr::JavaObject)
    jcall(model.inner, "add", Nothing, (BoolExpression,), expr)
end

function _add_constraint_to_model(model::Optimizer, constr::JavaObject)
    jcall(model.inner, "add", Nothing, (JConstraint,), constr)
end

function MOI.add_constraint(
    model::Optimizer,
    f::MOI.ScalarAffineFunction{T},
    s::S,
) where {T <: Real, S <: Union{MOI.EqualTo{T}, MOI.LessThan{T}, MOI.GreaterThan{T}}}
    index = MOI.ConstraintIndex{MOI.ScalarAffineFunction{T}, S}(length(model.constraint_info) + 1)
    constr = _build_constraint(model, f, s)
    _add_bool_constraint(model, constr)
    model.constraint_info[index] = ConstraintInfo(index, constr, f, s)
    return index
end

function MOI.add_constraint(
    model::Optimizer,
    f::MOI.VectorOfVariables,
    s::MOI.AllDifferent,
)
    index = MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.AllDifferent}(length(model.constraint_info) + 1)
    constr = _build_constraint(model, f, s)
    _add_constraint_to_model(model, constr)
    model.constraint_info[index] = ConstraintInfo(index, constr, f, s)
    return index
end

function MOI.add_constraint(
    model::Optimizer,
    f::MOI.VectorOfVariables,
    s::MOI.BinPacking{T},
) where {T <: Real}
    index = MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.BinPacking{T}}(length(model.constraint_info) + 1)
    constr = _build_constraint(model, f, s)
    _add_constraint_to_model(model, constr)
    model.constraint_info[index] = ConstraintInfo(index, constr, f, s)
    return index
end

function MOI.add_constraint(
    model::Optimizer,
    f::MOI.VectorOfVariables,
    s::MOI.Circuit,
)
    index = MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.Circuit}(length(model.constraint_info) + 1)
    constr = _build_constraint(model, f, s)
    _add_constraint_to_model(model, constr)
    model.constraint_info[index] = ConstraintInfo(index, constr, f, s)
    return index
end

function MOI.add_constraint(
    model::Optimizer,
    f::MOI.VectorOfVariables,
    s::MOI.Table{T},
) where {T <: Real}
    index = MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.Table{T}}(length(model.constraint_info) + 1)
    constr = _build_constraint(model, f, s)
    _add_constraint_to_model(model, constr)
    model.constraint_info[index] = ConstraintInfo(index, constr, f, s)
    return index
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{F, S},
) where {F <: MOI.AbstractFunction, S <: MOI.AbstractSet}
    return _info(model, c).f
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{F, S},
) where {F <: MOI.AbstractFunction, S <: MOI.AbstractSet}
    return _info(model, c).set
end
