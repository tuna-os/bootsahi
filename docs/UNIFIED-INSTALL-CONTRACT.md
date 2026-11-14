# Unified install contract — draft spec (responds to issue #6 §1)

Status: **first draft, not agreed**. This draft makes the proposal in issue #6
concrete enough to discuss. It does not settle it. It also corrects one
oversimplification in the RFC text (see "What wootc does" below).

## What wootc does

The RFC describes the wootc contract as a single `vault.json` with the same
shape as `install-config.json`. In the real code
(`app/vault_windows.go`, `app/installer_windows.go`), wootc splits it across
**three channels**, not one file:

1. **`vault.json`** (`0o600`, ACL-restricted to SYSTEM/Administrators) —
   only `username`, `hostname`, `image`, `password_hash`. The app hashes the
   password with `sha512_crypt` (`$6$...`) **before** it writes the file to
   disk. The plaintext never goes to disk.
2. **Kernel arguments in the boot entry** — `wootc.image=`,
   `wootc.hostname=` (a copy of the vault.json value; the deployer reads it
   before NTFS mounts), `wootc.bootloader=`,
   `wootc.luks=<encryption-type>`.
3. **The fisherman `recipe.json`**. The deployer script makes it at runtime
   from (1) and (2). The Windows app does not write it.

A limit in Windows causes this split. The deployer initramfs must read some
settings (image ref, LUKS type) from `/proc/cmdline` *before* it mounts
anything. Other settings (username, password hash) can wait until the
initramfs mounts the NTFS volume that holds `vault.json`.

## Why Asahi does not need the split

`install-config.json` is already on the ESP (per `DESIGN.md`). The bootsahi
bootstrap always mounts the ESP as one of its first actions. It needs
`<ESP>/m1n1/boot.bin`, and the bootstrap root is also on the ESP. Thus
Asahi has no "before any mount" phase like the wootc cmdline method, and a
single JSON file works.

**Recommendation: keep the Asahi contract as the single-file
`install-config.json`**, as `components/bootsahi-agent/install-config.schema.json`
specifies. This is simpler. The wootc split solves a problem that Asahi does
not have, and it is not a pattern to copy for its own sake.

## What to converge on

Do not converge on the file split. Converge on the **field shapes and
security conventions**, because the fisherman `recipe.json` is the true
contract below both installers:

| Concern | wootc | Asahi (current) | Converge? |
|---|---|---|---|
| Password | `$6$` hash, hashed client-side, `password_hash` field | plaintext `password` field | **Yes** — see below |
| Image ref | `image` | `targetImgref` | No. The Asahi name is clearer (in wootc, `image` is also the *current* value in other structs). A rename is not worth the argument |
| LUKS type | `Encryption` string (`none`/`tpm2-luks`/...) on `InstallConfig`, sent as `wootc.luks=` cmdline | `encryption.type` object | Already aligned in spirit. The Asahi object form has more detail (it holds `passphrase` with `type`). Keep it |
| Hostname | `hostname` | `hostname` | Already aligned |

**Action in this PR:** the `user.password` field in
`install-config.schema.json` now documents the `$6$` hash convention.

- The fisherman `chpasswd` step finds a value that starts with `$` and
  passes `chpasswd -e`. This was once in `projectbluefin/fisherman` only (see
  below); `tuna-os/fisherman` has it too (`internal/post/user.go`).
- fisherman also accepts a plain string. But then the password stays in the
  file in clear text until the install completes.
- The macOS app must hash the password client-side, as `vault_windows.go`
  does. It must do this before it writes `install-config.json` to the ESP.

## A real blocker that this document found

**Resolved. We keep this section as a record.**

`components/bootsahi-agent` used `github.com/tuna-os/fisherman` as its
source. wootc used `github.com/projectbluefin/fisherman`, which was 14 commits
ahead. That fork had fixes that `tuna-os/fisherman` did not have.

