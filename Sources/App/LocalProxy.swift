import AppKit
import Core
import Foundation
import Observation

/// Sends an open terminal on this machine through the proxy, by the switch
/// on its row.
///
/// No tunnel involved: Surge is already here, and a local shell only needs to
/// be told about it. That makes this a different thing from the reverse tunnel
/// a server needs, even though both end at the same port -- and worth its own
/// switch, because turning one on has never implied the other.
@MainActor
@Observable
final class LocalProxy {
    /// Where the proxy is. The same number the reverse tunnels use: it is one
    /// fact about this machine, kept in one place.
    var port = ProxyEnvironment.defaultLocalPort
    /// This Mac's SOCKS5 port, for `all_proxy`; 0 for none.
    var socksPort = ProxyEnvironment.defaultSocksLocalPort
    private var socks: Int? { socksPort > 0 ? socksPort : nil }

    /// Flips one open terminal, from its next command on.
    func toggle(_ session: TerminalSession) {
        Task { await set(!session.usesProxy, in: session) }
    }

    /// Puts one open terminal through the proxy, or takes it off; true once
    /// its shell has been told. Refused with a beep while a program has the
    /// terminal.
    @discardableResult
    func set(_ on: Bool, in session: TerminalSession) async -> Bool {
        guard !session.isSwitchingProxy else { return false }
        session.isSwitchingProxy = true
        defer { session.isSwitchingProxy = false }
        let command = on ? ProxyEnvironment.exportCommand(port: port, socksPort: socks)
                         : ProxyEnvironment.unsetCommand
        let done = await session.setProxy(on, command: command)
        if !done { NSSound.beep() }
        return done
    }
}
