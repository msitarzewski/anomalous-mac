import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Rung 3 — the Anomalous triage backend as a Foundation Models provider
/// (WWDC26 s339 `LanguageModel`/`LanguageModelExecutor`), so all three rungs
/// sit behind the same `LanguageModelSession` API.
///
/// CRITICAL PRODUCT RULE: this rung NEVER fires automatically. Money is
/// involved — "Get Help" remains an explicit user tap. This conformance is
/// architectural unification of the transport, not auto-routing; nothing in
/// JudgmentEngine or EscalationPolicy ever selects it.
///
/// HONEST SUBSET (documented, not faked):
/// - The backend is a structured triage service, not a general LLM: it
///   accepts one `PayloadComposer.TriagePayload` and returns one expert
///   diagnosis. The session contract here is therefore: the prompt text IS
///   the JSON-encoded TriagePayload (exactly what EscalationClient sends —
///   same bytes, same SendLog ledger), and the response text is the expert
///   result as JSON (snake_case, matching the server's own shape).
/// - `capabilities` is honestly EMPTY: the transport does no client-side
///   constrained decoding (`guidedGeneration`), executes no client tools
///   (`toolCalling` — its web-search grounding is server-side and surfaces
///   as citations in the result), and exposes no reasoning stream. Requests
///   that demand a schema or tools throw `unsupportedCapability` instead of
///   pretending.
/// - No KV cache, no incremental streaming: the server answers via
///   accept-then-poll, so the whole result arrives as one appendText event.
@available(macOS 27.0, *)
public struct AnomalousBackendModel: LanguageModel {
    /// Hashable + Sendable per the Executor protocol; carries only value
    /// state. The bearer token rides here the way the direct EscalationClient
    /// takes it — Keychain retrieval stays the app layer's job.
    public struct Configuration: Hashable, Sendable {
        public let baseURL: URL
        public let bearerToken: String
        /// Every send is still ledgered byte-for-byte (two-ledger trust
        /// mechanism) — the provider path must never dodge the SendLog.
        public let sendLogDirectory: URL

        public init(baseURL: URL, bearerToken: String, sendLogDirectory: URL) {
            self.baseURL = baseURL
            self.bearerToken = bearerToken
            self.sendLogDirectory = sendLogDirectory
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Honestly empty — see HONEST SUBSET above.
    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([])
    }

    public var executorConfiguration: Executor.Configuration {
        configuration
    }

    public struct Executor: LanguageModelExecutor {
        public typealias Model = AnomalousBackendModel
        public typealias Configuration = AnomalousBackendModel.Configuration

        private let configuration: Configuration

        public init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: AnomalousBackendModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            // Honesty gates: refuse capabilities we don't have rather than
            // silently ignoring them (the framework's own error taxonomy).
            guard request.schema == nil else {
                throw LanguageModelError.unsupportedCapability(.init(
                    capability: .guidedGeneration,
                    debugDescription: "The Anomalous backend returns a fixed expert-diagnosis shape; it cannot honor arbitrary generation schemas."
                ))
            }
            guard request.enabledToolDefinitions.isEmpty else {
                throw LanguageModelError.unsupportedCapability(.init(
                    capability: .toolCalling,
                    debugDescription: "The Anomalous backend runs no client-side tools; its grounding is server-side web search, returned as citations."
                ))
            }

            guard let promptText = Self.lastPromptText(in: request.transcript),
                  let payload = try? JSONDecoder().decode(PayloadComposer.TriagePayload.self, from: Data(promptText.utf8))
            else {
                throw LanguageModelError.unsupportedTranscriptContent(.init(
                    unsupportedContent: [],
                    debugDescription: "The prompt must be a JSON-encoded PayloadComposer.TriagePayload — the provider contract mirrors the direct /api/v1/triage transport."
                ))
            }

            let client = EscalationClient(
                baseURL: configuration.baseURL,
                bearerToken: configuration.bearerToken,
                sendLog: SendLog(directory: configuration.sendLogDirectory)
            )
            let accepted = try await client.escalate(payload)
            let result = try await client.awaitResult(id: accepted.id)

            let text = try Self.responseText(for: result)
            await channel.send(LanguageModelExecutorGenerationChannel.Response.response(
                action: .appendText(text, tokenCount: max(1, text.count / 4))
            ))
        }

        /// The newest prompt's plain-text content in the transcript.
        static func lastPromptText(in transcript: Transcript) -> String? {
            for entry in transcript.reversed() {
                guard case .prompt(let prompt) = entry else { continue }
                let text = prompt.segments.compactMap { segment -> String? in
                    if case .text(let textSegment) = segment { return textSegment.content }
                    return nil
                }.joined(separator: "\n")
                return text.isEmpty ? nil : text
            }
            return nil
        }

        /// Expert result → response text, snake_case like the server's own
        /// payload so the session consumer parses ONE shape end to end.
        static func responseText(for result: EscalationClient.ExpertResult) throws -> String {
            struct Body: Encodable {
                struct Evidence: Encodable {
                    let url: String
                    let note: String
                }
                let what_it_is: String?
                let why_its_probably_hot: String?
                let is_this_normal: String?
                let suggested_action: String?
                let action_safety_tier: Int?
                let evidence: [Evidence]
                let note: String?
            }
            let body = Body(
                what_it_is: result.whatItIs,
                why_its_probably_hot: result.whyItsProbablyHot,
                is_this_normal: result.isThisNormal,
                suggested_action: result.suggestedAction,
                action_safety_tier: result.actionSafetyTier,
                evidence: result.evidence.map { .init(url: $0.url, note: $0.note) },
                note: result.note
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(body), as: UTF8.self)
        }
    }
}

#endif
