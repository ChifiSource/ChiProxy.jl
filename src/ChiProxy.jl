
module ChiProxy
using Toolips
using Toolips.HTTP
import Toolips: route!, AbstractConnection, getindex, Route, setindex!
using Toolips.Sockets

abstract type AbstractProxyRoute <: Toolips.AbstractHTTPRoute end

abstract type ProxyMultiRoute <: AbstractProxyRoute end

mutable struct BalancedMultiRoute <: ProxyMultiRoute
    path::String
    sources::Vector{AbstractProxyRoute}
    loads::Vector{Float64}
    status::Pair{Int64, Int64}
    scale::Int64
end

#==
Potential SSL implementation for future. (not currently possible in julia)
==#

function load_cert_and_key(cert_path, key_path)
  #  crt = MbedTLS.crt_parse_file(cert_path)
   # pkctx = MbedTLS.parse_keyfile(key_path)
   # return crt, pkctx
end

function start_tls_server(cert_path::AbstractString, key_path::AbstractString)
    port = 443
	crt, key = load_cert_and_key(cert_path, key_path)
    @async HTTP.serve(HTTP.Router() do req::HTTP.Request
        HTTP.Response(200, "hello")
    end, "127.0.0.1", 443;
    ssl_config = HTTP.SSLConfig(cert_path, key_path))
end

