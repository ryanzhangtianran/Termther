import Foundation

/// Telling a server to use the tunnel back to this Mac.
///
/// A reverse forward on its own is inert: the port is open on the server and
/// nothing there knows to send anything to it. These are the variables every
/// ordinary command-line tool reads -- curl, wget, git, pip, npm -- so setting
/// them is what turns the tunnel into "the server's traffic comes through my
/// Mac".
public enum ProxyEnvironment {


    /// The variables, in the order a shell would read them.
    ///
    /// With a SOCKS5 port, `all_proxy` points at it -- the variable tools
    /// that speak SOCKS read -- and the HTTP ones stay on the HTTP port.
    public static func variables(port: Int, socksPort: Int? = nil) -> [(String, String)] {
        let url = "http://127.0.0.1:\(port)"
        return variables(web: url, all: socksPort.map { "socks5://127.0.0.1:\($0)" } ?? url)
    }

    private static func variables(web url: String, all: String) -> [(String, String)] {
        [
            ("http_proxy", url), ("https_proxy", url), ("all_proxy", all),
            // The upper-case spellings exist because half of the tools read
            // one and half the other, and nobody agrees which.
            ("HTTP_PROXY", url), ("HTTPS_PROXY", url), ("ALL_PROXY", all),
            // Without this every local call goes out to the proxy and back,
            // which breaks anything talking to a service on the server itself.
            ("no_proxy", "localhost,127.0.0.1,::1"),
            ("NO_PROXY", "localhost,127.0.0.1,::1"),
        ]
    }

    /// The Mac's system proxy -- Surge's, once it is set as the system
    /// proxy -- as the same variables, for the tools the app runs itself:
    /// they read these and never the system setting. Empty when there is
    /// none.
    public static var system: [String: String] {
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        return environment(fromSystem: settings)
    }

    /// `system`, from the settings as `CFNetworkCopySystemProxySettings`
    /// gives them: `HTTPEnable`, `HTTPProxy`, `HTTPPort`, and the same for
    /// HTTPS and SOCKS.
    static func environment(fromSystem settings: [String: Any]) -> [String: String] {
        func url(_ kind: String, _ scheme: String) -> String? {
            guard settings["\(kind)Enable"] as? Int == 1, let host = settings["\(kind)Proxy"] as? String,
                  !host.isEmpty, let port = settings["\(kind)Port"] as? Int else { return nil }
            return "\(scheme)://\(host):\(port)"
        }
        let web = url("HTTPS", "http") ?? url("HTTP", "http")
        let socks = url("SOCKS", "socks5")
        guard let any = web ?? socks else { return [:] }
        return Dictionary(uniqueKeysWithValues: variables(web: web ?? any, all: socks ?? any))
    }

    /// What to run instead of a plain login shell.
    ///
    /// sshd runs this through the account's own shell, so the exports happen
    /// and then a login shell replaces it -- meaning the user still gets their
    /// normal profile, prompt and history, with the variables already set.
    /// `exec` rather than a nested shell so `exit` still ends the session once.
    /// Later variables win over earlier ones of the same name, as they would
    /// typed in that order.
    public static func loginCommand(exporting variables: [(String, String)]) -> String {
        "\(export(variables)); exec \"$SHELL\" -l"
    }

    /// The same variables as an environment to start a process with.
    public static func environment(port: Int, socksPort: Int? = nil) -> [String: String] {
        Dictionary(uniqueKeysWithValues: variables(port: port, socksPort: socksPort))
    }

    /// What to type into a shell that is already running.
    ///
    /// A terminal that is already open cannot be handed a new environment --
    /// the process has one, and it is the one it started with. Typing the
    /// exports in is the only way to change it, and being visible is the
    /// honest form of that: something did happen to this shell.
    public static func exportCommand(port: Int, socksPort: Int? = nil) -> String {
        export(variables(port: port, socksPort: socksPort))
    }

    /// Taking them back off again.
    public static var unsetCommand: String {
        "unset " + variables(port: 0).map(\.0).joined(separator: " ")
    }

    private static func export(_ variables: [(String, String)]) -> String {
        "export " + variables.map { "\($0.0)=\(shellQuoted($0.1))" }.joined(separator: " ")
    }
}

/// Single-quoted for `sh`, with embedded quotes escaped the only way `sh`
/// allows.
public func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
