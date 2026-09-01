import Core
import Foundation
import Observation

/// Whether terminals on this machine go out through the proxy.
///
/// No tunnel involved: Surge is already here, and a local shell only needs to
/// be told about it. That makes this a different thing from the reverse tunnel
/// a server needs, even though both end at the same port -- and worth its own
/// switch, because turning one on has never implied the other.
@MainActor
@Observable
final class LocalProxy {
    private(set) var isOn = false

    /// Where the proxy is. The same number the reverse tunnels use: it is one
    /// fact about this machine, kept in one place.
    var port = ProxyEnvironment.defaultLocalPort

    private let store: Store

    init(store: Store) {
        self.store = store
    }

    func restore() async {
        isOn = (try? await store.setting("localProxy")) == "on"
        apply()
    }

    /// Flips it, and returns what to type into the terminal that is open.
    ///
    /// A running shell has the environment it started with; nothing can reach
    /// in and change it. So new terminals get it at birth, and the one in
    /// front of you is offered the line that does the same thing -- visible,
    /// because something really did happen to that shell.
    @discardableResult
    func toggle() -> String {
        isOn.toggle()
        apply()
        Task { try? await store.setSetting("localProxy", to: isOn ? "on" : "off") }
        return isOn ? ProxyEnvironment.exportCommand(port: port)
                    : ProxyEnvironment.unsetCommand
    }

    private func apply() {
        LocalShell.newShellEnvironment = isOn ? ProxyEnvironment.environment(port: port) : [:]
    }
}
