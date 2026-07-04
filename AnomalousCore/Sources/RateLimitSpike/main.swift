import Foundation
import AnomalousCore

// ============================================================================
// STEP 0 — the four-question spike (seed.md build order):
//   1. Does Foundation Models answer from a non-foreground process, and at
//      what rate does `.rateLimited` appear? (realistic: few/day; abusive: burst)
//   2. What is `contextSize` on this OS build?
//   3. What is the error type's actual shape? (enum cases shift across releases)
//   4. Is Private Cloud Compute reachable from a Developer ID / unsigned dev
//      build (free tier is reportedly App Store Small Business Program-gated)?
// Run: swift run RateLimitSpike [count] [delaySeconds]
// ============================================================================

let arguments = CommandLine.arguments
let count = arguments.count > 1 ? Int(arguments[1]) ?? 5 : 5
let delaySeconds = arguments.count > 2 ? Double(arguments[2]) ?? 10 : 10

print("Anomalous RateLimitSpike — \(count) requests, \(delaySeconds)s apart")
print("Process: \(ProcessInfo.processInfo.processName) pid \(ProcessInfo.processInfo.processIdentifier)")
print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print(String(repeating: "-", count: 60))

#if canImport(FoundationModels)
import FoundationModels

if #available(macOS 26.0, *) {
    let model = SystemLanguageModel.default

    // Q2/Q3 groundwork: report whatever the availability enum actually is.
    print("availability: \(model.availability)")

    // Q2: contextSize — WWDC26-era API; probe via Mirror so the spike still
    // builds if the SDK on this machine predates it.
    let mirror = Mirror(reflecting: model)
    if let contextSize = mirror.children.first(where: { $0.label == "contextSize" })?.value {
        print("contextSize (via reflection): \(contextSize)")
    } else {
        print("contextSize: not present on this SDK (or renamed) — check release notes")
    }

    guard case .available = model.availability else {
        print("Model unavailable — spike cannot proceed. Reason above.")
        exit(1)
    }

    var successes = 0, failures = 0
    for attempt in 1...count {
        let started = Date()
        do {
            let session = LanguageModelSession(instructions: "Answer in one short sentence.")
            let response = try await session.respond(to: "What is the Duet Activity Scheduler daemon on macOS?")
            successes += 1
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            print("[\(attempt)/\(count)] OK in \(elapsed)s — \(response.content.prefix(80))…")
        } catch {
            failures += 1
            // Q3: record the REAL error shape, whatever it is.
            print("[\(attempt)/\(count)] ERROR type=\(type(of: error)) value=\(error)")
        }
        if attempt < count {
            try? await Task.sleep(for: .seconds(delaySeconds))
        }
    }

    print(String(repeating: "-", count: 60))
    print("RESULT: \(successes) ok / \(failures) failed at \(delaySeconds)s spacing")
    print("Q4 (PCC eligibility): TODO — target the PCC model variant once its API name is confirmed on this SDK.")
} else {
    print("macOS 26+ required.")
    exit(1)
}
#else
print("FoundationModels not available in this toolchain — spike requires Xcode 26+ SDK.")
exit(1)
#endif
