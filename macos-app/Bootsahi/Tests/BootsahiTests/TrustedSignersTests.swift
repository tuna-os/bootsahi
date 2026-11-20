import XCTest
@testable import Bootsahi

/// The compiled-in signer policy (#193): the app offers only entries whose
/// cosign signer it trusts at compile time, and that list must equal the one
/// the bootstrap agent ships.
@MainActor
final class TrustedSignersTests: XCTestCase {

    private let trustedIdentity = "https://github.com/tuna-os/tunaOS/.github/workflows/reusable-build-image.yml@refs/heads/main"
    private let githubIssuer = "https://token.actions.githubusercontent.com"
    private let attackerIdentity = "https://github.com/someone-else/image/.github/workflows/build.yml@refs/heads/main"

    /// Repository root, from this file's path: Tests/BootsahiTests/<file>.
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private func entry(identity: String, issuer: String, verified: Bool = true,
                       imgref: String = "ghcr.io/tuna-os/bonito:gnome-asahi") -> CatalogEntry {
        CatalogEntry(variant: "bonito", desktop: "gnome", stream: "stable",
                     imgref: imgref, description: "fixture",
                     cosignIdentity: identity, cosignIssuer: issuer, verified: verified)
    }

    // ── the two lists cannot drift ────────────────────────────────────────

    func testCompiledSignersEqualTheListTheBootstrapShips() throws {
        struct SignerList: Decodable { var signers: [TrustedSigners.Signer] }
        let url = repoRoot.appendingPathComponent("components/bootsahi-agent/trusted-signers.json")
        let shipped = try JSONDecoder().decode(SignerList.self, from: Data(contentsOf: url)).signers
        XCTAssertFalse(TrustedSigners.all.isEmpty, "an empty policy trusts nobody")
        XCTAssertEqual(Set(TrustedSigners.all), Set(shipped),
                       "TrustedSigners.all and trusted-signers.json differ: the app would offer images the agent refuses, or the reverse")
    }

    func testEveryBundledCatalogEntryNamesATrustedSigner() throws {
        let url = repoRoot.appendingPathComponent("macos-app/Bootsahi/Sources/Bootsahi/Resources/catalog.json")
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        for e in catalog.entries {
            XCTAssertTrue(e.signerIsTrusted, "\(e.imgref) names a signer the app does not trust")
        }
    }

    // ── matching ──────────────────────────────────────────────────────────

    func testTrustIsAnExactPairMatch() {
        XCTAssertTrue(TrustedSigners.contains(identity: trustedIdentity, issuer: githubIssuer))
        XCTAssertFalse(TrustedSigners.contains(identity: attackerIdentity, issuer: githubIssuer),
                       "a validly self-signed image from another workflow must not be trusted")
        XCTAssertFalse(TrustedSigners.contains(identity: trustedIdentity, issuer: "https://issuer.example.test/other"),
                       "the same identity string from another OIDC provider is another signer")
        XCTAssertFalse(TrustedSigners.contains(identity: trustedIdentity + "x", issuer: githubIssuer))
        XCTAssertFalse(TrustedSigners.contains(identity: "", issuer: ""))
    }

    func testOfferableNeedsBothVerifiedAndTrusted() {
        XCTAssertTrue(entry(identity: trustedIdentity, issuer: githubIssuer).isOfferable)
        XCTAssertFalse(entry(identity: trustedIdentity, issuer: githubIssuer, verified: false).isOfferable)
        XCTAssertFalse(entry(identity: attackerIdentity, issuer: githubIssuer).isOfferable)
    }

    // ── the wizard refuses an untrusted signer ────────────────────────────

    func testAdvanceToOptionsRefusesAnUntrustedSigner() {
        let flow = InstallFlowViewModel.fixture(
            step: .catalog, selectedEntry: entry(identity: attackerIdentity, issuer: githubIssuer))
        flow.advanceToOptions()
        XCTAssertEqual(flow.step, .catalog)
        XCTAssertEqual(flow.config.targetImgref, "")
        XCTAssertNil(flow.config.cosignIdentity, "an untrusted signer must never reach install-config.json")
    }

    func testDriveModeCannotSelectAnUntrustedEntry() {
        let untrusted = entry(identity: attackerIdentity, issuer: githubIssuer,
                              imgref: "ghcr.io/someone-else/image:latest")
        let flow = InstallFlowViewModel.fixture(
            step: .catalog, catalog: Catalog(generatedAt: "t", entries: [untrusted]))
        flow.apply(.selectCatalogEntry(imgref: untrusted.imgref))
        XCTAssertNil(flow.selectedEntry)
    }
}
