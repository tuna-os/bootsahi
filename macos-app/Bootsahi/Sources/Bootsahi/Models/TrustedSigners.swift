import Foundation

/// The cosign signers this app will name in install-config.json, compiled into
/// the binary on purpose (issue #193).
///
/// The catalog is data the app reads and the agent later trusts, so a signer it
/// names proves nothing on its own: anyone can sign their own image with their
/// own workflow, and a keyless signature costs nothing. The policy therefore
/// lives in code, not in a file shipped beside the catalog. The bootstrap
/// agent applies the same list from `components/bootsahi-agent/trusted-signers.json`,
/// which ships inside the bootstrap image; `TrustedSignersTests` fails when the
/// two differ, so the app can never offer an image the agent will refuse.
enum TrustedSigners {
    struct Signer: Hashable, Decodable {
        var cosignIdentity: String
        var cosignIssuer: String
    }

    static let all: [Signer] = [
        Signer(
            cosignIdentity: "https://github.com/tuna-os/.github/.github/workflows/image-build.yml@refs/heads/main",
            cosignIssuer: "https://token.actions.githubusercontent.com"),
    ]

    /// Exact match on the (identity, issuer) pair. An identity alone is not
    /// trust: the same identity string from another OIDC provider is a
    /// different signer.
    static func contains(identity: String, issuer: String) -> Bool {
        all.contains(Signer(cosignIdentity: identity, cosignIssuer: issuer))
    }
}

extension CatalogEntry {
    /// Whether this entry's signer is one the app (and the bootstrap) trusts.
    var signerIsTrusted: Bool {
        TrustedSigners.contains(identity: cosignIdentity, issuer: cosignIssuer)
    }

    /// The app offers an entry only when it is harness-verified (#41) AND
    /// signed by a compiled-in signer (#193).
    var isOfferable: Bool { verified && signerIsTrusted }
}
