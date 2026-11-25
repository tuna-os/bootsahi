import XCTest
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import Bootsahi

/// Renders every screen of the installer to PNG, plus an animated walkthrough,
/// for `docs/gui-walkthrough.md` and the README.
///
/// **Why a test target rather than a `swift run` tool.** `Bootsahi` is an
/// executable target, and SwiftPM will not let a second non-test target import
/// one. The choices were to split the app into a library plus a thin shim — a
/// refactor touching every file, verified by no local compiler — or to use the
/// one target that is already allowed to `@testable import` it and already runs
/// in CI. The second is smaller and reuses a harness that demonstrably works.
///
/// **Why a real NSWindow rather than `ImageRenderer`.** The first version of
/// this used `ImageRenderer`, on the reasoning that offscreen rendering avoids
/// the window-server flake a screenshot job would have. That reasoning was
/// wrong in a way the output made obvious and the CI check did not:
/// `ImageRenderer` draws SwiftUI's own primitives fine — text, symbols, shapes,
/// the CoreImage QR — but it cannot draw AppKit-backed CONTROLS. Buttons came
/// out as the yellow/red "unsupported view" placeholder, and `Form`, `List`,
/// `Slider` and `TextField` did not come out at all. The settings screen
/// rendered as a title over an empty page, and the catalog screen was 57%
/// placeholder block. Every published screenshot was missing the very controls
/// a walkthrough exists to point at.
///
/// So the views are hosted in an `NSHostingView` inside a real (never ordered
/// on screen) `NSWindow`, and captured with `cacheDisplay(in:to:)`. The
/// controls are then genuine NSViews in a genuine view hierarchy and draw
/// themselves properly. It still needs no visible window, no focus and no
/// timing guesswork.
///
/// What is still absent, honestly: the title bar and the vibrancy behind
/// `.bar`, because those belong to window chrome the capture does not include.
///
/// Writes nothing unless `BOOTSAHI_CAPTURE_DIR` is set, so a normal `swift
/// test` stays a test run.
@MainActor
final class ScreenshotCaptureTests: XCTestCase {

    private struct Shot {
        let name: String
        let caption: String
        let view: AnyView
    }

    private static let size = CGSize(width: 860, height: 640)

