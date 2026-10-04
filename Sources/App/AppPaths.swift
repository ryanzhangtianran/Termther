import Core
import Foundation
import Observation

/// Where the app keeps and reads its files, as set on the General page.
///
/// Three places: its own data directory, where the agents' profiles live;
/// the keys directory, where a generated key is written and the Keys list
/// reads; and the ssh config the servers are kept in line with. Each is
/// `~`-relative by default and remembered in the store once changed. Moving
/// one moves nothing on disk -- the files stay where they were.
@MainActor
@Observable
final class AppPaths {
    enum Location: String, CaseIterable {
        case data = "path.data"
        case keys = "path.keys"
        case sshConfig = "path.sshConfig"
    }

    static let defaultData = URL.homeDirectory.appending(path: ".termther", directoryHint: .isDirectory)

    private var urls: [Location: URL] = [
        .data: defaultData, .keys: SSHKeys.sshDirectory, .sshConfig: SSHConfig.defaultURL,
    ]

    private let store: Store

    init(store: Store) {
        self.store = store
    }

    subscript(location: Location) -> URL { urls[location]! }

    /// What the store says, over the defaults. The store is an actor, so
    /// this cannot be the initialiser.
    func restore() async {
        for location in Location.allCases {
            if let path = try? await store.setting(location.rawValue) {
                urls[location] = URL(fileURLWithPath: path, isDirectory: location != .sshConfig)
            }
        }
    }

    func set(_ location: Location, to url: URL) async throws {
        try await store.setSetting(location.rawValue, to: url.path)
        urls[location] = url
    }
}
