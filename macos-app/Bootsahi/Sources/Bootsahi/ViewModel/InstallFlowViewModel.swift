import Foundation
import Combine

/// Drives the wizard flow from DESIGN.md: welcome -> catalog -> disk-space
/// slider -> options (user/Wi-Fi/LUKS) -> run backend with progress ->
/// guided recoveryOS walkthrough.
///
/// Catalog/options selection happens entirely in this app, before the
/// backend process is even started — the forked asahi-installer only ever
/// installs the single "bootsahi-boot" bootstrap OS (per DESIGN.md's core
/// idea: one bootstrap payload per architecture, not per variant), so it
/// has no reason to know about variant/desktop/stream at all. Those choices
/// only matter for install-config.json. The backend owns partition facts; the
/// Linux agent resolves them from PARTUUIDs recorded in stub_info.json, so the
/// app deliberately emits no macOS device-node guesses.
@MainActor
final class InstallFlowViewModel: ObservableObject {
    enum Step: Equatable {
        case welcome
        case catalog
        case options
        case diskSlider
        case installing
        case recoveryWalkthrough
        case done
        case failed(String)
    }

    @Published private(set) var step: Step = .welcome
    @Published private(set) var log: [BackendMessage] = []
    @Published private(set) var pendingAsk: BackendAsk?
    /// The backend's terminal result, if it sent one. nil after a run means the
    /// backend died without reporting — which must be read as failure, never as
    /// success. See json-mode.md's terminal-result section.
    @Published private(set) var backendResult: BackendResult?
    @Published var catalog: Catalog?
    @Published var selectedEntry: CatalogEntry?
    @Published var config = InstallConfig(
        targetImgref: "", rootPartition: nil, espPartition: nil,
        filesystem: "btrfs", hostname: "")

    private var process: InstallerProcess?
    private var e2eTimer: Timer?
    private var logWriter: InstallLogWriter?