    override func setUp() {
        super.setUp()
        // Touching NSApplication.shared is what creates the connection AppKit
        // needs before any NSWindow can be made. Without it the first window
        // construction traps rather than returning nil.
        // Not just NSApplication.shared: controls draw in their INACTIVE
        // appearance unless the app is frontmost, which makes an enabled
        // primary button look disabled in a user guide. This is best-effort —
        // a test bundle may not be permitted to activate — and the capture is
        // correct either way, so nothing asserts on it.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func testCaptureWalkthrough() throws {
        guard let dir = ProcessInfo.processInfo.environment["BOOTSAHI_CAPTURE_DIR"] else {
            throw XCTSkip("BOOTSAHI_CAPTURE_DIR not set — capture is opt-in")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var frames: [CGImage] = []
        var findings: [Finding] = []
        var entries: [[String: Any]] = []
        var state = "failed"
        var failure = "capture did not reach completion"
        // The receipt is written on EVERY exit path, so a failed or partial
        // run leaves a manifest that says "failed" instead of nothing (or a
        // stale file) for the verifier to misread. It lists only images that
        // were actually rendered and audited in this run.
        defer {
            let env = ProcessInfo.processInfo.environment
            let receipt: [String: Any] = [
                "schema": "bootsahi.capture-receipt/1",
                "harness_version": 1,
                "state": state,
                "failure": state == "complete" ? "" : failure,
                "scope": "synthetic-appkit-render",
                "capabilities": [
                    "render_fixture": "run",
                    "interaction": "not-run",
                    "backend_intent": "not-run",
                    "real_installation": "not-run",
                ],
                "identity": [
                    "source_sha": env["GITHUB_SHA"] ?? "",
                    "run_id": env["GITHUB_RUN_ID"] ?? "",
                    "run_attempt": env["GITHUB_RUN_ATTEMPT"] ?? "",
                    "binary_sha256": Self.sha256(of: URL(fileURLWithPath: CommandLine.arguments[0])) ?? "",
                    "macos": ProcessInfo.processInfo.operatingSystemVersionString,
                    "xcode": env["DEVELOPER_DIR"] ?? "",
                    "renderer": "NSHostingView+cacheDisplay",
                    "theme": NSApp.effectiveAppearance.name.rawValue,
                    "scale": NSScreen.main?.backingScaleFactor ?? 1,
                ] as [String: Any],
                "fixtures": entries,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appendingPathComponent("capture-receipt.json"))
            }
        }

        for shot in Self.shots() {
            let image = try XCTUnwrap(
                render(shot.view),
                "failed to render \(shot.name) — a nil here means AppKit could not "
                    + "produce a bitmap for the hosting view at \(Self.size)")
            let finding = Self.audit(image, name: shot.name)
            findings.append(finding)
            let png = out.appendingPathComponent("\(shot.name).png")
            try writePNG(image, to: png)
            frames.append(image)
            entries.append([
                "id": shot.name,
                "file": "\(shot.name).png",
                "sha256": Self.sha256(of: png) ?? "",
                "width": image.width,
                "height": image.height,
                // What the fixture depicts, not something that happened.
                "fixture_state": shot.caption,
                "audit": [
                    "placeholder": finding.placeholder,
                    "ink": finding.ink,
                    "action_bar": finding.actionBar,
                    "violations": Self.violations(finding),
                ] as [String: Any],
            ])
        }

        // Report every screen before asserting. Failing fast on the first one
        // hid the other five last time, which cost a whole CI round to learn
        // something the same run already knew.
        for f in findings {
            print("  \(f.name): placeholder \(pct(f.placeholder))  "
                  + "ink \(pct(f.ink))  actionBar \(pct(f.actionBar))")
        }
        for f in findings {
            let v = Self.violations(f)
            XCTAssertTrue(
                v.isEmpty,
                "\(f.name): region audit failed \(v) — placeholder \(pct(f.placeholder)), "
                    + "ink \(pct(f.ink)), action bar \(pct(f.actionBar))")
            if !v.isEmpty { failure = "\(f.name): \(v)" }
        }

        XCTAssertEqual(
            frames.count, Self.shots().count,
            "every screen must render; a missing frame would silently shorten the "
                + "walkthrough rather than fail the docs build")

        let gif = out.appendingPathComponent("walkthrough.gif")
        try writeAnimation(frames, to: gif)
        entries.append([
            "id": "walkthrough",
            "file": "walkthrough.gif",
            "sha256": Self.sha256(of: gif) ?? "",
            "width": frames.first?.width ?? 0,
            "height": frames.first?.height ?? 0,
            "fixture_state": "\(frames.count) frames of the fixtures above",
            "audit": ["violations": [String]()] as [String: Any],
        ])
        if findings.allSatisfy({ Self.violations($0).isEmpty }) {
            state = "complete"
        }
    }

    private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The screens, in the order a user meets them

