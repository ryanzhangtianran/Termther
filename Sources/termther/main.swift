// Termther.
//
//   termther                        a local shell
//   termther ssh user@host [port]   a remote shell, password from SSHPASS
//   termther --snapshot out.png     render a sample screen and exit

import App
import AppKit
import Core
import Foundation
import Net
import SSH
import VT

let arguments = CommandLine.arguments

if arguments.count >= 3, arguments[1] == "--snapshot" {
    let path = URL(fileURLWithPath: arguments[2])
    let sample = """
    \u{1b}[38;5;210m\u{e0b6}\u{1b}[0m\u{1b}[48;5;210;30m tianranzhang \u{1b}[0m\u{1b}[38;5;210;48;5;216m\u{e0b0}\u{1b}[0m\u{1b}[48;5;216;30m / \u{1b}[0m\u{1b}[38;5;216;48;5;150m\u{e0b0}\u{1b}[0m\u{1b}[48;5;150;30m base \u{1b}[0m\u{1b}[38;5;150m\u{e0b4}\u{1b}[0m
    \u{1b}[1;32m✔\u{1b}[0m 91 tests passed   \u{1b}[4munderline\u{1b}[0m  \u{1b}[9mstrike\u{1b}[0m  \u{1b}[1mbold\u{1b}[0m
    box: ┌──┬──┐  ╔══╦══╗  ▁▂▃▄▅▆▇█   cjk: 写字终端   emoji: 🚀 ✅
    """.replacingOccurrences(of: "\n", with: "\r\n")

    do {
        try await Snapshot.write(input: Array(sample.utf8), to: path, cols: 80, rows: 6)
        print("wrote \(path.path)")
        exit(0)
    } catch {
        print("snapshot failed: \(error)")
        exit(1)
    }
}

let delegate = TermtherApp()

if arguments.count >= 3, arguments[1] == "ssh" {
    let target = arguments[2]
    let parts = target.split(separator: "@", maxSplits: 1)
    guard parts.count == 2 else {
        print("usage: termther ssh user@host [port]   (password in SSHPASS)")
        exit(2)
    }
    guard let password = ProcessInfo.processInfo.environment["SSHPASS"], !password.isEmpty else {
        print("set the password in SSHPASS")
        exit(2)
    }
    let port = UInt16(arguments.count > 3 ? arguments[3] : "22") ?? 22

    // The transport is chosen here and nowhere else: a proxy, a jump host or
    // the campus VPN would slot in at exactly this line.
    let transport = DirectTransport(interfaceName: ProcessInfo.processInfo.environment["EC_IFACE"])
    delegate.initialRemote = (
        title: target,
        io: RemoteShell(
            .init(host: String(parts[1]), port: port,
                  login: .init(username: String(parts[0]), secret: password, kind: .password)),
            over: transport))
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
