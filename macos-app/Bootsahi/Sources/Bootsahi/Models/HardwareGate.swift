import Foundation

#if os(macOS)
import Darwin
#endif

/// One Mac model Bootsahi will install on, read from
/// `Resources/supported-models.json`.
struct SupportedModel: Decodable, Equatable {
    /// `hw.model`, e.g. "MacBookAir10,1". The gate matches this exactly.
    var model: String
    /// Marketing name, shown to the user.
    var name: String
    /// Board ("J313AP") and SoC ("T8103"), as in Asahi's device list.
    var product: String
    var soc: String
    /// Shown before the install can start; the user must acknowledge it.
    var caution: String
}

/// The allowlist of supported Macs.
///
/// It is data, not code, so adding a model is a reviewed edit to one JSON file.
/// It lists only the M1 and M2 models in Asahi Linux's device list
/// (`source`). Any other model, including a future one, is refused: an
/// unknown Mac fails closed.
struct SupportedModels: Decodable, Equatable {
    var source: String
    var reviewed: String
    var models: [SupportedModel]

    /// Decodes and validates a list. Returns nil for anything malformed, and
    /// the gate treats nil as "refuse every model".
    static func load(from data: Data) -> SupportedModels? {
        guard let list = try? JSONDecoder().decode(SupportedModels.self, from: data),
              !list.models.isEmpty,
              Set(list.models.map(\.model)).count == list.models.count,
              list.models.allSatisfy({ !$0.model.isEmpty && !$0.name.isEmpty
                  && !$0.caution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }
        return list
    }

    /// The list bundled with the app.
    static func bundled() -> SupportedModels? {
        guard let url = Bundle.module.url(forResource: "supported-models", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return load(from: data)
    }
}

enum HardwareGate {
    enum Status: Equatable {
        case supported(SupportedModel)
        case unsupported(model: String, reason: String)
    }

    static func classify(model: String, in list: SupportedModels?) -> Status {
        guard let list else {
            return .unsupported(model: model,
                                reason: "The list of supported Macs could not be read, so no Mac is accepted.")
        }
        if let entry = list.models.first(where: { $0.model == model }) {
            return .supported(entry)
        }
        return .unsupported(model: model,
                            reason: "This Mac is not on Bootsahi's list of supported models. "
                                + "Bootsahi installs only on the M1 and M2 Macs that Asahi Linux supports.")
    }

    /// Whether the welcome screen may continue: only on a listed model, and
    /// only after the user has acknowledged that model's caution.
    static func canContinue(_ status: Status, acknowledged: Bool) -> Bool {
        if case .supported = status { return acknowledged }
        return false
    }

    static func current(models: SupportedModels? = SupportedModels.bundled()) -> Status {
        #if os(macOS)
        var arm64 = Int32(0)
        var arm64Size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &arm64, &arm64Size, nil, 0) == 0, arm64 != 0 else {
            return .unsupported(model: "non-Apple-Silicon", reason: "Bootsahi requires an Apple Silicon Mac.")
        }
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return .unsupported(model: "unknown", reason: "The Mac model could not be identified safely.")
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { buffer in
            sysctlbyname("hw.model", buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else {
            return .unsupported(model: "unknown", reason: "The Mac model could not be identified safely.")
        }
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return classify(model: String(decoding: bytes[..<end], as: UTF8.self), in: models)
        #else
        return .unsupported(model: "non-macOS", reason: "Bootsahi can only run on an Apple Silicon Mac.")
        #endif
    }
}
