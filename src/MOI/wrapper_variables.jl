function _info(model::Optimizer, key::MOI.VariableIndex)
    if haskey(model.variable_info, key)
        return model.variable_info[key]
    end
    throw(MOI.InvalidIndex(key))
end

function _make_var(model::Optimizer, variable::JavaObject)
    index = CleverDicts.add_item(
        model.variable_info,
        VariableInfo(MOI.VariableIndex(0), variable),
    )
    _info(model, index).index = index
    return index
end

function _make_var(
    model::Optimizer,
    variable::JavaObject,
    set::MOI.AbstractScalarSet,
)
    index = _make_var(model, variable)
    S = typeof(set)
    return index, MOI.ConstraintIndex{MOI.VariableIndex, S}(index.value)
end

function _make_intvar(model::Optimizer, lb::Int32, ub::Int32)
    return jcall(model.inner, "intVar", JIntVar, (jint, jint), lb, ub)
end

function MOI.supports_add_constrained_variable(
    ::Optimizer,
    ::Type{F},
) where {
    F <: Union{
        MOI.EqualTo{Int},
        MOI.LessThan{Int},
        MOI.GreaterThan{Int},
        MOI.Interval{Int},
        MOI.EqualTo{Float64},
        MOI.LessThan{Float64},
        MOI.GreaterThan{Float64},
        MOI.Interval{Float64},
        MOI.ZeroOne,
        MOI.Integer,
    },
}
    return true
end

function MOI.add_variable(model::Optimizer)
    v = _make_intvar(model, _DEFAULT_INT_LB, _DEFAULT_INT_UB)
    return _make_var(model, v)
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.Integer)
    v = _make_intvar(model, _DEFAULT_INT_LB, _DEFAULT_INT_UB)
    vindex, cindex = _make_var(model, v, set)
    return vindex, cindex
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.ZeroOne)
    v = _make_intvar(model, Int32(0), Int32(1))
    vindex, cindex = _make_var(model, v, set)
    _info(model, vindex).is_binary = true
    _info(model, vindex).lb = 0
    _info(model, vindex).ub = 1
    return vindex, cindex
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.EqualTo{T}) where {T <: Real}
    val = _to_int32(set.value)
    v = _make_intvar(model, val, val)
    vindex, cindex = _make_var(model, v, set)
    ival = Int(val)
    _info(model, vindex).lb = ival
    _info(model, vindex).ub = ival
    return vindex, cindex
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.GreaterThan{T}) where {T <: Real}
    v = _make_intvar(model, _to_int32(set.lower), _DEFAULT_INT_UB)
    vindex, cindex = _make_var(model, v, set)
    _info(model, vindex).lb = round(Int, set.lower)
    return vindex, cindex
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.LessThan{T}) where {T <: Real}
    v = _make_intvar(model, _DEFAULT_INT_LB, _to_int32(set.upper))
    vindex, cindex = _make_var(model, v, set)
    _info(model, vindex).ub = round(Int, set.upper)
    return vindex, cindex
end

function MOI.add_constrained_variable(model::Optimizer, set::MOI.Interval{T}) where {T <: Real}
    v = _make_intvar(model, _to_int32(set.lower), _to_int32(set.upper))
    vindex, cindex = _make_var(model, v, set)
    _info(model, vindex).lb = round(Int, set.lower)
    _info(model, vindex).ub = round(Int, set.upper)
    return vindex, cindex
end

function MOI.is_valid(model::Optimizer, v::MOI.VariableIndex)
    return haskey(model.variable_info, v)
end
