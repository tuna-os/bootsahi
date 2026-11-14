import XCTest
@testable import Bootsahi

/// Step-transition guards and small seams on `InstallFlowViewModel` that no
/// other test file calls directly (`advanceToCatalog`, `advanceToOptions`,
/// `confirmRecoveryOSComplete`, `answer`, `loadCatalog`,
/// `finishBackendForTesting`).
///
/// Each guard is an invariant of the wizard: an incorrect one would let the
/// flow skip the catalog, options or recoveryOS confirmation steps. Terminal
/// result handling itself is pinned by `TerminalResultTests`.
///
/// `backendResult` is `private(set)` and `fixture` does not take one, so the
/// success and missing-EFI-UUID branches of `finishBackendForTesting` cannot
/// be reached from here without widening access; only the branches reachable
/// with no backend result are covered.
@MainActor
final class InstallFlowViewModelTests: XCTestCase {

    private let identity = "https://github.com/tuna-os/.github/.github/workflows/image-build.yml@refs/heads/main"
    private let issuer = "https://token.actions.githubusercontent.com"

    private func entry(_ imgref: String = "ghcr.io/tuna-os/bonito:gnome-asahi") -> CatalogEntry {
        CatalogEntry(variant: "bonito", desktop: "gnome", stream: "stable",
                     imgref: imgref, description: "fixture",
                     cosignIdentity: identity, cosignIssuer: issuer, verified: true)
    }

    private func ask() -> BackendAsk {
        BackendAsk(kind: .size, id: "resize", prompt: "How much space?",
                   defaultValue: .int(1), options: nil, min: 1, max: 2, total: 3)
    }

    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-\(UUID().uuidString).json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // ── advanceToCatalog ──────────────────────────────────────────────────

    func testAdvanceToCatalogFromWelcome() {
        let flow = InstallFlowViewModel.fixture(step: .welcome)
        flow.advanceToCatalog()
        XCTAssertEqual(flow.step, .catalog)
    }

    func testAdvanceToCatalogIsNoOpOutsideWelcome() {
        for step: InstallFlowViewModel.Step in [.options, .diskSlider, .installing, .done] {
            let flow = InstallFlowViewModel.fixture(step: step)
            flow.advanceToCatalog()
            XCTAssertEqual(flow.step, step, "advanceToCatalog must not leave \(step)")
        }
    }

    // ── advanceToOptions ──────────────────────────────────────────────────

    func testAdvanceToOptionsWithoutASelectionIsNoOp() {
        let flow = InstallFlowViewModel.fixture(step: .catalog)
        flow.advanceToOptions()
        XCTAssertEqual(flow.step, .catalog)
        XCTAssertEqual(flow.config.targetImgref, "")
    }

    func testAdvanceToOptionsCopiesTheSelectedEntryIntoTheConfig() {
        let flow = InstallFlowViewModel.fixture(step: .catalog, selectedEntry: entry())
        flow.advanceToOptions()
        XCTAssertEqual(flow.step, .options)
        // The only place the cosign policy reaches the config; the agent
        // refuses a config without it (#24).
        XCTAssertEqual(flow.config.targetImgref, "ghcr.io/tuna-os/bonito:gnome-asahi")
        XCTAssertEqual(flow.config.cosignIdentity, identity)
        XCTAssertEqual(flow.config.cosignIssuer, issuer)
    }

    func testAdvanceToOptionsIsNoOpOutsideCatalogEvenWithASelection() {
        let flow = InstallFlowViewModel.fixture(step: .welcome, selectedEntry: entry())
        flow.advanceToOptions()
        XCTAssertEqual(flow.step, .welcome)
        XCTAssertEqual(flow.config.targetImgref, "")
        XCTAssertNil(flow.config.cosignIdentity)
    }

    // ── confirmRecoveryOSComplete ─────────────────────────────────────────

    func testConfirmRecoveryOSCompleteFinishesTheWalkthrough() {
        let flow = InstallFlowViewModel.fixture(step: .recoveryWalkthrough)
        flow.confirmRecoveryOSComplete()
        XCTAssertEqual(flow.step, .done)
    }

    func testConfirmRecoveryOSCompleteCannotReachDoneFromOtherSteps() {
        for step: InstallFlowViewModel.Step in
            [.welcome, .installing, .failed("boom")] {
            let flow = InstallFlowViewModel.fixture(step: step)
            flow.confirmRecoveryOSComplete()
            XCTAssertEqual(flow.step, step, "\(step) must not jump to .done")
        }
    }

    // ── answer ────────────────────────────────────────────────────────────

    func testAnswerWithNoPendingAskLeavesStateAlone() {
        let flow = InstallFlowViewModel.fixture(step: .installing)
        flow.answer(.int(5))
        XCTAssertNil(flow.pendingAsk)
        XCTAssertEqual(flow.step, .installing)
    }

    func testAnswerClearsThePendingAsk() {
        let flow = InstallFlowViewModel.fixture(step: .installing, pendingAsk: ask())
        XCTAssertNotNil(flow.pendingAsk)
        // No backend process is attached, so the forward is a no-op; the
        // view-model state is what is under test.
        flow.answer(.int(5))
        XCTAssertNil(flow.pendingAsk)
    }

    // ── loadCatalog ───────────────────────────────────────────────────────

    func testLoadCatalogPopulatesFromAValidFile() throws {
        let url = try tempFile("""
        {"generatedAt": "2026-08-01T00:00:00Z",
         "entries": [{"variant": "bonito", "desktop": "gnome", "stream": "stable",
                      "imgref": "ghcr.io/tuna-os/bonito:gnome-asahi",
                      "description": "d", "cosignIdentity": "\(identity)",
                      "cosignIssuer": "\(issuer)", "verified": true}]}
        """)
        let flow = InstallFlowViewModel.fixture(step: .catalog)
        flow.loadCatalog(from: url)
        XCTAssertEqual(flow.catalog?.entries.map(\.imgref),
                       ["ghcr.io/tuna-os/bonito:gnome-asahi"])
    }

    func testLoadCatalogMissingFileLeavesCatalogUntouched() {
        let existing = Catalog(generatedAt: "x", entries: [entry()])
        let flow = InstallFlowViewModel.fixture(step: .catalog, catalog: existing)
        flow.loadCatalog(from: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json"))
        XCTAssertEqual(flow.catalog?.entries.count, 1)
    }

    func testLoadCatalogMalformedJSONDoesNotCrash() throws {
        let url = try tempFile("{ not json")
        let flow = InstallFlowViewModel.fixture(step: .catalog)
        flow.loadCatalog(from: url)
        XCTAssertNil(flow.catalog)
    }

    // ── finishBackendForTesting ───────────────────────────────────────────

    /// With no backend result the app must read the exit as failure even when
    /// the exit code is 0, and must never call the config writer.
    func testFinishBackendWithoutAResultFailsAndDoesNotWriteConfig() {
        let flow = InstallFlowViewModel.fixture(step: .installing)
        var wrote = false
        flow.finishBackendForTesting(exitCode: 0) { _, _ in wrote = true }
        guard case .failed(let msg) = flow.step else {
            return XCTFail("expected .failed, got \(flow.step)")
        }
        XCTAssertTrue(msg.contains("without reporting a result"))
        XCTAssertFalse(wrote, "config must not be written for an unverified install")
    }
}
