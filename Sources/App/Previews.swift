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
            model.showSampleLoads()
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

extension AppModel {
    /// Readings for the sample servers, so the monitor has something to
    /// show: one with eight GPUs, one with none, one not answered yet.
    func showSampleLoads() {
        func load(cpu: Double, memory: (Double, Double), disk: Double, gpus: [Double] = []) -> ServerLoad {
            var load = ServerLoad()
            load.cpuPercent = cpu
            load.memoryUsed = UInt64(memory.0 * 1_073_741_824)
            load.memoryTotal = UInt64(memory.1 * 1_073_741_824)
            load.diskUsedPercent = disk
            load.load1 = cpu / 25
            load.uptime = 86_400 * 21
            load.gpus = gpus.enumerated().map { index, use in
                ServerLoad.GPU(name: "RTX 4090 #\(index)", utilizationPercent: use,
                               memoryUsed: UInt64(use / 100 * 24 * 1_073_741_824),
                               memoryTotal: 24 * 1_073_741_824)
            }
            return load
        }
        let wave = { (base: Double, swing: Double) in
            (0..<40).map { max(1, min(99, base + swing * sin(Double($0) / 3) + swing / 2 * sin(Double($0) * 7.3))) }
        }
        for server in servers {
            guard let id = server.id else { continue }
            switch server.name {
            case "db-primary":
                monitor.show(load(cpu: 64, memory: (48.2, 64), disk: 71, gpus: [96, 88, 41, 12, 100, 74, 3, 55]),
                             history: wave(55, 14), for: id)
            case "web-1":
                monitor.show(load(cpu: 2, memory: (0.6, 1.9), disk: 20), history: wave(3, 1.5), for: id)
            default:
                break
            }
        }
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
        .frame(width: 280, height: 720)
    }
}
