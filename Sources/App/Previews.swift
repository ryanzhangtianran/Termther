import Core
import SwiftUI

extension AppModel {
    /// An unlocked model over an in-memory store with a few servers, for
    /// previews: the sidebar can be looked at without a vault to open.
    static func sample() -> AppModel {
        let model = AppModel(store: try! Store(inMemory: true))
        Task {
            // ponytail: waits out init's own vault check, which would otherwise
            // land after createVault and relock; an awaitable init fixes it.
            try? await Task.sleep(for: .milliseconds(300))
            await model.createVault(password: "sample")
            let servers = [("web-1", "10.0.0.11", "prod"), ("db-primary", "10.0.0.20", "prod"),
                           ("gpu-box", "gpu.lab.example.edu", "lab"), ("pi", "192.168.1.8", "")]
            for (name, host, tag) in servers {
                guard let saved = await model.save(Server(
                    name: name, host: host, username: "ryan",
                    routesThroughVPN: name == "gpu-box", tags: tag)),
                    let id = saved.id else { continue }
                if name == "gpu-box" {
                    _ = await model.forwards.save(PortForwardPreset(
                        serverID: id, direction: .local, bindPort: 8888,
                        targetHost: "127.0.0.1", targetPort: 8888))
                }
                if name == "db-primary" || name == "gpu-box" {
                    await model.forwards.setProxyBack(for: id, remotePort: 16152)
                }
            }
            model.shellEnvironment.variables = [.init(name: "EDITOR", value: "nvim"),
                                                .init(name: "LANG", value: "en_US.UTF-8")]
            if let (sealed, _) = await model.vpn.seal(password: "sample", totp: nil) {
                _ = await model.vpn.save(VPNProfile(
                    name: "Campus", gateway: "vpn.example.edu:443", username: "ryan",
                    sealed: sealed))
            }
        }
        return model
    }
}

// PreviewProvider rather than #Preview: the Command Line Tools ship without
// the previews macro plugin, and the build must not need Xcode.
struct ToolsSidebar_Previews: PreviewProvider {
    static var previews: some View {
        let theme = Theme()
        ToolsSidebar(workspace: Workspace(), model: .sample())
        .environment(theme)
        .themed(theme)
        .frame(width: 260, height: 720)
    }
}
