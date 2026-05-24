using Downloads

const MAXICP_VERSION = "0.0.2"
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

const JAR_PATH = joinpath(@__DIR__, "maxicp.jar")
Downloads.download(MAXICP_URL, JAR_PATH; verbose=true)
if isfile(JAR_PATH)
    write_depsfile(JAR_PATH)
end
