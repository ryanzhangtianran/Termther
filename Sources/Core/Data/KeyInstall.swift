import Foundation
import Net
import SSH

/// Puts a freshly made public key onto a server.
///
/// The password is asked for once and used once: it authenticates a single
/// connection whose only job is to append the key, and it is never stored.
/// After this the key is what logs in, which is the whole point of making one.
public enum KeyInstall {
    public enum Outcome: Sendable, Equatable {
        case installed
        case rejected(String)
        case failed(String)
    }

    public static func install(publicKey: String,
                               host: String, port: UInt16, username: String,
                               password: String,
                               over transport: any SSHTransport = DirectTransport(),
                               replacing previous: String? = nil) async -> Outcome {
        let session = SSHSession()
        defer { Task { await session.disconnect() } }

        do {
            try await session.connect(to: host, port: port, over: transport)
        } catch {
            return .failed(String(describing: error))
        }

        do {
            try await session.authenticate(username: username, password: password)
        } catch {
            // Told apart from a connection problem, because the answer is
            // different: one means try the password again, the other means the
            // server is not reachable at all.
            return .rejected(String(describing: error))
        }

        do {
            let result = try await session.exec(
                SSHKeys.installScript(publicKey: publicKey, replacing: previous))
            guard result.exitStatus == 0 else {
                let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failed(message.isEmpty ? "exit \(result.exitStatus)" : message)
            }
            return .installed
        } catch {
            return .failed(String(describing: error))
        }
    }
}