    private static func shots() -> [Shot] {
        let catalog = Catalog(
            generatedAt: "2026-08-01T00:00:00Z",
            entries: [
                CatalogEntry(variant: "bonito", desktop: "GNOME", stream: "stable",
                             imgref: "ghcr.io/tuna-os/bonito:gnome-asahi",
                             description: "TunaOS with the GNOME desktop. The default, "
                                        + "and the best-tested combination.",
                             cosignIdentity: "https://github.com/tuna-os/tunaOS/.github/workflows/reusable-build-image.yml@refs/heads/main",
                             cosignIssuer: "https://token.actions.githubusercontent.com",
                             verified: true),
                CatalogEntry(variant: "dakota", desktop: "KDE Plasma", stream: "stable",
                             imgref: "ghcr.io/tuna-os/dakota:kde-asahi",
                             description: "TunaOS with KDE Plasma, for a more "
                                        + "customisable desktop.",
                             cosignIdentity: "https://github.com/tuna-os/tunaOS/.github/workflows/reusable-build-image.yml@refs/heads/main",
                             cosignIssuer: "https://token.actions.githubusercontent.com",
                             verified: true),
                CatalogEntry(variant: "bluefin", desktop: "GNOME", stream: "testing",
                             imgref: "ghcr.io/ublue-os/bluefin:asahi",
                             description: "Universal Blue's developer-focused image. "
                                        + "Tracks upstream more closely.",
                             cosignIdentity: "https://github.com/tuna-os/tunaOS/.github/workflows/reusable-build-image.yml@refs/heads/main",
                             cosignIssuer: "https://token.actions.githubusercontent.com",
                             verified: true),
            ])

        var configured = InstallConfig(
            targetImgref: "ghcr.io/tuna-os/bonito:gnome-asahi",
            rootPartition: nil, espPartition: nil,
            filesystem: "ext4", hostname: "seans-air",
            cosignIdentity: "https://github.com/tuna-os/tunaOS/.github/workflows/reusable-build-image.yml@refs/heads/main",
            cosignIssuer: "https://token.actions.githubusercontent.com")
        // A hash, not a typed password: the model only ever holds the $6$ form
        // (see InstallConfig.UserSpec), so a plaintext fixture would document a
        // state the app cannot actually be in.
        configured.user = .init(username: "sean", fullname: "Sean",
                                password: PasswordHash.hash("correct horse battery"),
                                groups: ["wheel"])

        // A believable APFS split on a 512 GB Mac: the numbers are what the
        // reader checks first, so round, plausible ones matter more here than
        // in most fixtures.
        let sizeAsk = BackendAsk(
            kind: .size,
            id: "resize",
            prompt: "How much space should Linux get?",
            defaultValue: .int(120_000_000_000),
            options: nil,
            min: 45_000_000_000,
            max: 380_000_000_000,
            total: 500_000_000_000)

        let installLog: [BackendMessage] = [
            .init(level: .info, text: "Collecting system information..."),
            .init(level: .success, text: "Apple Silicon (t8103), macOS 15.5"),
            .init(level: .progress, text: "Resizing the macOS container..."),
            .init(level: .success, text: "Created 120 GB of free space"),
            .init(level: .progress, text: "Downloading bootsahi-boot payload..."),
            .init(level: .warning, text: "Mirror slow, retrying with fallback"),
            .init(level: .progress, text: "Installing m1n1 + U-Boot to the EFI system partition"),
        ]

        return [
            Shot(name: "01-welcome",
                 caption: "What the install will do, before anything is touched.",
                 view: AnyView(WelcomeView()
                    .environmentObject(InstallFlowViewModel.fixture(step: .welcome)))),

            Shot(name: "02-choose-image",
                 caption: "Pick a desktop. Every option is a bootc image.",
                 view: AnyView(CatalogView()
                    .environmentObject(InstallFlowViewModel.fixture(
                        step: .catalog,
                        catalog: catalog,
                        selectedEntry: catalog.entries[0])))),

            Shot(name: "03-settings",
                 caption: "Account, computer name and Wi-Fi network.",
                 view: AnyView(OptionsView(previewPassword: "correct horse battery")
                    .environmentObject(InstallFlowViewModel.fixture(
                        step: .options, config: configured)))),

            Shot(name: "04-disk-space",
                 caption: "Choose the split. macOS keeps the rest.",
                 view: AnyView(InstallProgressView()
                    .environmentObject(InstallFlowViewModel.fixture(
                        step: .diskSlider, config: configured, pendingAsk: sizeAsk)))),

            Shot(name: "05-installing",
                 caption: "Progress, with the full log one click away.",
                 view: AnyView(InstallProgressView()
                    .environmentObject(InstallFlowViewModel.fixture(
                        step: .installing, config: configured, log: installLog)))),

            Shot(name: "06-recoveryos",
                 caption: "The one step no software can do for you.",
                 view: AnyView(RecoveryWalkthroughView()
                    .environmentObject(InstallFlowViewModel.fixture(
                        step: .recoveryWalkthrough)))),
        ]
    }

    // MARK: - Rendering

    private func render(_ view: AnyView) -> CGImage? {
        let content = view
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        let host = NSHostingView(rootView: AnyView(content))
        host.frame = NSRect(origin: .zero, size: Self.size)

        // A real window, never ordered on screen. AppKit controls need to be in
        // a window's view hierarchy to draw — that is precisely what
        // ImageRenderer could not give them — but they do NOT need that window
        // to be visible, focused, or on any display.
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentView = host
        // Key status matters for how CONTROLS draw, not just for input focus:
        // AppKit renders a non-key window's controls in their inactive
        // appearance. The measured symptom was actionBar 0.00% on exactly the
        // three screens whose primary button is .borderedProminent, while the
        // .bordered buttons on 04/05 drew fine — consistent with the prominent
        // style falling back to a near-background inactive fill rather than
        // accent blue.
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }

    /// The region verdict, shared by the capture test and the pixel-fixture
    /// controls so both judge a frame by the same thresholds.
    static func violations(_ f: Finding) -> [String] {
        var v: [String] = []
        if f.placeholder >= 0.0025 { v.append("placeholder") }
        if f.ink <= 0.04 { v.append("blank") }
        if f.actionBar <= 0.02 { v.append("action-bar") }
        return v
    }

