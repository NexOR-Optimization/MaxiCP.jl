using Downloads

const MAXICP_VERSION = "faef72ee7d"
const MAXICP_URL = "https://jitpack.io/com/github/aia-uclouvain/maxicp/$MAXICP_VERSION/maxicp-$MAXICP_VERSION.jar"

const DEPSFILE = joinpath(@__DIR__, "deps.jl")
if isfile(DEPSFILE)
    rm(DEPSFILE)
end

function write_depsfile(path)
    open(DEPSFILE, "w") do f
        println(f, "const maxicp_jar = \"$(escape_string(path))\"")
    end
end

const JAR_PATH = joinpath(@__DIR__, "maxicp.jar")
Downloads.download(MAXICP_URL, JAR_PATH; verbose=true)
if isfile(JAR_PATH)
    write_depsfile(JAR_PATH)
end

function _find_java_tool(name::String)
    # First try Sys.which (uses PATH)
    path = Sys.which(name)
    path !== nothing && return path
    # Then try JAVA_HOME
    java_home = get(ENV, "JAVA_HOME", "")
    if !isempty(java_home)
        candidate = joinpath(java_home, "bin", name)
        isfile(candidate) && return candidate
    end
    return nothing
end

# Compile the SearchHelper Java class needed for the MOI wrapper
const HELPER_JAR = joinpath(@__DIR__, "maxicp_helper.jar")
const JAVA_SRC = joinpath(@__DIR__, "java", "SearchHelper.java")
if isfile(JAR_PATH) && isfile(JAVA_SRC)
    javac = _find_java_tool("javac")
    jar_cmd = _find_java_tool("jar")
    if javac !== nothing && jar_cmd !== nothing
        tmpdir = mktempdir()
        try
            run(`$javac -cp $JAR_PATH -d $tmpdir $JAVA_SRC`)
            run(`$jar_cmd cf $HELPER_JAR -C $tmpdir SearchHelper.class`)
        catch e
            @warn "Failed to compile SearchHelper.java" exception = e
        finally
            rm(tmpdir; recursive = true, force = true)
        end
    else
        @warn "javac or jar not found; SearchHelper.jar not built. MOI wrapper will not work."
    end
end
