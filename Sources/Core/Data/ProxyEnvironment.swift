import Foundation

/// Telling a server to use the tunnel back to this Mac.
///
/// A reverse forward on its own is inert: the port is open on the server and
/// nothing there knows to send anything to it. These are the variables every
/// ordinary command-line tool reads -- curl, wget, git, pip, npm -- so setting
/// them is what turns the tunnel into "the server's traffic comes through my
/// Mac".
public enum ProxyEnvironment {
    /// Surge's HTTP proxy, which is where this usually points.
    public static let defaultLocalPort = 6152
    /// The port opened on the server. Deliberately not 6152: it is a different
    /// machine's port and confusing the two is easy.
    public static let defaultRemotePort = 16152

    /// The variables, in the order a shell would read them.
    public static func variables(port: Int) -> [(String, String)] {
        let url = "http://127.0.0.1:\(port)"
        return [
            ("http_proxy", url), ("https_proxy", url), ("all_proxy", url),
            // The upper-case spellings exist because half of the tools read
            // one and half the other, and nobody agrees which.
            ("HTTP_PROXY", url), ("HTTPS_PROXY", url), ("ALL_PROXY", url),
            // Without this every local call goes out to the proxy and back,
            // which breaks anything talking to a service on the server itself.
            ("no_proxy", "localhost,127.0.0.1,::1"),
            ("NO_PROXY", "localhost,127.0.0.1,::1"),
        ]
    }

    /// What to run instead of a plain login shell.
    ///
    /// sshd runs this through the account's own shell, so the exports happen
    /// and then a login shell replaces it -- meaning the user still gets their
    /// normal profile, prompt and history, with the variables already set.
    /// `exec` rather than a nested shell so `exit` still ends the session once.
    public static func loginCommand(port: Int) -> String {
        let exports = variables(port: port)
            .map { "\($0.0)=\(shellQuoted($0.1))" }
            .joined(separator: " ")
        return "export \(exports); exec \"$SHELL\" -l"
    }

    /// The same variables as an environment to start a process with.
    public static func environment(port: Int) -> [String: String] {
        Dictionary(uniqueKeysWithValues: variables(port: port))
    }

    /// The names, for taking them back off again.
    public static var names: [String] {
        variables(port: 0).map(\.0)
    }

    /// What to type into a shell that is already running.
    ///
    /// A terminal that is already open cannot be handed a new environment --
    /// the process has one, and it is the one it started with. Typing the
    /// exports in is the only way to change it, and being visible is the
    /// honest form of that: something did happen to this shell.
    public static func exportCommand(port: Int) -> String {
        "export " + variables(port: port)
            .map { "\($0.0)=\(shellQuoted($0.1))" }
            .joined(separator: " ")
    }

    public static var unsetCommand: String {
        "unset " + names.joined(separator: " ")
    }

    /// Single-quoted for `sh`, with embedded quotes escaped the only way `sh`
    /// allows.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
