import Foundation
import Security
import SwiftUI
import TasjeelCore

/// Where the Anthropic API key lives: the macOS Keychain, and nowhere else.
/// It is never written to a file, to the app's settings or to a log.
enum SecretStore {
    private static let service = "dev.tasjeel.app"
    private static let account = "anthropic-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func readKey() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var hasKey: Bool {
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Tasjeel: Anthropic API key"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deleteKey() {
        SecItemDelete(query as CFDictionary)
    }
}

/// The user's AI choices and what this Mac can run, shared by every window.
@MainActor
final class AIConfig: ObservableObject {
    static let shared = AIConfig()

    @Published var engine: AIEngineKind {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "aiEngine") }
    }

    @Published var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: "aiOllamaModel") }
    }

    @Published private(set) var found = AIAvailability()
    @Published private(set) var checked = false
    /// Set while a model is being downloaded into Ollama.
    @Published private(set) var download: Download?
    @Published var downloadError: String?

    struct Download: Equatable {
        var model: String
        var progress: Double
        var status: String
    }

    private var downloadTask: Task<Void, Never>?

    private init() {
        engine = AIEngineKind(rawValue: UserDefaults.standard.string(forKey: "aiEngine") ?? "") ?? .automatic
        ollamaModel = UserDefaults.standard.string(forKey: "aiOllamaModel") ?? ""
    }

    /// Looks again at what is available: Apple's model, Ollama, a saved key.
    func refresh() async {
        found = await AIEngines.discover(hasClaudeKey: SecretStore.hasKey)
        checked = true
    }

    /// The engine that would write notes for a transcript in `language`.
    func choice(for language: String) -> AIChoice {
        AIEngines.choose(engine, ollamaModel: ollamaModel, language: language, found: found)
    }

    func model(for language: String) throws -> any TextModel {
        try AIEngines.model(for: choice(for: language)) { SecretStore.readKey() }
    }

    // MARK: - Claude key

    func saveKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, SecretStore.saveKey(trimmed) else { return false }
        found.hasClaudeKey = true
        return true
    }

    func removeKey() {
        SecretStore.deleteKey()
        found.hasClaudeKey = false
        if engine == .claude { engine = .automatic }
    }

    // MARK: - Ollama models

    func downloadModel(_ name: String) {
        guard download == nil else { return }
        download = Download(model: name, progress: 0, status: "Starting…")
        downloadError = nil
        downloadTask = Task {
            do {
                try await OllamaClient().pull(name) { [weak self] progress, status in
                    Task { @MainActor in
                        if self?.download != nil { self?.download = Download(model: name, progress: progress, status: status) }
                    }
                }
                ollamaModel = name
            } catch is CancellationError {
                // Stopped by the user.
            } catch let error as URLError where error.code == .cancelled {
                // Stopped by the user.
            } catch {
                downloadError = error.localizedDescription
            }
            download = nil
            await refresh()
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }
}
