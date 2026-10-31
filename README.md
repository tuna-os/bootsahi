# Bootsahi

Bootsahi is the Apple Silicon (Asahi Linux) installer path for TunaOS-family
bootc images — and anyone else's (Dakota, Bluefin, Bazzite). It is a
macOS-driven install flow for M1/M2 Macs. The repository is
`tuna-os/bootc-installer-asahi`.

<p align="center">
  <img src="docs/screenshots/walkthrough.gif"
       alt="The Bootsahi installer, screen by screen: welcome, choosing an image, account settings, the disk-space split, installation progress, and the recoveryOS hand-off."
       width="700">
</p>

<p align="center">
  <em>Every frame is rendered in CI from the real SwiftUI views — see the
  <a href="docs/gui-walkthrough.md">step-by-step walkthrough</a>.</em>
</p>

**Architecture** (see [docs/DESIGN.md](docs/DESIGN.md)): instead of one
installer payload per variant×desktop, we ship **one minimal bootstrap
payload** whose first boot runs [fisherman](https://github.com/projectbluefin/fisherman)
to `bootc install` the image ref the user picked in the macOS app. The catalog
is just registry refs (`bonito:gnome-asahi`, …), so a new variant needs no
installer change — but a ref **must** pass the Asahi golden-manifest harness
before it is offered, and "appears without touching the installer" must never
be read as "appears without being verified."

As of 2026-07-30 only `bonito` and `grouper` pass (36/36 each); the other six
promoted `*-asahi` tags would leave a Mac unbootable
([tunaOS#776](https://github.com/tuna-os/tunaOS/issues/776)). The catalog
is an explicit allowlist: every `CatalogEntry` carries a `verified` field
(`false` by default), and the macOS app only offers entries where it is
`true`. The shipped `catalog.json` includes both `bonito` and `grouper`,
marked `verified: true`. Adding a new variant requires both the image and a
passing harness sweep — the field is the gate. That gate is currently
hand-maintained rather than CI-generated from harness results
([#70](https://github.com/tuna-os/bootc-installer-asahi/issues/70)); the
harness sweep itself ([#41](https://github.com/tuna-os/bootc-installer-asahi/issues/41))
that produced the two verified entries above is closed.

<!-- hive-contribute-plea: donated-compute appeal, keep in sync across repos -->
## Contribute compute — no code needed

**[Donate time with your AI CLI](https://hub.tunaos.org/#contribute).**

Your machine runs one task at a time using your signed-in AI coding CLI.
The relay alternates between eligible **School** (OS) and **Reef** (apps)
hives after each task. If one hive has no work, the other can continue.

The guide covers prerequisites, verified `just` setup, credentials, provider
costs, and how to stop with Ctrl+C. Your subscription quota or API charges apply.
Never post account credentials or API keys in issues or pull requests.

## Status

- [x] Design (docs/DESIGN.md)
- [x] D0 scaffold: `scripts/make-payload.sh` + `build-payload.yml` — package
      any asahi-capable bootc image as an asahi-installer zip +
      `installer_data.json` (wired with R2 upload step for `download.tunaos.org/asahi`)
- [x] D0 validated against a real asahi image (`bonito:gnome-asahi`, tunaOS#774)
- [x] D1 first-boot fisherman agent config (`install-config.json` → unattended `bootc install`)
- [x] D2 asahi-installer `--json` machine mode (upstreamable)
- [x] D3 macOS app (SwiftUI; implementation is complete, and CI build and tests pass). Alpha still needs end-to-end tests on real Apple Silicon and signed and notarized distribution.
- [ ] D4 recoveryOS: LUKS fails closed. Remaining work: illustrations, QR, Wi-Fi SSID prefill, real disk-slider bytes, hardware verification, and a signed and notarized release artifact.

## Development & testing

Contributor workflow, code style, branch conventions and the full local test
matrix live in [CONTRIBUTING.md](CONTRIBUTING.md). The short version:

```sh
shellcheck -S warning scripts/*.sh components/*/*.sh   # lint, as CI runs it
sudo ./scripts/selftest.sh                             # payload + installer_data.json contract
./scripts/test-backend-contract.sh                     # pinned asahi-installer --json contract
./components/bootsahi-agent/test-agent.sh              # install-config.json -> recipe.json

cd macos-app/Bootsahi && swift build -v && swift test -v
```

### What's tested and what it proves

The project distinguishes two claims that are easy to conflate (see #27):

| Claim | Test | What it proves |
|---|---|---|
| **"A payload boots"** | `test-payload.sh` + `test-boot-payload.sh` | The kernel, DTBs, modules, and U-Boot EFI chain work. Any asahi-capable image passes this — it proves the *packaging*, not the *product*. |
| **"The bootstrap handoff is green"** | `test-agent.sh` + `test-agent-disk.sh` + `test-agent-install.sh` | The agent generates a valid recipe, the recipe passes real fisherman `validate`, and a real `bootc install` succeeds end-to-end (canaries on ESP / neighbour / bootstrap / target). |
| **"The bootstrap image contains everything it needs"** | `test-bootstrap-contents.sh` | Static verification: bootsahi-agent, enabled unit, fisherman, cosign, jq, nmcli, blkid — all present and accounted for. Also gates a negative fixture (agent removed → must fail). |
| **"The actual bootstrap image boots"** | `test-bootstrap-boot.sh` (opt-in) | Build, package, and boot the repo's own bootstrap under qemu+U-Boot. The deepest fidelity achievable without Apple hardware. Needs aarch64 + qemu + u-boot-qemu. |

Payload layout & `installer_data.json` schema modeled on
fedora-asahi kiwi-descriptions and
[nixos-asahi-package](https://github.com/quinneden/nixos-asahi-package).
M1/M2 only — M3+ has no Asahi installer support yet.
