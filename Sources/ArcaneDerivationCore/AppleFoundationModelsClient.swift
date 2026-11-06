import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
public enum AppleFoundationModelsClient {
    public static func generate(prompt: String) async throws -> String {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt)
        return response.content
    }
}
#endif
