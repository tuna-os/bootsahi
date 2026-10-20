# Bootsahi — design

*Draft 1, 2026-07-23. The "ultimate challenge": a good macOS-based installer for
bootc Asahi images (all TunaOS variants + Dakota + Bluefin).*

## The core idea: install a bootstrap, not an OS

Every existing asahi-installer distro (Fedora Asahi, Ubuntu Asahi, NixOS) ships
**one zip payload per OS variant** — extracted raw onto the partitions from
macOS. For a family with 10+ variants × desktops × streams, that's a
combinatorial artifact explosion, always stale relative to the registries.

Instead: **one bootstrap payload per architecture, ever.**

```
macOS app ──▶ asahi-installer backend ──▶ writes:
   • stub macOS + per-install ESP (m1n1 boot.bin, U-Boot, systemd-boot/GRUB)
   • "bootsahi" bootstrap root (~1.5 GB): 16K asahi kernel, dracut-asahi,
     NetworkManager, podman/bootc, fisherman + minimal UI
   • install-config.json (chosen image ref, user, locale, LUKS choice, Wi-Fi)
        ↓ reboot (after the one unavoidable recoveryOS blessing step)
bootstrap boots ──▶ first-boot agent reads install-config.json
   ──▶ bootc install to-filesystem / bootc switch --apply ghcr.io/tuna-os/<variant>:<tag>-arm64
   ──▶ reboots into the real OS; bootstrap root is reclaimed
```

