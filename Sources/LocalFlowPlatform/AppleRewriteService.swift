import Foundation
import FoundationModels
import LocalFlowCore

public actor AppleRewriteService: Rewriting {
    private let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    private var session: LanguageModelSession?

    public init() {}

    nonisolated public func prewarm() { Task { await warm() } }
    private func warm() {
        guard model.availability == .available else { return }
        let session = LanguageModelSession(model: model, instructions: RewritePolicy.instructions)
        session.prewarm(promptPrefix: Prompt("Rewrite this dictation"))
        self.session = session
    }

    public func rewrite(_ text: String, deadline: Duration) async -> String {
        guard model.availability == .available, let session else { return text }
        if let candidate = await DeadlineRace.first(deadline: deadline, operation: { [session] in
            let response = try await session.respond(to: RewritePolicy.prompt(for: text))
            return response.content
        }) {
            return RewritePolicy.accepts(candidate: candidate, original: text)
                ? candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                : text
        }
        return text
    }
}
