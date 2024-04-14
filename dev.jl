using Pkg; Pkg.activate(".")
using Toolips
using ChiProxy
using ChiProxy: TestServer1, TestServer2

Toolips.start!(ChiProxy, "192.168.1.15":80)

Toolips.start!(TestServer1, "127.0.0.1":8000)

Toolips.start!(TestServer2, "127.0.0.1":8001)