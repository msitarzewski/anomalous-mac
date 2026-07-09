import Testing
import Foundation
@testable import AnomalousCore

// Regression coverage for the "zed → 'a preview tool'" bug: a channel-variant
// bundle id (dev.zed.Zed-Preview) must (1) normalize to the base app's identity,
// (2) reuse the base app's corpus record instead of dropping to a model guess,
// and (3) when a guess IS unavoidable, hand the model the CANONICAL id with an
// explicit "don't read meaning out of the string" instruction.

private func identity(name: String, bundle: String? = nil, version: String? = nil) -> ProcessIdentity {
    ProcessIdentity(pid: 1, startAbsTime: 1, executableName: name, bundleID: bundle, appVersion: version)
}

private func leakAnomaly(identity: ProcessIdentity) -> Anomaly {
    Anomaly(
        kind: .memoryLeakFootprint, identity: identity, windowSeconds: 1800,
        magnitudeCurve: [900, 3514], baselineValue: 900, detectedAt: .now,
        drivingMetric: BaselineMetric.memoryMB.rawValue
    )
}

private func zedEntry() -> KnowledgeEntry {
    KnowledgeEntry(
        processName: "zed", displayName: "Zed Code Editor",
        whatItIs: "Zed is a high-performance code editor.", ownedBy: "Zed Industries, Inc.",
        whenHotImplies: "You have Zed open and are editing or running AI agents.",
        safetyTier: 1, safeAction: "Quit via Cmd+Q.", worstCase: "Unsaved edits lost.",
        causallyLinked: []
    )
}

@Suite("release-channel identity normalization")
struct ReleaseChannelTests {
    @Test("dash-attached channel suffix strips to the base app")
    func dashSuffix() {
        let id = identity(name: "zed", bundle: "dev.zed.Zed-Preview")
        #expect(id.releaseChannel == "Preview")
        #expect(id.canonicalBundleID == "dev.zed.Zed")
        #expect(id.canonicalBundleLeaf == "Zed")
    }

    @Test("channel as its own trailing segment strips too")
    func dotSegmentChannel() {
        let id = identity(name: "Brave Browser", bundle: "com.brave.Browser.beta")
        #expect(id.releaseChannel == "Beta")
        #expect(id.canonicalBundleID == "com.brave.Browser")
    }

    @Test("release build is unchanged")
    func releaseBuild() {
        let id = identity(name: "zed", bundle: "dev.zed.Zed")
        #expect(id.releaseChannel == nil)
        #expect(id.canonicalBundleID == "dev.zed.Zed")
    }

    @Test("a component role segment is NOT a channel (left for the prompt to handle)")
    func helperIsNotAChannel() {
        let id = identity(name: "Google Chrome Helper", bundle: "com.google.Chrome.helper")
        #expect(id.releaseChannel == nil)
        #expect(id.canonicalBundleID == "com.google.Chrome.helper")
    }

    @Test("bare executable has no bundle identity")
    func bareExecutable() {
        let id = identity(name: "dasd")
        #expect(id.canonicalBundleID == nil)
        #expect(id.releaseChannel == nil)
    }
}

@Suite("channel-variant corpus reuse")
struct ChannelCorpusReuseTests {
    @Test("Preview channel reuses the base app's record even when the observed name diverges")
    func previewReusesBaseRecord() {
        let map = KnowledgeMap(entries: [zedEntry()])
        // Observed executable name "Zed" (capitalized), bundle is the Preview channel.
        let resolved = map.entry(for: identity(name: "Zed", bundle: "dev.zed.Zed-Preview"))
        #expect(resolved?.processName == "zed")
    }

    @Test("exact name still wins")
    func exactWins() {
        let map = KnowledgeMap(entries: [zedEntry()])
        #expect(map.entry(for: identity(name: "zed", bundle: "dev.zed.Zed"))?.processName == "zed")
    }

    @Test("genuinely unknown app stays unknown")
    func unknownStaysUnknown() {
        let map = KnowledgeMap(entries: [zedEntry()])
        #expect(map.entry(for: identity(name: "mysteryd", bundle: "com.acme.Mystery")) == nil)
    }

    @Test("the reused record means the app does NOT treat it as genuinely unknown")
    func notGenuinelyUnknownWhenReused() {
        let map = KnowledgeMap(entries: [zedEntry()])
        let anomaly = leakAnomaly(identity: identity(name: "Zed", bundle: "dev.zed.Zed-Preview"))
        let engine = JudgmentEngine(knowledgeMap: map)
        #expect(engine.groundingEntry(for: anomaly, context: nil)?.processName == "zed")
    }
}

@Suite("bundle-anchored prompt no longer invites token invention")
struct BundleAnchorPromptTests {
    @Test("channel-suffixed, uncurated app: canonical id + channel note, no token-guessing")
    func hardenedPrompt() {
        let anomaly = leakAnomaly(identity: identity(name: "SomePreviewApp", bundle: "com.acme.Widget-Preview", version: "2.0"))
        let text = JudgmentEngine.instructions(anomaly: anomaly, entry: nil, baselineSentence: "Now 3514 MB.")
        // Canonical id anchors the model; the raw suffixed form never appears as bait.
        #expect(text.contains("com.acme.Widget"))
        #expect(!text.contains("Widget-Preview"))
        // The model is told this is a release channel of the same app...
        #expect(text.contains("Preview release channel"))
        // ...and explicitly forbidden from reading meaning out of the id string.
        #expect(text.contains("NEVER infer"))
        // The old invitation to guess from the bundle id is gone.
        #expect(!text.contains("most likely does"))
    }
}
