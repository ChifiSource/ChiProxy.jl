
module ChiProxy
using Toolips
import Toolips: route!, AbstractConnection, getindex, Route

abstract type AbstractProxyRoute <: Toolips.AbstractRoute end

abstract type AbstractSource end

abstract type Balanced{T <: Number} end

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
    Toolips.proxy_pass!(c, "http://$(string(pr.ip4))")
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

proxy_route(hostname::String, send_to::IP4) = begin
    ProxyRoute{Connection}(hostname, send_to)::ProxyRoute{Connection}
end

function route!(c::Toolips.AbstractConnection, pr::AbstractSourceRoute)
    rt = source!(c, pr.src)
end

function source(path::String, to::IP4)
    srcinfo::Dict{Symbol, IP4} = Dict{Symbol, IP4}(:ip => to)
    src = Source{IP4}(srcinfo)
    SourceRoute{Connection, IP4}(path, src)
end


function source!(c::Toolips.AbstractConnection, source::Source{IP4})
    Toolips.proxy_pass!(c, "http://$(string(source[:ip]))")
end


function source(f::Function, path::String, to::IP4)
    srcinfo::Dict{Symbol, String} = Dict{Symbol, String}(:backup => f, :to => to)
    
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

function source(path::String, loads::SourceRoute{<:Any, <:Any} ...)
    srcinfo::Dict{Symbol, Any} = Dict{Symbol, Any}(:routes => [root for root in loads], :at => 1)
    src = Source{Balanced{Integer}}(srcinfo)
    SourceRoute{Connection, Balanced{Integer}}(path, src)
end

function source!(c::Toolips.AbstractConnection, source::Source{Balanced{Integer}})
    i = source[:at]
    routes = source[:routes]
    if source[:at] > length(routes)
        source.sourceinfo[:at] = 1
    end
    source!(c, routes[source[:at]].src)
    source.sourceinfo[:at] += 1
end

function source(path::String, loads::Pair{Int64, SourceRoute{<:Any, <:Any}} ...)
    loadd = Dict{Int64, Int64}(p[1] => e for (e, p) in enumerate(loads))
    max = maximum(keys(loadd))
    srcinfo::Dict{Symbol, Any} = Dict{Symbol, Any}(:routes => [rootp[2] for rootp in loads],
    :loads => loadd, :at => 1, :active => 1)
    src = Source{Balanced{Int64}}(srcinfo)
    SourceRoute{Connection, Balanced{Int64}}(path, src)
end

function source!(c::Toolips.AbstractConnection, source::Source{Balanced{Int64}} ...)
    i = source[:at]
    loadd = source[:loads]
    if i == loadd[source.sourceinfo[:active]]
        source.sourceinfo[:active] += 1
        if :active > length(routes)
            source.sourceinfo[:active] = 1
        end
        source.sourceinfo[:at] = 1
    end
    source!(c, routes[source.sourceinfo[:active]])
    i += 1
end

function source(path::String, scale::Int64, loads::Pair{Float64, SourceRoute{<:Any, <:Any}})

end

#==
function route(r::ProxyRoute{<:Any, <:Any} ...)

end
==#


module ProxyProcessSample
    using Toolips
    r = route("/") do c::Connection
        write!(c, "we served this route through our proxy server.")
    end
end
server1 = source("127.0.0.1:8000", "127.0.0.1":8002)
server2 = source("127.0.0.1:8000", ProxyProcessSample.r)
newtest = source("127.0.0.1:8000", server1, server2)
# 404
err_404 = Toolips.default_404

module TestServer
using Toolips
main = route("/") do c::Connection
    write!(c, "</br>this is 127.0.0.1 responding")
end

export main
end

export newtest
end


