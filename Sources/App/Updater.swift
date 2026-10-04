import AppKit
import Foundation

/// Updates the app from the latest GitHub release, by Check for Updates in
/// the app menu.
///
/// The release's .dmg is downloaded and its app checked -- a valid signature,
/// this app's bundle identifier -- before it replaces this one, which then
/// relaunches. Asked first; nothing is installed behind the user's back.
@MainActor
enum Updater {
    static let latest = URL(string: "https://api.github.com/repos/ryanzhangtianran/Termther/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func checkForUpdates() async {
        let app = Bundle.main.bundleURL
        // `swift run` has no bundle to replace.
        guard app.pathExtension == "app",
              let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let identifier = Bundle.main.bundleIdentifier else {
            alert("Not an installed app", "Only Termther.app can update itself.")
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: latest)
            try requireOK(response)
            let release = try JSONDecoder().decode(Release.self, from: data)
            let version = String(release.tag_name.trimmingPrefix("v"))
            // Numeric, so 1.0.10 is newer than 1.0.9.
            guard version.compare(current, options: .numeric) == .orderedDescending else {
                alert("Termther is up to date", "Version \(current) is the latest release.")
                return
            }
            guard let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
                throw Failure("release \(release.tag_name) has no .dmg")
            }
            guard alert("Termther \(version) is available",
                        "You have \(current). Install it and relaunch? Open terminals will close.",
                        buttons: ["Install and Relaunch", "Later"])
            else { return }

            let (download, downloaded) = try await URLSession.shared.download(from: dmg.browser_download_url)
            try requireOK(downloaded)
            try await Task.detached { try install(download, replacing: app, identifier: identifier) }.value
            relaunch(app)
        } catch {
            alert("Could not update", "\(error)")
        }
    }

    /// Mounts the image, checks its app, and swaps it in for `app`. The copy
    /// is staged beside the old one so the swap is a rename on one volume:
    /// a half-copied app is never left where the old one was.
    nonisolated private static func install(_ dmg: URL, replacing app: URL, identifier: String) throws {
        let files = FileManager.default
        let mount = files.temporaryDirectory.appending(path: "termther-update-\(UUID().uuidString)")
        try run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path)
        defer { try? run("/usr/bin/hdiutil", "detach", mount.path, "-force") }

        let new = mount.appending(path: "Termther.app")
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", new.path)
        guard Bundle(url: new)?.bundleIdentifier == identifier else {
            throw Failure("the downloaded app is not Termther")
        }

        let staged = app.deletingLastPathComponent().appending(path: ".Termther-update.app")
        try? files.removeItem(at: staged)
        try run("/usr/bin/ditto", new.path, staged.path)
        // Gone already once the swap succeeds; left over only if it failed.
        defer { try? files.removeItem(at: staged) }
        _ = try files.replaceItemAt(app, withItemAt: staged)
    }

    /// Opens the new app once this process has gone, by way of a shell that
    /// outlives it.
    private static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let waiter = Process()
        waiter.executableURL = URL(filePath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$0\"", app.path]
        try? waiter.run()
        NSApp.terminate(nil)
    }

    nonisolated private static func requireOK(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure("GitHub answered HTTP \(status)") }
    }

    nonisolated private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("\(URL(filePath: tool).lastPathComponent) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// True when the first of `buttons` was pressed.
    @discardableResult
    private static func alert(_ title: String, _ text: String, buttons: [String] = []) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        for button in buttons { alert.addButton(withTitle: button) }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
