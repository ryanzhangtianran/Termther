// Termther.
//
//   termther                        a local shell
//   termther ssh user@host [port]   a remote shell, password from SSHPASS,
//                                   bound to TERMTHER_INTERFACE if set

import App
import AppKit
import Core
import Foundation
import Net
import SSH
import VT

let arguments = CommandLine.arguments

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
    let transport = DirectTransport(interfaceName: ProcessInfo.processInfo.environment["TERMTHER_INTERFACE"])
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
