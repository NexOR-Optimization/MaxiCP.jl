using Downloads

const MAXICP_VERSION = "0.0.3"
const MAXICP_URL = "https://repo1.maven.org/maven2/org/maxicp/maxicp/$MAXICP_VERSION/maxicp-$MAXICP_VERSION.jar"

const DEPSFILE = joinpath(@__DIR__, "deps.jl")
if isfile(DEPSFILE)
    rm(DEPSFILE)
end

function write_depsfile(path)
    open(DEPSFILE, "w") do f
        println(f, "const maxicp_jar = \"$(escape_string(path))\"")
    end
end

# A JDK tool, from `JAVA_HOME` or the `PATH`.
function jdk_tool(name)
    if haskey(ENV, "JAVA_HOME")
        path = joinpath(ENV["JAVA_HOME"], "bin", name)
        isfile(path) && return path
    end
    path = Sys.which(name)
    path === nothing && error("MaxiCP: `$name` not found; install a JDK and set `JAVA_HOME`.")
    return path
end

# Compile the Java sources of `java/`, the search helpers and the routing
# engine of `MathOptVRP` models, into `maxicp_helper.jar`.
function build_helper(maxicp_jar)
    sources = String[]
    for (root, _, files) in walkdir(joinpath(@__DIR__, "java"))
        append!(sources, joinpath(root, f) for f in files if endswith(f, ".java"))
    end
    mktempdir() do classes
        run(`$(jdk_tool("javac")) --release 21 -cp $maxicp_jar -d $classes $sources`)
        run(`$(jdk_tool("jar")) cf $(joinpath(@__DIR__, "maxicp_helper.jar")) -C $classes .`)
    end
end

const JAR_PATH = joinpath(@__DIR__, "maxicp.jar")
Downloads.download(MAXICP_URL, JAR_PATH; verbose=true)
if isfile(JAR_PATH)
    build_helper(JAR_PATH)
    write_depsfile(JAR_PATH)
end
