function _parse_to_vars(model::Optimizer, f::MOI.VectorOfVariables)
    return IntExpression[_info(model, v).variable for v in f.variables]
end
