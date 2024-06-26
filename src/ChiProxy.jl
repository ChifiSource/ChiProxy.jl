
module ChiProxy
using Toolips
import Toolips: route!, AbstractConnection, getindex, Route

abstract type AbstractProxyRoute <: Toolips.AbstractRoute end

abstract type ProxyMultiRoute <: AbstractProxyRoute end

mutable struct BalancedMultiRoute <: ProxyMultiRoute
    path::String
    sources::Vector{AbstractProxyRoute}
    loads::Vector{Float64}
    status::Pair{Int64, Int64}
    scale::Int64
end

abstract type AbstractSource end

struct Source{T <: Any} <: AbstractSource
    sourceinfo::Dict{Symbol, <:Any}
end

getindex(src::Source{<:Any}, info::Symbol) = getindex(src.sourceinfo, info)


mutable struct ProxyRoute{T <: AbstractConnection} <: AbstractProxyRoute
    path::String
    ip::IP4
end

abstract type AbstractSourceRoute <: AbstractProxyRoute end

mutable struct SourceRoute{T <: AbstractConnection, SOURCE <: Any} <: AbstractSourceRoute
    path::String
    src::Source{SOURCE}
end

function route!(c::Toolips.AbstractConnection, pr::AbstractProxyRoute)
    Toolips.proxy_pass!(c, "http://$(string(pr.ip))")
end

route!(c::Connection, vec::Vector{<:AbstractProxyRoute}) = begin
    if Toolips.get_route(c) == "/favicon.ico"
        write!(c, "no icon here, fool")
        return
    end
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
    srcinfo::Dict{Symbol, IP4} = Dict{Symbol, IP4}(:ip => to)
    src = Source{IP4}(srcinfo)
    SourceRoute{Connection, IP4}(path, src)
end

function source!(c::Toolips.AbstractConnection, source::Source{IP4})
    Toolips.proxy_pass!(c, "http://$(string(source[:ip]))")
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


server1 = proxy_route("192.168.1.15", "127.0.0.1":8000)
server2 = proxy_route("192.168.1.15", "127.0.0.1":8001)

# 404
err_404 = Toolips.default_404

balances = proxy_route("192.168.1.15", .5 => server1, .5 => server2, scale = 10)

module TestServer1
using Toolips
main = route("/") do c::Connection
    write!(c, "message from server 1")
end

export main
end

module TestServer2
using Toolips
main = route("/") do c::Connection
    write!(c, "message from server 2")
end

export main
end

export balances
end


