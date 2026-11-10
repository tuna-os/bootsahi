# AGENTS.md — agent guide for tuna-os/bootc-installer-asahi

The **Apple Silicon install path** for TunaOS-family bootc images: a macOS
SwiftUI app (Bootsahi) plus a minimal bootstrap payload whose first boot runs
[fisherman](https://github.com/tuna-os/fisherman) to `bootc install`
the image the user picked.

[`CONTRIBUTING.md`](CONTRIBUTING.md) already has the full local test matrix,
code style and branch conventions, and [`docs/DESIGN.md`](docs/DESIGN.md) the
architecture — **read those first**. This file covers the few things that will
cost you a Mac or a wasted week.

## The `verified` field is a safety gate, not metadata

The catalog is just registry refs, so "a new variant needs no installer
change". That must never be read as "a new variant needs no verification".
Every `CatalogEntry` carries `verified` (default `false`) and the app offers
only `true` entries. As of 2026-07-30 only `bonito` and `grouper` pass the
Asahi golden-manifest harness (36/36 each); the other six promoted `*-asahi`
tags **would leave a Mac unbootable**
([tunaOS#776](https://github.com/tuna-os/tunaOS/issues/776)).

Never set `verified: true` from tag enumeration, a green build, or the fact
that an image exists. It requires a passing harness sweep — see
[#41](https://github.com/tuna-os/bootc-installer-asahi/issues/41).

## Producer-side green is not proof

Everything in `selftest.yml` except `install-selftest` checks *what recipe we
generate* and that fisherman can parse it. None of it observes what fisherman
**does** to a disk, which is where the failures that cost a user their Mac
live ([#26](https://github.com/tuna-os/bootc-installer-asahi/issues/26)).

The repo learned this concretely: the `vfat` defect survived every
producer-side assertion because those assertions were *our opinion of what
fisherman accepts*, never shown to the real consumer. That is why the disk
selftest builds the actual pinned fisherman and runs its own `validate`, and
why `install-selftest` runs a real `bootc install` on `ubuntu-24.04-arm` —
arm64 on purpose, since running it on x86 would test a different image than
the one that ships.

Two claims stay separate (see
[#27](https://github.com/tuna-os/bootc-installer-asahi/issues/27)):
**"a payload boots"** — any asahi-capable image passes, it proves the
packaging — versus **"the product installs"**, which needs the bootstrap
containing `bootsahi-agent`. A stock desktop image boots and cannot install.

## The fisherman pin is duplicated three times

The same SHA appears in `scripts/build-bootstrap-image.sh` (`FISHERMAN_REV`)
and twice in `selftest.yml`, each marked "Keep in sync" — with nothing
enforcing it. Change one and the disk selftest can validate against a
different fisherman than the bootstrap ships.

All three pin `205e07d`, the squash merge of
[fisherman#70](https://github.com/tuna-os/fisherman/pull/70) on `dev`.
Pin only a commit on `dev`. Do not pin a PR branch head: a squash merge
leaves that head off `dev`. When someone deletes the branch, a fresh
`git clone` + `git checkout <sha>` fails in both workflows and in the
bootstrap build (#106).

Re-pinning is a maintainer decision, not a mechanical bump: it changes what
gets written to a user's disk on hardware CI cannot fully exercise.

## macOS CI is deliberately sparing

`bootsahi-app-build.yml` runs on `macos-14` (plus `macos-26` for the Swift
6.2+ Liquid Glass path) only on pushes to `main` and PRs touching
`macos-app/**`. The PR trigger was added because push-to-main-only meant a
Swift change was compile-checked *after* it landed — the first sign of a break
was a red main. Keep the paths filter; don't widen it to every push.

Locally, `swift test` **SKIPs on CLT-only Macs** (no XCTest), so a clean local
run is not coverage. That suite has already caught what reasoning alone did
not — the Swift 6 "reference to captured var 'self' in concurrently-executing
code" error.

## Checks

```bash
shellcheck -S warning scripts/*.sh components/*/*.sh   # exactly as CI runs it
sudo ./scripts/selftest.sh
./scripts/test-backend-contract.sh                     # needs pytest
./components/bootsahi-agent/test-agent.sh
sudo ./components/bootsahi-agent/test-agent-disk.sh    # needs root, gdisk, a built fisherman
```

`test-backend-contract.sh` pins the asahi-installer revision on purpose, for
the same reason `FISHERMAN_REV` is pinned: the macOS backend and the Linux
agent live in different repos and languages, joined only by
`stub_info.json`. Both sides' suites can stay green while the contract between
them rots — and the failure shows up on real hardware as a refusal to install,
or a resolution to the wrong partition.
