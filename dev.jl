using Pkg; Pkg.activate(".")
using Toolips
using ChiProxy
using ChiProxy: TestServer

Toolips.start!(ChiProxy, "127.0.0.1":80)

Toolips.start!(TestServer)