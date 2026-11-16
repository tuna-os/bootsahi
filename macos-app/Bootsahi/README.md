# Bootsahi (macOS app) — SwiftUI frontend, partially CI-verified

D3 from [`docs/DESIGN.md`](../../docs/DESIGN.md): a SwiftUI app driving the
forked asahi-installer backend
([`tuna-os/bootc-installer-asahi@json-machine-mode`](https://github.com/tuna-os/bootc-installer-asahi/tree/json-machine-mode),
D2) over its `--json` stdio protocol
([`docs/json-mode.md`](https://github.com/tuna-os/bootc-installer-asahi/blob/json-machine-mode/docs/json-mode.md)).

**Written with no local Swift toolchain** — no macOS host in the environment
that produced it. CI builds and tests it on GitHub-hosted runners with
[`bootsahi-app-build.yml`](../../.github/workflows/bootsahi-app-build.yml).
The workflow runs on pushes to `main` and on PRs that change `macos-app/**`.
It uses `macos-15` with a pre-6.2 Swift toolchain and a macOS 13 deployment
target, and `macos-26` for the Swift 6.2+ Liquid Glass path. To run it on
`main` by hand, use
`gh workflow run bootsahi-app-build.yml -R tuna-os/bootsahi --ref main`,
or the Actions tab. The first CI run was on `macos-14` (Xcode 15.4, Swift
5.10): **`swift build` succeeded and all 8 tests in
`BackendEventDecodingTests` passed**, with zero compiler warnings. That
proves the Codable models, the protocol round-trip,
and the SwiftUI view graph all type-check and link. It does **not** prove:
the app actually launches and shows a window, `InstallerProcess` correctly
drives a real `python3 main.py --json` subprocess, or any of the recoveryOS/
disk/Wi-Fi flows behave right on real hardware — none of that is exercised
by `swift build`/`swift test` in CI.

## First things to do on the real Mac

1. `cd macos-app/Bootsahi && swift run` — confirm the app actually launches
   and the welcome screen renders (CI proves it compiles, not that it runs).
2. Point `InstallerProcess` at a real `python3` + the fork's `src/main.py`
   and confirm one real `ask`/`answer` round-trip before building out the
   rest of the flow.

## What exists

- `Models/` — `BackendEvent`/`BackendAsk`/`BackendMessage`/`JSONValue`
  mirror `docs/json-mode.md` exactly (by hand — no shared schema/codegen
  with the Python side yet). `InstallConfig` mirrors
  `components/bootsahi-agent/install-config.schema.json` in this same repo
  (also by hand, also needs to be kept in sync manually).
- `Backend/InstallerProcess.swift` — spawns `python3 main.py --json`,
  streams stdout line-by-line into decoded `BackendEvent`s, writes
  `BackendAnswer` lines back to stdin.
- `Backend/InstallConfigWriter.swift` — resolves the backend's ESP PARTUUID
  with `diskutil`, mounts it if needed, and atomically writes
  `asahi/install-config.json` after verified backend success.
- `ViewModel/InstallFlowViewModel.swift` — the wizard state machine.
- `Views/` — one view per step (welcome, catalog, options, disk-slider/
  progress, recoveryOS walkthrough).

## What's deliberately left as a TODO, not invented

- **Where `python3` comes from at runtime.** asahi-installer's own
  `install.sh` already solves this for the curl-|-sh path (provisions a
  venv); Bootsahi should probably reuse that rather than bundling a Python
  runtime. Not decided — see the comment in `InstallerProcess.swift`.
- **catalog.json generation in CI.** `Resources/catalog.json` is a single
  hand-written placeholder entry. The real thing (generated from
  registry-map.yaml, per DESIGN.md) doesn't exist yet.
- **Backend discovery for packaged distribution.** The app drives a real
  process session when `BOOTSAHI_BACKEND_MAIN` is supplied (the development
  and CI seam), or when a future bundle contains
  `asahi-installer/src/main.py`. The Python runtime and notarized DMG still
  need a release packaging decision; the app refuses clearly when neither
  backend location exists.
- **SoC-generation gate** (M1/M2 only, refuse M3+ politely) —
  `HardwareGate` checks the Apple Silicon capability and refuses known M3/M4
  model families before the first destructive action.
- **Wi-Fi SSID prefill from the current macOS network** (DESIGN.md D4,
  `SystemConfiguration`) — `OptionsView.swift` has a plain manual field.
- **Real disk-space slider bytes**, notarization, and the recoveryOS
  walkthrough's actual illustrations/QR code — all D4 polish, not attempted
  here beyond a labeled placeholder.