function handle_client_tls(ctx)
	req = String(readavailable(ctx))
	method, path = match(r"^([A-Z]+) ([^ ]+)", req).captures
	headers = Dict("User-Agent" => "TLSProxy")
	resp = HTTP.request(method, "https://httpbin.org$path", headers)
	write(ctx, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n")
	write(ctx, resp.body)
	close(ctx)
end

abstract type AbstractSource end

struct Source{T <: Any} <: AbstractSource
    sourceinfo::Dict{Symbol, Any}
end

getindex(src::Source{<:Any}, info::Symbol) = getindex(src.sourceinfo, info)

setindex!(src::Source{<:Any}, val::Any, name::Symbol) = src.sourceinfo[name] = val 


mutable struct ProxyRoute{T <: AbstractConnection} <: AbstractProxyRoute
    path::String
    ip::IP4
end

abstract type AbstractSourceRoute <: AbstractProxyRoute end

mutable struct SourceRoute{T <: AbstractConnection, SOURCE <: Any} <: AbstractSourceRoute
    path::String
    src::Source{SOURCE}
end

function standard_proxy!(c::Toolips.AbstractConnection, to::IP4)
    client_ip::String = Toolips.get_ip(c)
    target_url = "http://$(string(to))" * c.stream.message.target
    headers = Toolips.get_headers(c)
    f = findfirst(h -> contains(h[1], "X-Forwarded-For"), headers)
    if ~(isnothing(f))
        deleteat!(headers, f)
    end
    push!(headers, "X-Forwarded-For" => client_ip)
    response = nothing
    if get_method(c) == "GET"
        response = HTTP.request("GET", target_url, headers)
    else
        body = Toolips.get_post(c)
        response = HTTP.request("POST", target_url, headers, body)
    end
    bod = String(response.body)
    bod::String
end

function route!(c::Toolips.AbstractConnection, pr::AbstractProxyRoute)
    bod = standard_proxy!(c, pr.ip)
    write!(c, bod)
end

route!(c::Connection, vec::Vector{<:AbstractProxyRoute}) = begin
    selected_route::String = get_host(c)
    if selected_route in vec
        route!(c, vec[selected_route])
    else
        write!(c, "this route is not here")
    end
end

function route!(c::Toolips.AbstractConnection, pr::AbstractSourceRoute)
    rt = source!(c, pr.src)
end

function route!(c::Toolips.AbstractConnection, pr::BalancedMultiRoute)
    current_source::Int64 = pr.status[1]
    current_count::Int64 = pr.status[2]
    if current_count / pr.scale >= pr.loads[current_source]
        current_source += 1
        current_count = 0
        if current_source > length(pr.sources)
            current_source = 1
        end
    end
    current_count += 1
    pr.status = current_source => current_count
    route!(c, pr.sources[current_source])
end

proxy_route(hostname::String, send_to::IP4) = begin
    ProxyRoute{Connection}(hostname, send_to)::ProxyRoute{Connection}
end

proxy_route(path::String, routes::Pair{Float64, <:AbstractProxyRoute} ...; scale::Int64 = 100) = begin
    loads::Vector{Float64} = Vector{Float64}()
    new_routes::Vector{AbstractProxyRoute} = Vector{AbstractProxyRoute}()
    for r in routes
        push!(loads, r[1])
        push!(new_routes, r[2])
    end
    if sum(loads) != 1.0
        throw(Toolips.RouteError("balanced proxy-route", "load balances must add up to 100 (percent)."))
    end
    BalancedMultiRoute(path, new_routes, loads, 1 => 0, scale)
end

function source(path::String, to::IP4)
    srcinfo::Dict{Symbol, Any} = Dict{Symbol, Any}(:ip => to)
    src = Source{IP4}(srcinfo)
    SourceRoute{Connection, IP4}(path, src)
end

function backup_proxy_route(f::Function, path::String, to::IP4, component::Any ...; mobile::Bool = false)
    srcinfo::Dict{Symbol, Any} = Dict{Symbol, Any}(:to => to, :dead => false, :saved => Dict{String, String}(), 
    :f => f, :comp => [component ...])
    T = if mobile
        Toolips.MobileConnection
    else
        Connection
    end
    SourceRoute{T, :backup}(path, Source{:backup}(srcinfo))
end

function source!(c::Toolips.AbstractConnection, source::Source{IP4})
    Toolips.proxy_pass!(c, "http://$(string(source[:ip]))" * get_route(c))
end

function source(path::String, to::Toolips.AbstractRoute)
    srcinfo::Dict{Symbol, Any} = Dict{Symbol, Any}(:ref => to)
    src = Source{Route}(srcinfo)
    SourceRoute{Connection, Route}(path, src)
end

function source!(c::Toolips.AbstractConnection, source::Source{Route})
    source[:ref].page(c)
end

function source(path::String, filepath::String)
    srcinfo::Dict{Symbol, String} = Dict{Symbol, String}(:f => filepath)
    src = Source{File}(srcinfo)
    SourceRoute{Connection, File}(path, src)
end

function source!(c::Toolips.AbstractConnection, source::Source{File})
    fl = Toolips.File(source[:f])
    write!(c, fl)
end

function source!(c::Toolips.AbstractConnection, source::Source{:backup})
    dead = source[:dead]
    if dead
        if haskey(source[:saved], c.stream.message.target)
            write!(c, source[:saved][c.stream.message.target], source[:comp] ...)
        else
            source[:f](c)
        end
        return
    end
    try
        bod = standard_proxy!(c, source[:to])
        
        TARGET = c.stream.message.target
        @info "got response $TARGET"
        if ~(haskey(source[:saved], TARGET)) && ~(contains(replace(bod, " " => ""), "location.href='$TARGET'")) && get_method(c) != "POST"
            push!(source[:saved], c.stream.message.target => bod)
        end
        if ~(eof(c))
            return
        end
        write!(c, bod)
    catch e
        @info "caught error and dead $e"
        if ~(typeof(e) != HTTP.Exceptions.ConnectError)
            source[:dead] = true
        end
        if haskey(source[:saved], c.stream.message.target)
            write!(c, source[:saved][c.stream.message.target], source[:comp] ...)
        else
            source[:f](c)
        end
        if !haskey(source.sourceinfo, :ping_task) || istaskdone(source[:ping_task])
            source[:ping_task] = @async begin
                while source[:dead]
                    @info "pinged reconnect"
                    try
                        bod = get(source[:to])
                        source[:dead] = false
                        # redundant break (for clarity and punctuation, loop ends here.)
                        break
                    catch e
                        @warn e
                    end
                    sleep(100)
                end
            end
        end
    end
end

ROUTES = Vector{AbstractProxyRoute}()

function parse_source(t::Type{Source{<:Any}}, raw::AbstractString)
    @warn "could not parse proxy from source $(t.parameters[1])"
end

function parse_source(t::Type{Source{IP4}}, raw::AbstractString)
    @warn "could not parse proxy from source $(t.parameters[1])"
    @info ""
end

function load_config(raw::String)
    [begin
        tend = findfirst(";", pr)
        if isnothing(tend)
            throw("not a valid configuration")
        end
        tend = minimum(tend)
        T_nstr = pr[1:tend - 1]
        parse_source(Source{Symbol(T_nstr)}, pr[tend + 1:end])
    end for pr in split(raw, "|\n")]
end
#==
IP4;path;127.0.0.1;8000|
==#

function config_str(r::ProxyRoute)
    "IP4;$(r.path);$(r.ip.ip);$(r.ip.port)"
end

function save_config(path::String = pwd() * "/proxy.conf.d", routes::Vector{AbstractProxyRoute} = ChiProxy.ROUTES)
    open(path, w) do o::IOStream 
        for r in routes
            write(o, config_str(r))
        end
    end
    @info "saved server configuration to $path"
end

function start(ip::IP4 = "127.0.0.1":8000, server_routes::AbstractProxyRoute ...; TLS::Bool = false, 
    cert_path::String = "", key_path::String = "", args ...)
    ChiProxy.ROUTES = [server_routes ...]
    start!(ChiProxy, ip, router_type = AbstractProxyRoute; args ...)
    if TLS
        @warn "SSL, unfortunately, has yet to be implemented and will likely require a new C wrapper to fully implement."
        @info "The typical use-case for `ChiProxy` lies *beneath* an exterior proxy, usually `nginx` -- giving us tighter, Julia-bound control of our proxy sources from that server."
        throw("TLS servers have yet to be implemented. Native Julia packages have yet to support this possibility (to developer's knowledge)")
        if cert_path == "" || key_path == ""
            @warn "TLS is set to true, but no 'cert_path` or `key_path` provided"
            @info "if you are on Unix, perhaps the following may help you..."
            @info "openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes"
            @warn "(and then ChiProxy.start(..., key_path = \"key.pem\", cert_path = \"cert.pem\", SSL = true))"
            throw("TLS is set to true, but no 'cert_path` or `key_path` provided")
        end
        start_tls_server(cert_path, key_path)
    end
end

function start(source_ip::IP4, prox::Pair{String, IP4} ...; args ...)
    start(source_ip, [ProxyRoute(pathip[1], pathip[2]) for pathip in prox] ...; args ...)
end

function start(ip::IP4, config_path::String = pwd() * "/proxy.conf.d"; args ...)
    ChiProxy.routes = load_config(config_path)
    start!(ip, server_routes, router_type = AbstractProxyRoute; args ...)
end


export ROUTES, proxy_route
end