    struct Finding {
        let name: String
        /// Fraction that is SwiftUI's "unsupported view" marker.
        let placeholder: Double
        /// Fraction that is not the window background.
        let ink: Double
        /// Fraction of the bottom action bar that is drawn on — i.e. a button.
        let actionBar: Double
    }

    private func pct(_ v: Double) -> String { String(format: "%.2f%%", v * 100) }

    /// Measures a rendered screen. Assertions live at the call site so that all
    /// six are reported together.
    ///
    /// **Why `ink` is only a blank-page floor.** The first version of this
    /// asserted ink > 12% as a proxy for "the body rendered". It is not one.
    /// Measured on this repo's own output, the BROKEN `01-welcome` scored
    /// 10.85% and the FIXED one 11.05% — indistinguishable — while the broken
    /// `03-settings`, which rendered nothing but a header, scored 9.30%, BELOW
    /// the working `01-welcome`. Screen densities differ more than breakage
    /// does, so a single global ink threshold cannot separate them. It is kept
    /// only as a floor for a catastrophically empty page.
    ///
    /// The two checks that DO discriminate are the placeholder fraction, which
    /// is zero unless a view failed to draw, and the action bar, which is
    /// blank unless the primary button rendered. Those test the actual
    /// regression rather than a correlate of it.
    static func audit(_ image: CGImage, name: String) -> Finding {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        var placeholder = 0, ink = 0, samples = 0
        var barSamples = 0
        var barLuma: [Int] = []
        // The action bar is the bottom ~11% of the page (14pt padding either
        // side of a large control, against a 640pt page).
        let barTop = Int(Double(h) * 0.89)

        for y in stride(from: 0, to: h, by: 3) {
            for x in stride(from: 0, to: w, by: 3) {
                let i = (y * w + x) * 4
                let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                samples += 1
                if r > 230, g > 170, g < 225, b < 70 { placeholder += 1 }
                if abs(r - 236) > 12 || abs(g - 236) > 12 || abs(b - 236) > 12 { ink += 1 }
                if y >= barTop {
                    barSamples += 1
                    barLuma.append((30 * r + 59 * g + 11 * b) / 100)
                }
            }
        }

        // Contrast against the bar's OWN background, not absolute darkness.
        //
        // The darkness version measured 0.00% on three screens and I read that
        // as "the button is missing". The artifact says otherwise: the button
        // is drawn, and 24% of the strip differs from its background. macOS
        // renders a .borderedProminent button in a NON-ACTIVE app as pale grey
        // with white text — every pixel of it above luma 200. The check was
        // asserting the app was frontmost, which in a test bundle it is not.
        //
        // So: whatever colour the bar is, a control on it differs from it. An
        // empty bar is uniform and scores ~0 regardless of appearance, active
        // or inactive, light mode or dark.
        var barBackground = 0
        var histogram: [Int: Int] = [:]
        for l in barLuma { histogram[l, default: 0] += 1 }
        if let common = histogram.max(by: { $0.value < $1.value })?.key {
            barBackground = common
        }
        let barDrawn = barLuma.filter { abs($0 - barBackground) > 6 }.count

        return Finding(
            name: name,
            placeholder: Double(placeholder) / Double(max(samples, 1)),
            ink: Double(ink) / Double(max(samples, 1)),
            actionBar: Double(barDrawn) / Double(max(barSamples, 1)))
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.encodingFailed(url.lastPathComponent)
        }
        try data.write(to: url)
    }

    /// An animated GIF, assembled with ImageIO.
    ///
    /// wootc builds its timelapse with ffmpeg, which is not preinstalled on
    /// GitHub's macOS runners — `brew install ffmpeg` would add minutes to every
    /// run for one file. ImageIO ships with the OS and writes GIF natively, and
    /// GitHub renders animated GIFs inline in READMEs.
    private func writeAnimation(_ frames: [CGImage], to url: URL) throws {
        guard !frames.isEmpty else { throw CaptureError.noFrames }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw CaptureError.encodingFailed(url.lastPathComponent) }

        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        // 2.4s a frame. These are dense screens of text, not motion — a
        // walkthrough the reader cannot finish reading is decoration.
        let frameProps = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 2.4]
        ] as CFDictionary

        for frame in frames {
            CGImageDestinationAddImage(dest, frame, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.encodingFailed(url.lastPathComponent)
        }
    }

    private enum CaptureError: Error {
        case encodingFailed(String)
        case noFrames
    }
}