The two forks are now in sync (tuna-os/fisherman#59). This sync also made the
CI of tuna-os/fisherman green again, because those same bugs caused its
failures. The pin here now points at `tuna-os/fisherman`. That fork also has
the customMounts validation (#58) and TPM2 enrolment on first boot, which
projectbluefin does not have. These items were missing:

- **`MountType`** — an explicit `mount -t <fstype>` for the new root
  filesystem. The deployer initramfs has no libblkid probe. Without
  `MountType`, it can try to mount an xfs root as ext4, and then it fails.
  The initramfs of Asahi probably has the same gap. Nobody has verified
  this. An aarch64 check must confirm it (see the hardware test checklist).
- ~~**`chroot <target> useradd`** instead of **`useradd --root <target>`**~~ —
  **superseded.** The change went through these steps:
  - `5025d4d` moved to `chroot`, because `--root` pulls in the PAM and
    SELinux stack of the host.
  - `e2a6499` **reversed that for composefs-native** (dakota exit 127) and
    went back to `--root`.
  - `f94a716` and `d12b6cb` refined it more.

  Classic ostree and composefs-native need different methods, and fisherman
  finds the type at runtime. A statement such as "use chroot, not --root"
  shows only one step of this sequence, not the result. Earlier revisions of
  this document had that error.

At the time, we updated the `bootsahi-agent` README and the hardware test
checklist to point at `projectbluefin/fisherman`. That workaround is gone:
both now point at `tuna-os/fisherman`, and the owners archived
`projectbluefin/fisherman`. These failures occur only when the input is not a mock stdin.

## The handoff: how install-config.json gets to the ESP

*(We added this section after we read the fisherman and asahi-installer
source. It is step 4 of the test checklist, and it blocks each step that uses
a real disk. It also corrects the section above — see "Correction to my §1
recommendation".)*

### The question

`install-config.json` holds `rootPartition` and `espPartition`. The macOS
app cannot know these values until the backend partitions the disk. The
backend partitions the disk during the install. Thus: who writes the file,
where, when, and what identifies the partitions?

### The backend cannot send device nodes back to the app

The app runs on macOS, where the new partition has the name `disk0s5`. The
agent runs on Linux, where the same partition is `nvme0n1p5`. **A device node
from macOS has no meaning to the agent.** Thus a device node that the app gets
back is never a usable value. This is not a choice between
two designs that work. This fact removes one of them.

### The two channels that this needs are already upstream

1. **A location for writes after the partition step.** In
   `installer_data.json`, the entry for the EFI partition already sets
   `copy_installer_data: true`.
   - This makes `osinstall.py:169` register `<ESP>/asahi/` as a target.
   - `main.py:596` calls `collect_installer_data()` on those targets
     **after** `osins.install()` makes and mounts the partitions.
   - The backend writes `stub_info.json` and `installer.log` there.
   - After a verified success, the macOS app finds the returned ESP PARTUUID
     with `diskutil`. It then writes `install-config.json` atomically to the
     same location.
2. **A partition identifier that is the same on all OSes.** Each
   `diskutil.py` partition object holds its GPT UUID
   (`uuid=partinfo["DiskUUID"]`, `diskutil.py:134`).
   - asahi-installer *already* sends the ESP UUID through the boot chain:
     `chosen.asahi,efi-system-partition=<uuid>` and
     `chainload=<uuid>;<next_object>` (`osinstall.py:189-192`).
   - It also shows the UUID to the user as "EFI PARTUUID" (`main.py:731`).

   **This stack already uses PARTUUID as its identity value.** It is the same
    on macOS and Linux. A new partition order does not change it.

### Proposed contract

Split the data by *who knows what, and when*:

| Channel | Written by | When | Contents |
|---|---|---|---|
| `<ESP>/asahi/install-config.json` | macOS app via `diskutil` | after a verified JSON `result.success` and a clean backend exit; the app finds the returned ESP PARTUUID and writes the file atomically | **intent only**: `targetImgref`, `user` (with `$6$` hash), `hostname`, `filesystem`, `encryption`, `wifi`, `cosign*`, `sshEnabled` |
| `<ESP>/asahi/stub_info.json` (existing file, more keys) | backend | same hook | **facts that only the backend knows**: the **PARTUUID** of each new partition, with its declared **role** (`esp`/`bootstrap`/`target`) |

**Implemented.** The backend records `partitions[]` after `osins.install()`.
The agent resolves `role -> PARTUUID -> /dev/disk/by-partuuid/<uuid>`. It
then refuses to continue unless it can prove that the target is safe:

- It is not the active root.
- Nothing has mounted it.
- It is on the same parent disk as the ESP.

If a role has zero matches or more than one match, the agent refuses. It does
not try to choose, because an ambiguous identity is not an identity. The
payload template declares the roles. The agent does not guess them from a
display name or a position. `test-payload.sh` makes the roles mandatory. Thus
a payload cannot ship without them and silently send the agent to the dev/test
path.

### Credential lifetime on the ESP (the file must not stay there)

The table above tells *where the file goes*. It must also tell *how long the
file stays*, because the ESP is a bad place for secrets:

- The ESP is **vfat**, which has no permission bits. No file on it can be
  `0o600`. In wootc, `vault.json` is `0o600` and ACL-restricted to
  SYSTEM/Administrators on NTFS.
- The ESP is **not** tmpfs (the agent `RUN_DIR` is tmpfs). The installed
  system mounts it at `/boot/efi` for all time.
- The password goes as a `$6$` hash, which is the purpose of that
  convention. But **nothing can hash the LUKS passphrase or the Wi-Fi PSK**,
  because the system must use them. They are always equal to plaintext.

If the file stays, the disk passphrase is in clear text, and all users can
read it, on the same machine that we encrypted. Thus the contract is:

- **The agent removes `install-config.json` after a successful install.** It
  does this in the same place where it already shreds `recipe.json`.
- The agent *keeps* the file on failure, on purpose. The interactive
  fisherman UI that it falls back to has no other data for a retry.
- `test-agent.sh` asserts both directions.

(On vfat over wear-levelled flash, `shred` is only best-effort and has almost
no effect. The removal is the important part. We record this fact here and do
not pretend otherwise.)

### The app writes no device fields

Thus **the app writes no device fields.** `rootPartition` and
`espPartition` are no longer inputs from the app. The agent resolves them at
runtime from `/dev/disk/by-partuuid/<uuid>`. Remove them from `required` in
the schema. Keep them only as an explicit dev/test override
(`test-agent.sh` uses them this way today).

### Correction to my §1 recommendation

The section above said "Asahi does not need the wootc split", because Asahi
has no pre-mount phase that puts settings on the kernel cmdline. That logic
was correct about the **file** and incorrect about the
**boundary**.

The wootc split is not mainly a method for early mounts. It is a *separation
of knowledge*:

- The host app writes what it knows before it changes the disk.
- The runtime finds what only the runtime can know.

Asahi needs the same boundary for the same reason as wootc, but Asahi can
keep one file on one channel. The recommendation does not change: use a
single JSON file, and converge on field shapes and the `$6$` convention. The
correction is that the device identity fields go on the runtime side of the
line, not in the file from the app.

### The blocking limit: fisherman formats `/`

We read `tuna-os/fisherman` and found a problem that we must solve before we
can make the items above. `disk.ApplyCustomLayout()`
(`internal/disk/custom.go:61`) runs `mkfs` on each custom mount whose fstype
is not `unformatted`/`""`. This includes `/`. The project now has three
beliefs, and they cannot all be true:

- `DESIGN.md`: a ~1.5 GB bootstrap root boots and runs the agent.
- `scripts/make-payload.sh`: the payload declares exactly **two**
  partitions — `EFI` and `Root` (`expand: true`). One Linux partition.
- fisherman: it formats the partition where it installs `/`.

**You cannot run mkfs on the filesystem that you run from.** This is not only
a question of a clean layout — **LUKS makes it necessary**. To encrypt the
root, fisherman must format it again as a LUKS container. It cannot do this
in place. Thus encryption cannot work with the current layout of one
partition, whatever else changes.

Options, for James to choose:

- **A — three partitions.** The ESP, a small bootstrap root of fixed size,
  and the target root (`expand: true`).
  - The agent installs into the target root. The installer then gets the
    bootstrap partition back, or keeps it on purpose as a rescue system.
  - This is the direct wootc equivalent: bootstrap root = Phase 2, target
    root = Phase 3 (native disk).
  - It needs only a change to `make-payload.sh`. The agent finds "the Linux
    partition that I do not run from". A better method: it reads the target
    PARTUUID from the backend, per the table above.
- **B — the bootstrap runs from RAM.** The bootstrap boots as a live root
  from squashfs or initramfs. Then fisherman can format the one Linux
  partition. The disk layout is cleaner and keeps two partitions. But
  it needs a new dracut path for a live root on this side.
- **~~C — `bootc install to-existing-root`~~** (install in place, with no
  new format). Discarded: it does not use the fisherman format step. Thus
  it gives up the premise of one shared installer, which is the purpose of
  RFC §1. It also cannot do LUKS.

A and B are a real trade: one payload script change, or a cleaner disk
layout. All work after step 4 of the test checklist waits on this decision.

**Decided: option A** — see [ADR 0001](adr/0001-bootstrap-partition-layout.md).
The payload now makes three partitions.

The generated recipe is still not *correct*. `build_recipe` writes
`rootPartition` without change, and nothing resolves it to the target that
the installer made (that is #22). But after ADR 0001, the disk has two Linux
partitions. Thus a wrong value now looks *plausible*, and is not clearly
incorrect. Because of this, the agent now refuses the dangerous values:

- A `rootPartition` or `espPartition` that resolves to the device for `/`.
- A `rootPartition` and an `espPartition` that are the same device.

The agent compares `major:minor` from `/proc/self/mountinfo`. Thus it does
not think that `/dev/nvme0n1p5` and `/dev/disk/by-partuuid/...` are different
devices.

The original hazard, as a record: `build_recipe` writes the root mount as
`{ partition: $c.rootPartition, target: "/", fstype: $c.filesystem }`. With
the old payload of two partitions, the only Linux partition *is* the one
that the agent runs from. fisherman would run `mkfs` on it during the
install. That is not a cleanup for later. It is a live hazard.

Thus we do not change the root mount here to a value that only looks correct. The
correct value depends on the layout that we choose.

### Two live bugs that this document found

Both bugs were in the recipe that `bootsahi-agent` makes. The selftest did
not find them. The same PR as this document fixed them:

1. **The ESP mount had `fstype: "vfat"`, which fisherman does not accept.**
   `recipe.Validate()` does not check `customMounts` fstypes
   (`internal/recipe/recipe.go:148-166`). Thus the recipe passes validation,
   and then fails fatally in `formatPartition()`. That switch knows `fat32`,
   not `vfat`. **This recipe was never valid.** It would stop at fisherman
   step 1 on the first real run.
2. **The obvious fix is the dangerous fix.** If you change it to `fat32`,
   `ApplyCustomLayout` runs `mkfs.fat -F32` on the ESP. At that time the ESP
   holds `m1n1/boot.bin`, the bootloader, `stub_info.json`, and `vendorfw/`.
   `vendorfw/` is the Apple firmware that the Mac extracts on the device. It
   is not redistributable, so no source can restore it. That mistake needs a
   DFU restore. The correct value is **`unformatted`**, which skips only the
   `mkfs`. fisherman still does the mount and the `efiPart` records that it
   needs for the boot entry (`custom.go:68-86`).

The selftest now asserts that each `customMounts` fstype is in the set that
`formatPartition` accepts. It also asserts, as a separate check, that the
ESP fstype is a token that skips the format. We verified that both assertions
fail with the old `vfat` value. Know the gap that let this bug through: the
old shape checks used grep to find that a `/boot/efi` mount *existed*. They
never checked what the mount *does*.

### Also confirms the `MountType` problem in RFC §5, with a line number

`custom.go:85` was `runner.Run("mount", s.Partition, hostTarget)`, with no
`-t`. That is the bug from §5 (no explicit type). When we wrote this
section, the bug was live in `tuna-os/fisherman`. The section said that
`projectbluefin/fisherman` had already fixed it, and it recommended a build
from the projectbluefin fork.

We withdraw that recommendation. tuna-os/fisherman#59 synced the forks, the
owners archived `projectbluefin/fisherman`, and this repository builds from
`tuna-os/fisherman` at the pinned `FISHERMAN_REV`. The fork choice never
closed this gap for the manual layout, though: the archived fork's
`custom.go` also mounts with no `-t`. On `tuna-os/fisherman` `dev`, the
`customMounts` path passes an explicit type only for btrfs
(`MountType(..., "btrfs", ...)`). Every other fstype still goes through a
plain `mount`. The aarch64 check in the hardware test checklist still has to
confirm that the Asahi initramfs can probe the root filesystem.

## One correction to issue #6 §5

The RFC puts the clevis/dracut-omit problem under "already fixed for you" in
the shared fisherman. That is not correct. The problem is in the **wootc
deployer script** (the `DRACUT_OMIT` code in `payload/deployer/deploy.sh`).
That is a dracut regen step that wootc does after the install.
`bootsahi-agent` has no equivalent step at this time.

This is not urgent
today, because D1 has no dracut regen step. But add a comment marker if the
Asahi agent gets such a step.
