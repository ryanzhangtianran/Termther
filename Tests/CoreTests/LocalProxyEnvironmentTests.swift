import Testing
@testable import Core

/// Handing a shell the proxy, at birth or afterwards.
///
/// The two forms exist because a process has the environment it started with
/// and nothing can reach in and change it: a new terminal is given the
/// variables, and one already open has to be told.
struct LocalProxyEnvironmentTests {
    @Test("the environment and the export line say the same thing")
    func bothFormsAgree() {
        let environment = ProxyEnvironment.environment(port: 6152)
        let command = ProxyEnvironment.exportCommand(port: 6152)

        #expect(environment["http_proxy"] == "http://127.0.0.1:6152")
        for (name, value) in environment {
            // Every variable in one form appears in the other; a shell told
            // half of it would send some traffic through and some around.
            #expect(command.contains("\(name)='\(value)'"),
                    "\(name) missing from the export line")
        }
    }

    @Test("turning it off names every variable turning it on set")
    func unsetIsComplete() {
        let unset = ProxyEnvironment.unsetCommand
        for name in ProxyEnvironment.environment(port: 6152).keys {
            // A leftover HTTPS_PROXY after switching off is the kind of thing
            // that gets blamed on the network an hour later.
            #expect(unset.contains(name), "\(name) would survive being switched off")
        }
    }

    @Test("the export line is a single command a shell can run")
    func exportIsOneLine() {
        let command = ProxyEnvironment.exportCommand(port: 6152)
        #expect(command.hasPrefix("export "))
        #expect(!command.contains("\n"))
    }

    @Test("a local shell is told about the proxy on this machine, not a tunnel")
    func localPointsAtSurgeDirectly() {
        // The difference from the reverse tunnel: a server's terminal is
        // pointed at a port on the server, this one at the proxy itself.
        #expect(ProxyEnvironment.environment(port: ProxyEnvironment.defaultLocalPort)["http_proxy"]
                == "http://127.0.0.1:6152")
    }
}
