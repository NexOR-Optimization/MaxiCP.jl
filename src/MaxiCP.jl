module MaxiCP

using JavaCall
import MathOptInterface as MOI

const depsfile = joinpath(dirname(@__FILE__), "..", "deps", "deps.jl")
if isfile(depsfile)
    include(depsfile)
else
    error(
        "MaxiCP not properly installed. Please run " *
        "`Pkg.build(\"MaxiCP\")` or `]build MaxiCP`",
    )
end

function __init__()
    if get(ENV, "JULIA_REGISTRYCI_AUTOMERGE", "") != "true"
        maxicp_java_init()
    end
end

"""
    maxicp_java_init(init_java::Bool=true)

Initialise the JVM with MaxiCP on the classpath.

If other parts of the application also require JavaCall, set `init_java=false`
and call this **before** `JavaCall.init()` so that the classpath is set up.
"""
const helper_jar = joinpath(dirname(@__FILE__), "..", "deps", "maxicp_helper.jar")

function maxicp_java_init(init_java::Bool=true)
    JavaCall.addClassPath(maxicp_jar)
    if isfile(helper_jar)
        JavaCall.addClassPath(helper_jar)
    end
    if init_java
        JavaCall.addOpts("-Xss2m")
        JavaCall.init()
    end
    return
end

include("java_wrapper.jl")
include("MOI/wrapper.jl")
include("MOI/parse.jl")
include("MOI/wrapper_constraints_cp.jl")
include("MOI/wrapper_constraints_linear.jl")
include("MOI/wrapper_constraints_singlevar.jl")
include("MOI/wrapper_constraints.jl")
include("MOI/wrapper_variables.jl")

end # module MaxiCP
