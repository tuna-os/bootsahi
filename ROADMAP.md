# Bootsahi release roadmap

This roadmap turns the existing Apple Silicon installer prototype into a
versioned product without weakening the hardware-safety gate in
[`docs/TESTING-CHECKLIST.md`](docs/TESTING-CHECKLIST.md). A green build is
necessary, but it is not evidence that repartitioning and installation are
safe on a real Mac.

## Current baseline (September 2026)

- The payload, first-boot agent, machine protocol, and recovery walkthrough
  have automated coverage.
- The SwiftUI app compiles and tests on a hosted macOS runner, but the complete
  flow has not been run on real Apple Silicon hardware.
- `bonito` and `grouper` are the only catalog entries currently recorded as
  harness-verified, and both point at GNOME. No other desktop lane is built for
  Apple Silicon in either variant.
- The catalog is a hand-maintained allowlist. `verified` records a cosign
  identity check made once, on 2026-07-30; it does not assert that the lane is
  still producing builds. As of 2026-09-02 `grouper:gnome-asahi` last built on
  2026-09-01 and `bonito:gnome-asahi` last built on 2026-08-16, while other
  `bonito` lanes continued to build through 2026-09-02.
- The repository has no version tag, GitHub Release, or downloadable notarized
  application.
- Destructive Mac testing remains on hold pending the ordered hardware checks,
  and no Apple Silicon machine or hosted equivalent is currently committed to
  the run that clears the hold.

## Alpha: one reproducible, hardware-verified install

Alpha is the next release target. It is ready only when all of these outcomes
have durable evidence linked from the release notes:

- [ ] Commit the hardware capacity the rest of this list depends on: name the
      owner of the destructive run, choose between a maintainer-owned Mac with
      a documented sacrificial disk and hosted Apple Silicon capacity, and set
      a target date. Every gate below is blocked on this one, so it is stated
      first. If neither path is reachable, record that here as the current
      release status rather than leaving Alpha open-ended.
- [ ] Run the non-destructive hardware checklist: app launch, backend JSON
      round trip, app-to-backend control, and install-config handoff.
- [ ] Complete one controlled end-to-end install on a supported M1 or M2 Mac,
      including recoveryOS blessing, first boot, and a successful boot into a
      harness-verified image.
- [ ] Confirm the installer refuses unsupported Macs and unverified catalog
      entries before making disk changes.
- [ ] Replace the hand-maintained catalog trust bit with CI-generated harness
      evidence, and have the same job establish currency alongside provenance
      under the catalog currency contract below. #70 closed when #104 added
      only an interim guard: `scripts/validate-catalog.sh` checks each
      `verified: true` entry against the hand-written
      `docs/harness-results.json`. CI generation is still to do.
- [ ] State that Alpha ships GNOME only, so single-desktop coverage is a
      recorded scope decision rather than an unexamined default.
- [ ] Publish a signed and notarized DMG, checksums, supported-host statement,
      known limitations, recovery guidance, and the exact tested image digest.
- [ ] Tag the same commit used to build the artifact and publish it as the first
      GitHub prerelease.

Until these checks pass, documentation should call the project a prototype
and should not direct users to perform a destructive install.

## Beta: repeatability beyond the first machine

Beta demonstrates that Alpha was not a one-machine success:

- [ ] Repeat the install on a second supported hardware model and from a clean
      macOS host meeting the documented minimum version.
- [ ] Exercise failure and recovery paths after partitioning without damaging
      the neighbouring macOS installation.
- [ ] Publish a compatibility matrix for tested Mac models, macOS hosts,
      catalog images, and installer versions.
- [ ] Decide the desktop coverage target. Both catalog variants build `base`,
      `cosmic`, `gnome`, `kde`, `niri`, and `xfce` lanes, but only `gnome` has
      an Apple Silicon counterpart, so Mac users have no desktop choice and the
      COSMIC, KDE, Niri, and XFCE installer frontends cannot be reached from
      Apple Silicon at all. Name the desktops Beta adds, or state that Beta
      adds none. Each added desktop needs an asahi build lane in the variant
      repository, a catalog entry, and its own hardware evidence, so treat the
      build lanes as a tracked dependency rather than an assumption.
- [ ] Add an artifact promotion policy so only a tagged, hardware-qualified
      build is presented as the recommended download.
- [ ] Establish a release owner and response path for installation failures.

## Stable: supported upgrade and recovery lifecycle

Stable requires a supportable lifecycle, not only a successful fresh install:

- [ ] Document and test upgrade compatibility for the app, bootstrap payload,
      catalog schema, and installed operating system.
- [ ] Validate recovery or safe retry after each destructive boundary in the
      install flow.
- [ ] Define the supported release lifetime and deprecation policy for Mac
      models, macOS host versions, catalog entries, and desktop lanes.
- [ ] Record release health signals: successful hardware sweeps, confirmed
      installs, installation failures by stage, and time to recovery.

## Catalog currency contract

A catalog entry is a recommendation to write a specific image to a user's disk,
so `verified` has to mean more than a signature checked once. An entry counts as
verified only while all of the following hold:

- The entry records the resolved image digest and the date of the build it came
  from, not only a floating tag. A floating tag hides a lane that has stopped
  producing, because the ref keeps resolving.
- The lane behind the entry has produced a dated build within the currency
  window. Set the window explicitly; the same job that regenerates the catalog
  enforces it.
- An entry whose lane has gone past the window is demoted out of `verified`
  rather than left in place, and catalog regeneration reports the demotion
  instead of silently republishing the frozen ref.
- Catalog regeneration fails loudly when it cannot establish either provenance
  or currency, so a stale allowlist cannot be shipped by omission.

The immediate case this rule exists for: on 2026-09-02, half the shipped catalog
was frozen. Restore `bonito:gnome-asahi` to the cadence the rest of that
variant's lanes run at, or drop it from the catalog until it is, so the
allowlist matches what is actually maintained.

## Decision log

Each release decision should link the exact CI runs, hardware checklist record,
artifact digest, catalog evidence, supported-hardware statement, and unresolved
risks. If a gate is waived, document the owner, rationale, user impact, and
expiry date in the release notes.
