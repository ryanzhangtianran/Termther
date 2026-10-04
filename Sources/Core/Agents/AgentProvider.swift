import Foundation

/// Who a profile talks to: the endpoint, the key and the model, as the
/// fields of a form rather than lines of JSON or TOML. Read from and written
/// into a profile's own files, everything else in them left as it was.
///
/// For Claude Code these are `settings.json`'s `env` entries; for Codex,
/// `config.toml`'s `model` and a provider table of its own, and the key in
/// `auth.json`. An empty field is an entry removed, so the tool's default
/// -- its own login, its own model -- takes over.
public struct AgentProvider: Equatable, Sendable {
    public var baseURL: String
    public var apiKey: String
    public var model: String

    public init(baseURL: String = "", apiKey: String = "", model: String = "") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: - Claude Code

    static let baseURLKey = "ANTHROPIC_BASE_URL"
    static let tokenKey = "ANTHROPIC_AUTH_TOKEN"
    /// Older setups name the key this; read as well, and replaced on write so
    /// the two cannot disagree.
    static let legacyKeyKey = "ANTHROPIC_API_KEY"
    static let modelKey = "ANTHROPIC_MODEL"

    // MARK: - Codex

    /// The provider table Termther writes, `[model_providers.custom]`.
    static let codexProvider = "custom"
    static let codexKey = "OPENAI_API_KEY"

    /// The fields as a profile's files have them.
    public static func read(from directory: URL, tool: AgentTool) throws -> AgentProvider {
        switch tool {
        case .claude:
            let file = directory.appending(path: "settings.json")
            let object = try JSONFile.read(file)
            let env = object["env"] as? [String: Any] ?? [:]
            return AgentProvider(baseURL: env[baseURLKey] as? String ?? "",
                                 apiKey: env[tokenKey] as? String ?? env[legacyKeyKey] as? String ?? "",
                                 model: env[modelKey] as? String ?? "")
        case .codex:
            let config = TOMLDocument(text: try CodexConfig.read(directory.appending(path: "config.toml")))
            let auth = directory.appending(path: "auth.json")
            let keys = try JSONFile.read(auth)
            let provider = config.value("model_provider", in: [])?.string
            return AgentProvider(
                baseURL: provider.flatMap { config.value("base_url", in: ["model_providers", $0])?.string } ?? "",
                apiKey: keys[codexKey] as? String ?? "",
                model: config.value("model", in: [])?.string ?? "")
        }
    }

    /// Writes the fields into a profile's files, leaving everything else in
    /// them as it is.
    public static func write(_ provider: AgentProvider, to directory: URL, tool: AgentTool) throws {
        let trimmed = AgentProvider(baseURL: provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                    apiKey: provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                    model: provider.model.trimmingCharacters(in: .whitespacesAndNewlines))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        switch tool {
        case .claude:
            let file = directory.appending(path: "settings.json")
            var object = try JSONFile.read(file)
            var env = object["env"] as? [String: Any] ?? [:]
            env[baseURLKey] = trimmed.baseURL.nilIfEmpty
            env[tokenKey] = trimmed.apiKey.nilIfEmpty
            env[legacyKeyKey] = nil
            env[modelKey] = trimmed.model.nilIfEmpty
            object["env"] = env.isEmpty ? nil : env
            try writePrivately(JSONFile.data(object), to: file)
        case .codex:
            var config = TOMLDocument(text: try CodexConfig.read(directory.appending(path: "config.toml")))
            config.set("model", to: trimmed.model.nilIfEmpty.map { .string($0) }, in: [])
            let table = ["model_providers", codexProvider]
            if trimmed.baseURL.isEmpty {
                // Whichever provider was named, not only Termther's: a table
                // of the user's own left in place kept the relay, and Official
                // could not be chosen.
                config.set("model_provider", to: nil, in: [])
                config.removeTable(table)
            } else {
                config.set("model_provider", to: .string(codexProvider), in: [])
                config.set("name", to: .string(codexProvider), in: table)
                config.set("base_url", to: .string(trimmed.baseURL), in: table)
                config.set("wire_api", to: .string("responses"), in: table)
                config.set("requires_openai_auth", to: .bool(true), in: table)
            }
            try writePrivately(Data(config.text.utf8), to: directory.appending(path: "config.toml"))

            let auth = directory.appending(path: "auth.json")
            var keys = try JSONFile.read(auth)
            keys[codexKey] = trimmed.apiKey.nilIfEmpty
            try writePrivately(JSONFile.data(keys), to: auth)
        }
    }

    /// Keys live here, so only the owner may read the file.
    private static func writePrivately(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