    /// Starts polling for drive-mode directives (issue #6 §2). No-op
    /// unless BOOTSAHI_E2E_DRIVE=1 — see E2EDrive's doc comment. Call once,
    /// e.g. from the app's init.
    func startE2EDriveIfEnabled() {
        guard E2EDrive.isEnabled else { return }
        reportE2EState()
        e2eTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pollE2EDirective() }
        }
    }

    private func pollE2EDirective() {
        guard let directive = E2EDrive.nextDirective() else { return }
        // apply() reports; a second call here would just rewrite the same file.
        apply(directive)
    }

    /// Applies one directive to the live view model — the same mutations a
    /// click performs, which is the whole point of the seam (see E2EDrive's
    /// doc comment on why this drives the real ViewModel rather than a UI
    /// automation framework).
    ///
    /// Split out of `pollE2EDirective` and left internal rather than private
    /// so tests can drive it without a BOOTSAHI_E2E_DRIVE=1 run and the /tmp
    /// file dance — the same reasoning that made `terminalStep` a pure static.
    /// Previously the only coverage was of the decoder, so nothing checked
    /// that a decoded directive did anything.
    func apply(_ directive: E2EDrive.Directive) {
        switch directive {
        case .selectCatalogEntry(let imgref):
            // Same filter as CatalogView: drive mode must not reach an entry
            // a user could not click.
            selectedEntry = catalog?.entries.first { $0.imgref == imgref && $0.isOfferable }
        case .setHostname(let value):
            config.hostname = value
        case .setUser(let username, let fullname, let password):
            applyUser(username: username, fullname: fullname, password: password)
        case .setWifi(let ssid):
            // Empty SSID clears it, matching OptionsView's `if !wifiSSID.isEmpty`
            // guard — otherwise a harness could not test the no-Wi-Fi config.
            config.wifi = ssid.isEmpty ? nil : .init(ssid: ssid)
        case .setEncryption(let type):
            config.encryption = .init(type: type)
        case .setFilesystem(let value):
            config.filesystem = value
        case .startBackend:
            startBundledBackend()
        case .advance:
            switch step {
            case .welcome: advanceToCatalog()
            case .catalog: advanceToOptions()
            case .options: advanceToDiskSlider()
            case .recoveryWalkthrough: confirmRecoveryOSComplete()
            default: break
            }
        case .answerAsk(let value):
            answer(value)
        }
        reportE2EState()
    }

    /// Applies a user exactly the way OptionsView's Continue button does:
    /// hash first, and let only the hash reach `config`.
    ///
    /// The drive seam deliberately takes the password as typed rather than a
    /// pre-hashed value. Accepting a hash would let the harness pass a config
    /// the real UI could never produce, so the one property most worth
    /// covering — that plaintext never reaches the model, #21 — would be
    /// asserted about a code path no user crosses. `ConfigContractTests`
    /// already refuses a config whose password is not `$6$`-shaped, so a
    /// regression here fails the suite rather than reaching a disk.
    private func applyUser(username: String, fullname: String?, password: String) {
        config.user = InstallConfig.UserSpec(
            username: username,
            fullname: fullname,
            password: PasswordHash.hash(password),
            groups: config.user?.groups ?? ["wheel"])
    }

    private func reportE2EState() {
        var state: [String: Any] = ["step": "\(step)"]
        if let entry = selectedEntry { state["selectedEntry"] = entry.imgref }
        state["hostname"] = config.hostname
        state["pendingAskKind"] = pendingAsk?.kind.rawValue ?? NSNull()
        state["logCount"] = log.count
        // Enough of the config for a harness to assert the handoff actually
        // carries what the wizard collected — the audit's complaint was that
        // drive mode could not observe user/Wi-Fi/LUKS at all.
        state["username"] = config.user?.username ?? NSNull()
        // The SHAPE of the stored password, never the value. A harness needs to
        // prove hashing happened; writing the hash itself into a world-readable
        // /tmp file would be a new place for a credential to rest, which is the
        // same objection #21 makes about the ESP.
        state["passwordIsHashed"] = (config.user?.password ?? "").hasPrefix("$6$")
        state["wifiSsid"] = config.wifi?.ssid ?? NSNull()
        state["encryptionType"] = config.encryption?.type ?? NSNull()
        state["filesystem"] = config.filesystem
        // The verified-completion half of the slice (#25): a harness must be
        // able to tell "backend said success" from "the app decided it was
        // done", which is exactly the distinction terminalStep exists to make.
        state["backendStatus"] = backendResult?.status.rawValue ?? NSNull()
        state["backendHasEfiPartUuid"] = backendResult?.efiPartUuid != nil
        E2EDrive.report(state)
    }

    func loadCatalog(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        catalog = try? JSONDecoder().decode(Catalog.self, from: data)
    }

    func advanceToCatalog() {
        guard step == .welcome else { return }
        step = .catalog
    }

    func advanceToOptions() {
        // CatalogView already hides entries that are not offerable; this guard
        // keeps the config writer from ever naming a signer the compiled-in
        // policy (and so the bootstrap agent) does not trust (#193).
        guard step == .catalog, let entry = selectedEntry, entry.isOfferable else { return }
        config.targetImgref = entry.imgref
        config.cosignIdentity = entry.cosignIdentity
        config.cosignIssuer = entry.cosignIssuer
        step = .options
    }

    func advanceToDiskSlider() {
        guard step == .options, !config.hostname.isEmpty else { return }
        step = .diskSlider
    }

    /// Locate the backend supplied by the app bundle in production, with an
    /// explicit environment override for local dry-runs and CI fixtures.
    func startBundledBackend() {
        let environment = ProcessInfo.processInfo.environment
        let mainPath = environment["BOOTSAHI_BACKEND_MAIN"]
            ?? Bundle.main.url(forResource: "asahi-installer/src/main", withExtension: "py")?.path
        guard let mainPath else {
            step = .failed("The asahi-installer backend is not bundled. Set BOOTSAHI_BACKEND_MAIN for a development run.")
            return
        }
        let mainURL = URL(fileURLWithPath: mainPath)
        let pythonPath = environment["BOOTSAHI_PYTHON_PATH"] ?? "/usr/bin/python3"
        startBackend(pythonPath: pythonPath, mainPyPath: mainPath,
                     workingDirectory: mainURL.deletingLastPathComponent())
    }

    /// The production entry point from the options screen. The backend owns
    /// disk partitioning; this app owns only the install intent and starts the
    /// exact process session used by the real GUI flow.
    func startBackend(pythonPath: String, mainPyPath: String, workingDirectory: URL) {
        let proc = InstallerProcess(pythonPath: pythonPath, mainPyPath: mainPyPath,
                                     workingDirectory: workingDirectory)
        logWriter = InstallLogWriter.makeDefault()
        proc.onEvent = { [weak self] event in self?.handle(event) }
        proc.onLog = { [weak self] text in
            let msg = BackendMessage(level: .plain, text: "[unparsed] \(text)")
            self?.log.append(msg)
            self?.logWriter?.append(level: msg.level, text: msg.text)
        }
        proc.onTerminate = { [weak self] code in
            guard let self else { return }
            self.logWriter?.appendTermination(exitCode: code)
            self.finishBackend(exitCode: code)
        }
        process = proc
        backendResult = nil
        step = .installing
        do {
            try proc.start()
        } catch {
            step = .failed("failed to launch installer backend: \(error)")
        }
    }

    /// Test/dry-run seam: callers can exercise the exact config handoff with
    /// a mounted fixture instead of invoking diskutil on a real Mac.
    func finishBackendForTesting(exitCode: Int32, writeConfig: (InstallConfig, String) throws -> Void) {
        let terminal = Self.terminalStep(exitCode: exitCode, result: backendResult)
        guard case .recoveryWalkthrough = terminal else { step = terminal; return }
        guard let uuid = backendResult?.efiPartUuid else {
            step = .failed("installer reported success without an EFI partition UUID")
            return
        }
        do {
            try writeConfig(config, uuid)
            step = .recoveryWalkthrough
        } catch {
            step = .failed("installer completed, but the install configuration could not be written: \(error)")
        }
    }

    /// Launches the forked asahi-installer in --json mode. See
    /// InstallerProcess's doc comment for the unresolved python3-location
    /// packaging question.
    private func finishBackend(exitCode: Int32) {
        let terminal = Self.terminalStep(exitCode: exitCode, result: backendResult)
        guard case .recoveryWalkthrough = terminal else { step = terminal; return }
        guard let uuid = backendResult?.efiPartUuid else {
            step = .failed("installer reported success without an EFI partition UUID")
            return
        }
        do {
            try InstallConfigWriter.write(config, efiPartUUID: uuid)
            step = .recoveryWalkthrough
        } catch {
            step = .failed("installer completed, but the install configuration could not be written: \(error)")
        }
    }

    /// Called by whichever view is currently rendering pendingAsk once the
    /// user (or an automatic default, e.g. the disk slider's initial value)
    /// has produced an answer.
    func answer(_ value: JSONValue?) {
        guard let ask = pendingAsk else { return }
        process?.send(answerId: ask.id, value: value)
        pendingAsk = nil
    }

    func confirmRecoveryOSComplete() {
        guard step == .recoveryWalkthrough else { return }
        step = .done
    }

    /// Decides the terminal step from BOTH the exit code and the backend's
    /// result event. Requiring both is the whole point, not belt-and-braces:
    ///
    /// - Exit code alone missed the original bug. The backend caught every
    ///   exception, printed advice, and fell through to exit 0, so a failed
    ///   install looked finished and this app sent the user off to bless and
    ///   reboot an incomplete system.
    /// - A success result alone would miss a crash after the backend reported
    ///   success.
    /// - `aborted` exits 0 by design (the user left the flow cleanly), so it is
    ///   indistinguishable from success by exit code.
    /// - No result at all must be failure, not "probably fine": a SIGKILLed
    ///   backend emits nothing.
    ///
    /// Advancing to `.recoveryWalkthrough` is the consequential branch — it
    /// tells the user to bless and reboot — so it is the one that must be
    /// hardest to reach.
    /// Pure so it is directly testable: `backendResult` is `private(set)`, so a
    /// test cannot drive an instance-state version of this without a back door.
    /// `nonisolated` because it is pure: it touches no MainActor state, and the
    /// enclosing class is `@MainActor`, which would otherwise isolate this static
    /// method and make it unusable from a plain XCTestCase.
    nonisolated static func terminalStep(exitCode: Int32, result: BackendResult?) -> Step {
        switch result?.status {
        case .success where exitCode == 0:
            return .recoveryWalkthrough
        case .success:
            return .failed("installer reported success but exited with status \(exitCode); "
                           + "not advancing to the recoveryOS step")
        case .failure:
            let reason = result?.reason ?? "no reason given"
            return .failed("installer failed: \(reason)")
        case .aborted:
            let reason = result?.reason ?? "installer exited without installing"
            return .failed("installation did not complete: \(reason)")
        case nil:
            return .failed("installer backend exited with status \(exitCode) "
                           + "without reporting a result; treating as failure")
        }
    }

    /// Builds a view model parked in an arbitrary step, for SwiftUI previews and
    /// for the documentation screenshot capture.
    ///
    /// It lives here rather than in an extension because `step`, `log` and
    /// `pendingAsk` are `private(set)` — that restricts the setter to this
    /// *file*, so a factory anywhere else could not populate them without
    /// widening the access control for everyone. Widening it would mean any
    /// view could push the flow into `.done` without the backend agreeing,
    /// which is the property `terminalStep` exists to defend.
    ///
    /// Deliberately not `#if DEBUG`: the screenshots are built by the same
    /// release configuration users run, so a debug-only seam would document a
    /// binary nobody ships.
    static func fixture(
        step: Step,
        catalog: Catalog? = nil,
        selectedEntry: CatalogEntry? = nil,
        config: InstallConfig? = nil,
        log: [BackendMessage] = [],
        pendingAsk: BackendAsk? = nil
    ) -> InstallFlowViewModel {
        let vm = InstallFlowViewModel()
        vm.step = step
        vm.catalog = catalog
        vm.selectedEntry = selectedEntry
        if let config { vm.config = config }
        vm.log = log
        vm.pendingAsk = pendingAsk
        return vm
    }

    private func handle(_ event: BackendEvent) {
        switch event {
        case .message(let msg):
            log.append(msg)
            logWriter?.append(level: msg.level, text: msg.text)
        case .ask(let ask):
            pendingAsk = ask
        case .result(let result):
            backendResult = result
        }
        reportE2EState()
    }
}
