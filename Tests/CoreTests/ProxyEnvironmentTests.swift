import Testing
@testable import Core

/// The exports that make a reverse tunnel actually do something.
///
/// A tunnel nothing points at is invisible, and these variables are what point
/// at it -- so their exact shape is the difference between "the server's
/// traffic goes through my Mac" and a port sitting open doing nothing.
struct ProxyEnvironmentTests {
    @Test("every spelling a command-line tool might read is set")
    func coversBothSpellings() {
        let names = Set(ProxyEnvironment.variables(port: 16152).map(\.0))
        // Half the tools read the lower-case names and half the upper-case
        // ones, and nobody agrees which.
        #expect(names.isSuperset(of: ["http_proxy", "https_proxy", "all_proxy"]))
        #expect(names.isSuperset(of: ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"]))
    }

    @Test("the proxy is the server's own loopback, not ours")
    func pointsAtTheServersLoopback() {
        let values = ProxyEnvironment.variables(port: 16152)
        // The tunnel's far end is on the server, so from a program running
        // there the proxy is at 127.0.0.1 -- naming this Mac would send it
        // looking for a machine it cannot reach.
        #expect(values.first { $0.0 == "http_proxy" }?.1 == "http://127.0.0.1:16152")
    }

    @Test("local traffic is kept out of the tunnel")
    func localTrafficBypasses() {
        let values = ProxyEnvironment.variables(port: 16152)
        let bypass = values.first { $0.0 == "no_proxy" }?.1
        // Without this, a call to a service on the server itself goes out
        // through the tunnel and back, which breaks it.
        #expect(bypass?.contains("127.0.0.1") == true)
        #expect(bypass?.contains("localhost") == true)
    }

    @Test("the login command execs a login shell, so the terminal is normal")
    func execsALoginShell() {
        let command = ProxyEnvironment.loginCommand(port: 16152)
        #expect(command.hasPrefix("export "))
        // exec rather than a nested shell: otherwise the first `exit` drops
        // into the wrapper instead of ending the session.
        #expect(command.contains("exec \"$SHELL\" -l"))
    }

    @Test("values are quoted, so a port cannot smuggle in a command")
    func valuesAreQuoted() {
        let command = ProxyEnvironment.loginCommand(port: 16152)
        #expect(command.contains("'http://127.0.0.1:16152'"))
        #expect(ProxyEnvironment.shellQuoted("don't; rm -rf /")
                == "'don'\\''t; rm -rf /'")
    }
}
