import Foundation
import MasterfulKit

/// Clean-up via a cloud model, using a key the user supplies.
///
/// Off by default and never silently enabled. This is the only code path in the
/// app that sends anything off the machine, so it is deliberately explicit: a
/// mode the user selects, a key they paste, and a provider they name.
public struct RemoteRefiner: Refiner {

    public enum RemoteError: Error, Sendable, Equatable {
        case missingKey
        case badResponse(Int)
        case malformedPayload
    }

    private let provider: RemoteProvider
    private let profile: FormattingProfile
    private let session: URLSession

    public init(
        provider: RemoteProvider,
        profile: FormattingProfile = .formal,
        session: URLSession = .shared
    ) {
        self.provider = provider
        self.profile = profile
        self.session = session
    }

    public func refine(_ text: String, context: RefinementContext) async -> String {
        guard profile != .verbatim else { return text }
        guard let key = Keychain.get(account: provider.keychainAccount), !key.isEmpty else {
            Log.refinement.notice("Remote refinement selected but no API key stored")
            return text
        }

        do {
            let output = switch provider {
            case .anthropic: try await callAnthropic(text: text, key: key, context: context)
            case .google: try await callGoogle(text: text, key: key, context: context)
            }
            return CleanupPrompt.sanitise(output)
        } catch {
            Log.refinement.error(
                "Remote refinement failed: \(error.localizedDescription, privacy: .public)"
            )
            return text
        }
    }

    // MARK: - Anthropic

    private func callAnthropic(
        text: String, key: String, context: RefinementContext
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 8

        let body: [String: Any] = [
            "model": provider.modelIdentifier,
            "max_tokens": max(128, text.count),
            "temperature": 0,
            "system": CleanupPrompt.instructions(for: profile),
            "messages": [[
                "role": "user",
                "content": CleanupPrompt.userMessage(
                    transcript: text, vocabulary: context.vocabulary, profile: context.profile
                ),
            ]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validate(response)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first(where: { $0["type"] as? String == "text" }),
              let output = first["text"] as? String
        else { throw RemoteError.malformedPayload }
        return output
    }

    // MARK: - Google

    private func callGoogle(
        text: String, key: String, context: RefinementContext
    ) async throws -> String {
        let endpoint = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(provider.modelIdentifier):generateContent"
        )!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header rather than a query parameter: a key in a URL ends up in logs.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 8

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": CleanupPrompt.instructions(for: profile)]]
            ],
            "contents": [[
                "role": "user",
                "parts": [["text": CleanupPrompt.userMessage(
                    transcript: text, vocabulary: context.vocabulary, profile: context.profile
                )]],
            ]],
            "generationConfig": ["temperature": 0, "maxOutputTokens": max(128, text.count)],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validate(response)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let output = parts.compactMap({ $0["text"] as? String }).first
        else { throw RemoteError.malformedPayload }
        return output
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteError.badResponse(http.statusCode)
        }
    }

    /// Round-trips a key so the settings UI can tell the user it works before
    /// they discover otherwise mid-sentence.
    public static func validateKey(_ key: String, provider: RemoteProvider) async -> Bool {
        let refiner = RemoteRefiner(provider: provider)
        Keychain.set(key, account: provider.keychainAccount)
        let probe = await refiner.refine("um this is a test", context: .none)
        return probe.lowercased().contains("test")
    }
}
