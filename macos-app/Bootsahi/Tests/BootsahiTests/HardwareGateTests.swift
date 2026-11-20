import XCTest
@testable import Bootsahi

/// The hardware gate is an allowlist read from supported-models.json: only
/// listed M1/M2 models pass, everything else (unknown, newer, malformed list)
/// is refused, and a listed model still needs its caution acknowledged.
final class HardwareGateTests: XCTestCase {

    /// The bundled list, read the way the app reads it.
    private func bundled() throws -> SupportedModels {
        try XCTUnwrap(SupportedModels.bundled(), "supported-models.json is missing or invalid")
    }

    private func isSupported(_ status: HardwareGate.Status) -> Bool {
        if case .supported = status { return true }
        return false
    }

    // ── the bundled data ──────────────────────────────────────────────────

    func testBundledListHasOnlyM1AndM2Models() throws {
        // Asahi's M1 and M2 SoCs: T8103 (M1), T6000/T6001/T6002 (M1 Pro/Max/Ultra),
        // T8112 (M2), T6020/T6021/T6022 (M2 Pro/Max/Ultra).
        let m1m2: Set<String> = ["T8103", "T6000", "T6001", "T6002", "T8112", "T6020", "T6021", "T6022"]
        for entry in try bundled().models {
            XCTAssertTrue(m1m2.contains(entry.soc), "\(entry.model) has SoC \(entry.soc), which is not M1/M2")
            XCTAssertFalse(entry.caution.isEmpty, "\(entry.model) has no caution text")
        }
    }

    func testBundledListCoversTheKnownM1AndM2Families() throws {
        let models = Set(try bundled().models.map(\.model))
        for model in ["MacBookAir10,1", "MacBookPro17,1", "Macmini9,1", "iMac21,1", "MacBookPro18,3",
                      "Mac13,2", "Mac14,2", "Mac14,15", "Mac14,3", "Mac14,9", "Mac14,14", "Mac14,8"] {
            XCTAssertTrue(models.contains(model), "\(model) should be supported")
        }
    }

    // ── classification ────────────────────────────────────────────────────

    func testListedModelsAreSupportedWithTheirCaution() throws {
        let list = try bundled()
        guard case .supported(let entry) = HardwareGate.classify(model: "Mac14,2", in: list) else {
            return XCTFail("M2 MacBook Air must be supported")
        }
        XCTAssertEqual(entry.product, "J413AP")
        XCTAssertFalse(entry.caution.isEmpty)
        XCTAssertTrue(isSupported(HardwareGate.classify(model: "MacBookPro17,1", in: list)))
    }

    func testNewerAndUnknownModelsAreRefused() throws {
        let list = try bundled()
        // M3, M4, M5, M6 and A18 Pro identifiers from Asahi's device list, a
        // future identifier, a CI virtual machine, an Intel Mac, near-misses.
        for model in ["Mac15,3", "Mac15,12", "Mac16,1", "Mac16,10", "Mac17,5", "Mac17,2", "Mac18,1",
                      "Mac19,1", "VirtualMac2,1", "MacBookPro16,1", "Mac14,2 ", "mac14,2", "Mac14,", ""] {
            XCTAssertFalse(isSupported(HardwareGate.classify(model: model, in: list)),
                           "\(model.debugDescription) must be refused")
        }
    }

    func testAnUnreadableListRefusesEveryModel() {
        XCTAssertFalse(isSupported(HardwareGate.classify(model: "Mac14,2", in: nil)))
    }

    func testMalformedListsAreRejected() {
        func list(_ json: String) -> SupportedModels? { SupportedModels.load(from: Data(json.utf8)) }
        let entry = #"{"model":"Mac14,2","name":"n","product":"J413AP","soc":"T8112","caution":"c"}"#
        XCTAssertNotNil(list(#"{"source":"s","reviewed":"r","models":[\#(entry)]}"#))
        XCTAssertNil(list(#"{"source":"s","reviewed":"r","models":[]}"#), "an empty list")
        XCTAssertNil(list(#"{"source":"s","reviewed":"r","models":[\#(entry),\#(entry)]}"#), "a duplicate model")
        XCTAssertNil(list(#"{"source":"s","reviewed":"r","models":[{"model":"Mac14,2","name":"n","product":"p","soc":"s","caution":"  "}]}"#),
                     "a blank caution")
        XCTAssertNil(list(#"{"source":"s","reviewed":"r","models":[{"model":"Mac14,2","name":"n","product":"p","soc":"s"}]}"#),
                     "a missing caution")
        XCTAssertNil(list("not json"))
    }

    // ── acknowledgement ───────────────────────────────────────────────────

    func testContinueNeedsASupportedModelAndAnAcknowledgedCaution() throws {
        let supported = HardwareGate.classify(model: "Mac14,2", in: try bundled())
        XCTAssertFalse(HardwareGate.canContinue(supported, acknowledged: false))
        XCTAssertTrue(HardwareGate.canContinue(supported, acknowledged: true))
        let refused = HardwareGate.classify(model: "Mac16,1", in: try bundled())
        XCTAssertFalse(HardwareGate.canContinue(refused, acknowledged: true),
                       "acknowledging cannot unlock an unlisted model")
    }
}
