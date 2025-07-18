using Pkg; Pkg.activate(".")
using Toolips
using ChiProxy

module TestServer
using Toolips

home = route("/") do c::AbstractConnection
    write!(c, "server 1")
end

export home
end

module TestServer2
using Toolips

home = route("/") do c::Toolips.AbstractConnection
    write!(c, "server 2")
end

export home
end

module Prox
using ChiProxy

main_r = ChiProxy.backup_proxy_route("192.168.1.28:8005", 
    "127.0.0.1":8000, div("-", text = "backupsamp")) do c::ChiProxy.Toolips.AbstractConnection
    write!(c, "failed to get server :()")
end
export main_r
end

Toolips.start!(Prox, "192.168.1.28":8005)

Toolips.start!(TestServer, "127.0.0.1":8000)

Toolips.start!(TestServer2, "127.0.0.1":8001)