Why this wins:
- **Catalog = an allowlist of harness-verified refs.** The macOS app lists
  variants from a small `catalog.json` (generated in CI from
  registry-map.yaml, filtered through harness results per
  tuna-os/tunaOS#910). Every entry carries a `verified` field; the app only
  offers entries where it is `true`. New variants/tags appear only after
  passing the Asahi golden-manifest harness — no unverified image is ever
  offered, because a user picking one would complete the whole recoveryOS
  blessing flow and end up with a Mac that does not boot (#41).
- **The heavy download happens in Linux**, with bootc's resumable, layered,
  signed pulls — not as a giant zip over asahi-installer's plain HTTP.
- **One artifact to maintain, test, and sign.** The bootstrap is small enough
  to boot-test in QEMU on every build (it's just an aarch64 UEFI image).
- Serves TunaOS, Dakota, Bluefin, Bazzite — anyone with a bootc aarch64 image
  ref. This is the shared piece the whole ecosystem lacks.

## Components

### 1. macOS app ("Bootsahi")
- **Wraps, never reimplements, the asahi-installer Python backend** — APFS
  live-resize, stub macOS creation, per-install ESP, machine-signed m1n1
  stage-1 install, and Apple-firmware extraction to `<ESP>/vendorfw` are
  battle-tested and Apple-fragile. Fork it only to add a `--json` machine
  interface (progress events + answers over stdio) for the GUI to drive.
- SwiftUI shell (native disk pickers, notarization, no runtime deps; the
  audience is by definition on a Mac). Tauri acceptable fallback if team
  prefers web-stack.
- Flow: welcome → catalog (variant/desktop/stream picker, rendered from
  catalog.json) → disk-space slider (APFS resize) → user + Wi-Fi + LUKS
  options (written to install-config.json) → run backend with progress →
  **guided recoveryOS walkthrough** (the one step no software can do: shut
  down, hold power, select the new OS, `bputil`-bless via the terminal
  dialog — illustrated, with a phone-scannable QR to continue instructions
  off-device while the Mac is rebooting).
- Distribution: notarized DMG + `curl | sh` fallback that runs the TUI
  backend directly (keeps CLI parity for servers/CI).

### 2. Bootstrap image ("bootsahi-boot")
- Built in CI from the leanest asahi-capable base we have — bonito-asahi
  minimal (near-term) or Dakota-asahi minimal (long-term, from-source pride).
- Contents: 16K asahi kernel + Apple DTBs, dracut-asahi (ESP firmware flow),
  NetworkManager + iwd, bootc + podman, greetd + a fisherman-driven
  first-boot UI (tuna-installer-* frontends already exist for the ISO path —
  reuse the contract in INSTALLER-FRONTENDS.md), speakersafetyd (safety even
  in bootstrap), sshd togglable for headless installs.
- First-boot agent: reads install-config.json from the ESP; if Wi-Fi creds
  present, connects; `bootc install to-filesystem` the chosen ref into the
  prepared root partition (or switch-in-place); on failure drops to the
  fisherman UI instead of a black screen. Verifies cosign signatures before
  deploying.
- The asahi-installer payload zip wraps: ESP tree (m1n1 boot.bin + U-Boot +
  bootloader) + the bootstrap root filesystem image + installer metadata.
  Produced by CI (adapt `make-asahi-installer-package.sh`), uploaded to R2
  (download.tunaos.org), referenced by our `installer_data.json`.

### 3. Boot.bin lifecycle (shared engineering, already scoped)
- The installed OS needs the update-m1n1-on-change systemd unit (the piece
  travier/Bazzite also need). Ship it in every asahi image; upstream to
  fedora-asahi-remix-atomic-desktops#2 / bootupd.

## Constraints to design around
- **M1/M2 only** until Asahi supports M3+; the app must detect the SoC
  generation from macOS (`sysctl hw.model` / IORegistry) and refuse politely
  with a link, not fail late.
- macOS ≥ 13.5 host requirement (asahi-installer backend requirement).
- No external boot, no live ISO — this flow is the *only* path onto the
  hardware; polish is not optional.
- The recoveryOS blessing step cannot be automated — invest UX effort there;
  it's where every first-time Asahi user gets lost.
- Never redistribute Apple firmware: extraction happens on-device (backend
  handles it; the bootstrap's dracut module consumes it).

## Milestones
1. **D0** — *(payload pipeline + QEMU boot-gate proven; R2 upload still
   blocked on bucket credentials being added as repo secrets)* CI job builds
   `bootsahi-boot` (bonito-asahi minimal) + payload zip + installer_data.json
   to R2; manual install with stock asahi-installer TUI pointed at our URL;
   QEMU boot-gate the bootstrap on every build.
2. **D1** — *(done, #7)* first-boot agent: install-config.json → unattended
   `bootc install` of a chosen ref; headless/ssh path proven (this is also
   how the M1 Air test loop gets provisioned). Implemented as
   [`components/bootsahi-agent`](../components/bootsahi-agent), which hands
   fisherman the asahi-installer backend's already-partitioned disk via
   `customMounts` and runs `bootc install to-filesystem` — `to-disk` remains
   debug/QEMU-only (D0's own payload harness).
3. **D2** — *(implemented, unverified on real hardware)* `--json` machine
   mode for asahi-installer. See the [D2 machine-mode contract](D2-JSON-MACHINE-MODE.md).
   Structured stdio events/answers routed through the two chokepoints every
   TTY prompt already funnels through, so the ~80 existing call sites needed
   no changes and the default TTY path is provably byte-for-byte unchanged.
   CI now checks the pinned source chokepoints and protocol document, runs the
   backend suite, and verifies the process-level terminal result. The full
   interactive flow (diskutil/bless/bputil) still needs a real Mac. **Not** opened
   as an upstream PR — awaiting James's go-ahead per the standing "no
   upstream outreach" rule.
4. **D3** — *(skeleton scaffolded; `swift build`/`swift test` CI-green on a
   GitHub macos-14 runner, not yet run on real hardware)* SwiftUI app
   ([`macos-app/Bootsahi`](../macos-app/Bootsahi)) driving the backend;
   notarized DMG; catalog.json generation in CI. `.github/workflows/
   bootsahi-app-build.yml` gives real compiler feedback without needing a
   physical Mac — dispatch manually against any branch. Still needs actual
   hardware to prove the app launches, drives a real backend subprocess, and
   partitions a real disk. Biggest open design gap, documented in the app's
   README: no defined contract yet for how install-config.json gets written
   onto the ESP after the backend finishes partitioning.
5. **D4** — polish: recoveryOS walkthrough UX, LUKS via systemd-repart
   options, Wi-Fi handoff from macOS (SystemConfiguration read of current
   SSID; never the password — user re-enters). Depends on D3's app shell;
   real UX/hardware verification still needs a Mac, though the CI build
   workflow removes that constraint for pure compile-correctness.

## Open questions for James
- Naming: "Bootsahi" is a placeholder; fisherman-adjacent naming preferred?
- Repo home: tuna-os/bootsahi (app + payload CI together, or split)?
- Does the bootstrap adopt fisherman as the first-boot agent directly, or a
  thin dedicated agent that calls bootc? (fisherman reuse keeps one installer
  brain across ISO and Asahi paths — my recommendation.)

## Adopted RFC #6 Host-Driven Install Patterns

See [issue #6](https://github.com/tuna-os/bootc-installer-asahi/issues/6) and [`UNIFIED-INSTALL-CONTRACT.md`](UNIFIED-INSTALL-CONTRACT.md) for full technical rationale.

1. **Unified Install Contract (`install-config.json`):**
   - Single JSON contract shared between macOS host app and first-boot agent.
   - Hashed account passwords ($6$ crypt format) supported via `chpasswd -e`.
   - Wi-Fi credentials and LUKS passphrases are never stored in plaintext on the ESP.
   - Partition device paths are resolved at runtime via PARTUUID/role (per ADR 0001) rather than hardcoded by the host app.

2. **Drive-Mode E2E Testing (`TUNADIVE_E2E_DRIVE=1`):**
   - Framework-agnostic UI automation seam for the SwiftUI app without accessibility bus dependencies.
   - Directive polling (`/tmp/tuna-dive-e2e-drive.json`) and state snapshot reporting (`/tmp/tuna-dive-e2e-drive-state.json`).

3. **macOS User Data Bridge (Architecture Direction):**
   - Reverses wootc's Linux-driven bind mount pattern due to Apple Silicon hardware encryption and lack of APFS driver in Linux.
   - Extraction occurs natively on the macOS host app before rebooting.
   - Reuses wootc's catalog, consent-tiering (`migration-selection.json`), and non-secret identity extraction (`wootc-identity`).

4. **Evidence & Quality Discipline:**
   - Green-only evidence requirement for published walkthroughs and screenshots.
   - CI-enforced regression tests across payload, agent, and backend contracts.
