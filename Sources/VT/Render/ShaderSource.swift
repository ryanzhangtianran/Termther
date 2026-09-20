import Foundation

/// Finding the Metal shader source, wherever this happens to be running from.
///
/// Not `Bundle.module`. That accessor traps when it cannot find its bundle, so
/// a resource that fails to travel with the app is not an error path but a
/// crash on the first frame -- and it looked fine on the machine that built it,
/// because SwiftPM's generated lookup falls back to the absolute path of the
/// build directory, which exists only there.
///
/// The bundle SwiftPM produces for this target has no `Info.plist`, so it is
/// not a valid bundle at all; `Bundle(url:)` accepts it on some versions of
/// macOS and refuses it on others. Rather than depend on which, this looks for
/// the file directly and treats not finding it as the error it is.
enum ShaderSource {
    static func metal() -> String? {
        for url in candidates() {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return nil
    }

    /// Every layout this file is known to arrive in, most likely first.
    private static func candidates() -> [URL] {
        var urls: [URL] = []
        let names = ["shaders.metal-source", "shaders.metal"]

        func appendBundleLayouts(at root: URL) {
            for name in names {
                urls.append(root.appending(path: name))
                urls.append(root.appending(path: "Contents/Resources").appending(path: name))
            }
        }

        // In an app bundle: beside the other resources, and inside the
        // SwiftPM-shaped bundle the build script copies there.
        if let resources = Bundle.main.resourceURL {
            for name in names {
                urls.append(resources.appending(path: name))
            }
            appendBundleLayouts(at: resources.appending(path: "Termther_VT.bundle"))
        }

        // Running from the build directory, which is what tests do: the
        // resource bundle sits beside the binary.
        let beside = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
        appendBundleLayouts(at: beside.appending(path: "Termther_VT.bundle"))
        appendBundleLayouts(at: beside)

        // A framework or test bundle carrying it directly.
        if let own = Bundle(for: Marker.self).resourceURL {
            for name in names {
                urls.append(own.appending(path: name))
            }
            appendBundleLayouts(at: own.appending(path: "Termther_VT.bundle"))
        }
        return urls
    }

    /// Only here to give `Bundle(for:)` something in this module to find.
    private final class Marker {}
}
