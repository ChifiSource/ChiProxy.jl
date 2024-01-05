module ChiProxy
using Toolips
import Toolips: route!

abstract type AbstractProxyRoute <: Toolips.AbstractRoute end

mutable struct ProxyRoute <: AbstractProxyRoute
    path::String
    ip::String
    port::Int64
end

function proxy_route(path::String, ip::IP4)
    ProxyRoute(path, ip.ip, ip.port)
end

function route!(c::Toolips.AbstractConnection, pr::AbstractProxyRoute)
    Toolips.proxy_pass!(c, "http://$(pr.ip):$(pr.port)")
end

function route!(c::Connection, vec::Vector{<:AbstractProxyRoute})
    route!(c, vec[get_host(c)])
end

main = route("/") do c::Connection
    write!(c, "$(c.routes)")
end

test = proxy_route("127.0.0.1", "127.0.0.1":8000)
# 404
err_404 = Toolips.default_404

module TestServer
using Toolips
main = route("/") do c::Connection
    write!(c, "</br>this is 127.0.0.1 responding")
end

export main
end

export test
end


