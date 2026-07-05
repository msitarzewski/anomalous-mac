import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple Intelligence's on-device model (Foundation Models) is usable
/// for the judgment layer. When it isn't, diagnosis cards fall back to the
/// built-in knowledge map — still useful, just not model-composed. The UI
/// surfaces this so a user understands why cards look generic and how to get
/// the richer ones. We always say "Apple Intelligence" — the name people know.
enum AppleIntelligence {
    enum Status: Equatable {
        case available
        /// Not usable, with a plain-language, actionable reason.
        case unavailable(reason: String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(reason: describe(reason))
            }
        }
        #endif
        return .unavailable(reason: "This Mac doesn't support Apple Intelligence.")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac isn't eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence isn't turned on. Enable it in System Settings › Apple Intelligence & Siri."
        case .modelNotReady:
            return "Apple Intelligence is still downloading its model — try again shortly."
        @unknown default:
            return "Apple Intelligence is currently unavailable."
        }
    }
    #endif
}
