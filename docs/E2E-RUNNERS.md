# E2E runner capacity: AWS and RunsOn

This page answers
[#74](https://github.com/tuna-os/bootc-installer-asahi/issues/74):
can AWS, through [RunsOn](https://runs-on.com), run the end-to-end tests for
this project? The other tuna-os repositories already use RunsOn. The tunaOS and
tacklebox repositories set their runners in `.github/runs-on.yml`. bootc-migrate selects
RunsOn with the `E2E_RUNSON_SPEC` variable.

## Short answer

RunsOn can make the Linux part of the E2E path faster. It cannot run the Mac
part, and it cannot do the hardware install that the Alpha gate in
[`ROADMAP.md`](../ROADMAP.md) needs.

| Test stage | Can RunsOn run it? | Why |
|---|---|---|
| Bootstrap image build (`build-bootstrap-image.yml`) | Yes | It is an arm64 Linux job. Graviton instances (`c7g`, `c8g`) are arm64. |
| Payload boot under U-Boot (`test-boot-payload.sh`, `test-bootstrap-boot.sh`) | Yes | It is QEMU on an arm64 host. See the KVM section. |
| Real `bootc install` to a loop disk (`install-selftest`) | Yes | It is an arm64 Linux job. It runs on `ubuntu-24.04-arm` now. |
| SwiftUI app build and tests (`bootsahi-app-build.yml`) | No | RunsOn does not supply macOS runners. |
| Install on a Mac: asahi-installer, recoveryOS step, first boot | No | No cloud service supplies this. See the Mac section. |

## The Linux stages: KVM is the real gain

The hosted `ubuntu-24.04-arm` runner has no `/dev/kvm`. Thus
`test-boot-payload.sh` and `test-bootstrap-boot.sh` boot the image with QEMU
TCG emulation. This is slow. The scripts allow 2400 seconds for one boot.
Both scripts select KVM when `/dev/kvm` is present. No script change is
necessary.

On AWS, these rules apply:

- Usual Graviton instances (`c7g`, `c8g`) do not show `/dev/kvm`. EC2 nested
  virtualization is available only on the x86 families `c8i`, `m8i` and `r8i`.
  The bootc-migrate `nested-virt` label is thus not applicable to arm64.
- Graviton bare-metal instances (for example `c7g.metal` or `c6g.metal`) show
  `/dev/kvm`. QEMU then runs the aarch64 guest with `-accel kvm -cpu host`.
- An x86 runner with KVM does not help. It must emulate aarch64 with TCG, the
  same as the hosted arm64 runner.

Thus the useful RunsOn runner for this repository is a Graviton `.metal`
instance. A bare-metal instance has many cores and costs more for each hour
than a small instance. Use it only for the opt-in jobs, not for each pull
request.

A usual Graviton runner from RunsOn is also useful, without KVM. It gives more cores,
more memory and a larger disk than the hosted runner. The hosted runner must
remove preinstalled toolchains before an image build has enough disk
space.

### The opt-in workflow

[`bootstrap-boot.yml`](../.github/workflows/bootstrap-boot.yml) runs
`test-bootstrap-boot.sh` on demand (`workflow_dispatch` only). It builds the
real bootstrap image, makes a payload from it, and boots that payload under
U-Boot. It selects the runner this way:

- When the repository variable `BOOTSTRAP_BOOT_RUNSON_SPEC` has a value, the
  job runs on RunsOn. The workflow adds the `runs-on=<run-id>` key that RunsOn uses to find the job.
  The variable contains the remaining part of the label, for example:

      family=c7g.metal/image=ubuntu24-full-arm64/volume=120gb/spot=false

- When the variable is empty, the job runs on `ubuntu-24.04-arm` with TCG.

The job writes `accel=kvm` or `accel=tcg` to the step summary. Thus each run
shows which mode it used.

Before the RunsOn path can work, a maintainer must do these steps:

1. Install the RunsOn app on `tuna-os/bootc-installer-asahi`. It
   has access to other tuna-os repositories now.
2. Make sure that the RunsOn stack can start Graviton `.metal` instances in
   its AWS region and account limits.
3. Set `BOOTSTRAP_BOOT_RUNSON_SPEC`.

This change did not do a run of the workflow. Its first run is the test of the
runner spec.

## The Mac stages: not possible on AWS

RunsOn [does not support macOS](https://runs-on.com/runners/macos/). EC2 Mac
instances have a minimum allocation of 24 hours, because of the Apple macOS
license. RunsOn starts one instance for each job and cannot share that
allocation.

A dedicated EC2 Mac (`mac2.metal` is M1, `mac2-m2.metal` is M2) is
possible without RunsOn. It can do these tasks:

- Build and test the SwiftUI app with full Xcode. This includes the XCTest
  suite, which skips on a Mac that has only the Command Line Tools.
- Run the non-destructive steps of
  [`TESTING-CHECKLIST.md`](TESTING-CHECKLIST.md) with
  `scripts/mac-hardware-smoketest.sh`.

It cannot do the install that the Alpha gate needs. The asahi-installer must
reboot into recoveryOS to set the boot policy for the new system. That step
needs a person at the Mac to hold the power button. An EC2 Mac has no console
for this step. The hosted `macos-15` and `macos-26` runners already do the app
build. Thus a dedicated EC2 Mac adds only the XCTest coverage, at the
cost of a 24-hour minimum each time it starts.

## Result

- Use RunsOn on Graviton `.metal` for the slow Linux boot tests. The opt-in
  workflow above is ready for this when a maintainer sets the variable.
- Keep the hosted macOS runners for the app build. AWS does not make this
  better at a good cost.
- The hardware install in the Alpha gate still needs a real Mac and a person.
  AWS does not remove the decision in `ROADMAP.md` between a maintainer-owned
  Mac and Apple Silicon capacity that a vendor supplies.
