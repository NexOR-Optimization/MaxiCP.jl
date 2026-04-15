function _parse_to_vars(model::Optimizer, f::MOI.VectorOfVariables)
    return IntExpression[_info(model, v).variable for v in f.variables]
end

# JavaCall doesn't support passing int[][] as an argument directly.
# We build the Java int[][] manually via JNI and call Factory.table
# with a hand-crafted method invocation.
function _call_factory_table(vars::Vector{IntExpression}, table::Matrix{Int32})
    nrows, ncols = size(table)
    int_array_class = JavaCall.JNI.FindClass("[I")
    outer = JavaCall.JNI.NewObjectArray(nrows, int_array_class, C_NULL)
    for i in 1:nrows
        row = jint.(table[i, :])
        inner = JavaCall.JNI.NewIntArray(ncols)
        JavaCall.JNI.SetIntArrayRegion(inner, 0, ncols, row)
        JavaCall.JNI.SetObjectArrayElement(outer, i - 1, inner)
        JavaCall.JNI.DeleteLocalRef(inner)
    end
    JavaCall.JNI.DeleteLocalRef(int_array_class)
    empty_opt = jcall(JOptional, "empty", JOptional, ())
    mc = JavaCall.metaclass(Symbol("org.maxicp.modeling.Factory"))
    sig = "([Lorg/maxicp/modeling/algebra/integer/IntExpression;[[ILjava/util/Optional;)Lorg/maxicp/modeling/Constraint;"
    mid = JavaCall.JNI.GetStaticMethodID(Ptr(mc), "table", sig)
    _, jvars = JavaCall.convert_arg(Vector{IntExpression}, vars)
    args = [JavaCall.jvalue(jvars), JavaCall.jvalue(outer), JavaCall.jvalue(empty_opt)]
    result = JavaCall.JNI.CallStaticObjectMethodA(Ptr(mc), mid, args)
    result == C_NULL && JavaCall.geterror()
    return JConstraint(result)
end
