import Foundation
import Security
import SwiftUI
import TasjeelCore

/// Where API keys live: the macOS Keychain, and nowhere else. A key is never
/// written to a file, to the app's settings or to a log.
enum SecretStore {
    enum Key: String {
        case anthropic = "anthropic-api-key"
        case elevenLabs = "elevenlabs-api-key"

        var label: String {
            switch self {
            case .anthropic: return "Tasjeel: Anthropic API key"
            case .elevenLabs: return "Tasjeel: ElevenLabs API key"
            }
        }
    }

    private static let service = "dev.tasjeel.app"

    private static func query(_ key: Key) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key.rawValue]
    }

    static func readKey(_ key: Key = .anthropic) -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ key: Key) -> Bool {
        var request = query(key)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    static var hasKey: Bool { has(.anthropic) }

    @discardableResult
    static func saveKey(_ value: String, for key: Key = .anthropic) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var item = query(key)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = key.label
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deleteKey(_ key: Key = .anthropic) {
        SecItemDelete(query(key) as CFDictionary)
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

    // Voiceover (ElevenLabs)
    @Published private(set) var hasVoiceKey = false
    /// The voices in the user's ElevenLabs account, once asked for.
    @Published private(set) var voices: [ElevenLabsClient.Voice] = []
    @Published private(set) var loadingVoices = false
    @Published var voicesError: String?

    private init() {
        engine = AIEngineKind(rawValue: UserDefaults.standard.string(forKey: "aiEngine") ?? "") ?? .automatic
        ollamaModel = UserDefaults.standard.string(forKey: "aiOllamaModel") ?? ""
    }

    /// Looks again at what is available: Apple's model, Ollama, a saved key.
    func refresh() async {
        found = await AIEngines.discover(hasClaudeKey: SecretStore.hasKey)
        hasVoiceKey = voiceKey() != nil
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

    // MARK: - ElevenLabs key and voices

    /// The ElevenLabs key. A development run that pictures its own windows
    /// may be given a stand-in's key through the environment instead.
    private func voiceKey() -> String? {
        if DebugSnapshot.isActive, let test = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !test.isEmpty { return test }
        return SecretStore.readKey(.elevenLabs)
    }

    /// A client for ElevenLabs, or nil when no key has been added.
    func voiceClient() -> ElevenLabsClient? {
        voiceKey().map { ElevenLabsClient(apiKey: $0) }
    }

    func saveVoiceKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, SecretStore.saveKey(trimmed, for: .elevenLabs) else { return false }
        hasVoiceKey = true
        voices = []
        Task { await loadVoices() }
        return true
    }

    func removeVoiceKey() {
        SecretStore.deleteKey(.elevenLabs)
        hasVoiceKey = false
        voices = []
        voicesError = nil
    }

    /// Asks ElevenLabs for the account's voices. Free; nothing is spoken.
    func loadVoices() async {
        guard let client = voiceClient(), !loadingVoices else { return }
        loadingVoices = true
        voicesError = nil
        do {
            voices = try await client.voices()
        } catch is CancellationError {
            // Stopped.
        } catch {
            voicesError = error.localizedDescription
        }
        loadingVoices = false
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
