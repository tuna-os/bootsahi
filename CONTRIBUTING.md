# Contributing to Bootsahi

This repo (`tuna-os/bootc-installer-asahi`) is the Apple Silicon (Asahi Linux)
install path for TunaOS-family bootc images: a macOS app (Bootsahi) plus a
bootstrap image whose first boot runs
[fisherman](https://github.com/projectbluefin/fisherman) to `bootc install`
the image the user picked. See [docs/DESIGN.md](docs/DESIGN.md) for
the architecture and [README.md](README.md) for current status.

<!-- hive-contribute-plea: donated-compute appeal, keep in sync across repos -->
## Contribute compute — no code needed

**[Donate time with your AI CLI](https://hub.tunaos.org/#contribute).**

Your machine runs one task at a time using your signed-in AI coding CLI.
The relay alternates between eligible **School** (OS) and **Reef** (apps)
hives after each task. If one hive has no work, the other can continue.

The guide covers prerequisites, verified `just` setup, credentials, provider
costs, and how to stop with Ctrl+C. Your subscription quota or API charges apply.
Never post account credentials or API keys in issues or pull requests.

## Building and testing

### macOS app (`macos-app/Bootsahi`, Swift/SwiftUI)

```sh
cd macos-app/Bootsahi
swift build -v
swift test -v
```

CI (`.github/workflows/bootsahi-app-build.yml`) builds and tests this on
`macos-14` (and `macos-26` for the Swift 6.2+ Liquid Glass path) on pushes to
`main` and on PRs touching `macos-app/**`.

### Shell scripts and the bootstrap/agent harness

```sh
# Lint (matches CI's selftest.yml lint job)
shellcheck -S warning scripts/*.sh components/*/*.sh

# catalog.json's `verified` field must be backed by a docs/harness-results.json
# record, not just hand-edited (#70)
./scripts/validate-catalog.sh

# Harness selftest: payload structure + installer_data.json contract
sudo ./scripts/selftest.sh

# Backend contract: pinned asahi-installer --json (needs `pip install pytest`)
./scripts/test-backend-contract.sh

# bootsahi-agent: install-config.json -> recipe.json contract
./components/bootsahi-agent/test-agent.sh

# Disk resolution + real fisherman `validate` (needs root, gdisk, a built fisherman)
sudo ./components/bootsahi-agent/test-agent-disk.sh
```

`.github/workflows/selftest.yml` runs the lint job plus these harness tests on
every PR. `test-agent-install.sh` (a real `bootc install` against a stand-in
image) and `test-bootstrap-boot.sh` (boots the bootstrap image under
qemu+U-Boot) are heavier and run as part of `build-payload.yml` /
`selftest.yml`'s `install-selftest` job rather than on every PR.

## Code style

Shell scripts are linted with `shellcheck -S warning` in CI (see above); there
is no repository-wide style tool for the Swift app yet.

## Branch and PR conventions

Branches are generally named `<category>/<short-description>`, e.g.
`fix/...`, `feat/...`, `docs/...`, `sec/...`, `test/...`, `quality/...` (see
existing branches in this repo for examples). Reference the relevant issue
number in the PR description when one exists.

## Reporting issues

Use [GitHub Issues](https://github.com/tuna-os/bootc-installer-asahi/issues)
on this repository.
