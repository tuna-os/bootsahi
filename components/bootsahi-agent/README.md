# bootsahi-agent

D1's first-boot agent for the "bootsahi" bootstrap image (see
[`docs/DESIGN.md`](../../docs/DESIGN.md)): translates `install-config.json`
(written by the Bootsahi macOS app onto the ESP) into a
[fisherman](https://github.com/projectbluefin/fisherman) `recipe.json` and
drives an unattended `bootc install to-filesystem`.

**Fork choice matters here.** wootc (the Windows sibling of this project,
see [issue #6](https://github.com/tuna-os/bootc-installer-asahi/issues/6))
vendored `projectbluefin/fisherman`, which had real fixes `tuna-os/fisherman`
lacks as of 2026-07-18 (six days stale at time of writing): an explicit
`mount -t` for the freshly-formatted root (the deployer initramfs can't
probe the filesystem type, so an xfs root gets attempted as ext4 and fails),
and the useradd handling (which is NOT simply "chroot instead of --root" —
that was reversed for composefs-native; see docs/UNIFIED-INSTALL-CONTRACT.md)
(`--root` also
initializes the *host's* PAM/SELinux stack and fails against an otherwise
perfectly writable target). Point `BOOTSAHI_FISHERMAN_BIN` at a binary
built from `tuna-os/fisherman` (now synced — see tuna-os/fisherman#59).

**Not** `bootc install to-disk` — that path (used by this repo's own
`scripts/make-payload.sh` / `scripts/test-payload.sh`) is debug/QEMU-only,
where fisherman partitions a scratch disk itself. In the real flow the
asahi-installer backend has already partitioned the disk on the macOS side
(stub macOS, ESP, root partition), so this agent hands fisherman those
pre-made partitions via `recipe.json`'s `customMounts`, never its
disk-auto-partition path.

## Contract

- Locates `install-config.json` at `<ESP>/bootsahi/install-config.json`
  (candidates: `/boot/efi`, `/efi`, `/boot` — same ESP-detection convention
  as [`asahi-bootbin-sync`](../asahi-bootbin-sync)). Override with
  `BOOTSAHI_CONFIG_PATH` for testing.
- Schema: [`install-config.schema.json`](install-config.schema.json).
- Optional Wi-Fi connect (`nmcli`) if `wifi.ssid` is present; non-fatal on
  failure (ethernet may still work).
- Optional cosign signature verification when `cosignIdentity` is set —
  refuses to deploy an unverified image if `cosign` isn't installed in the
  bootstrap. `BOOTSAHI_SKIP_VERIFY=1` is a dev/test-only escape hatch, never
  for production bootstrap images.
- Builds a fisherman recipe with `customMounts` (ESP + root, both
  pre-partitioned), `bootloader: "systemd"` (per fisherman's own docs, this
  is the setting for Bluefin/Dakota-style systemd-boot images — which is
  every TunaOS/Dakota/Bluefin Asahi target), and `imageType: "bootc"`.
- Shreds the generated recipe.json after a successful install (it carries the
  LUKS passphrase / user password in the clear); `BOOTSAHI_RUN_DIR` is
  tmpfs-backed in production, so this is belt-and-braces.
- Reboots into the installed system on success unless `BOOTSAHI_NO_REBOOT=1`.

### Exit codes (load-bearing — the bootstrap's greetd session branches on these)

| Code | Meaning | greetd fallback |
|------|---------|------------------|
| `0`  | Installed successfully | none — the agent already rebooted |
| `2`  | No `install-config.json` yet (expected first-boot state) | show the interactive fisherman-driven UI (`tuna-installer-*`; contract documented as [`docs/INSTALLER-FRONTENDS.md`](https://github.com/tuna-os/tunaOS/blob/main/docs/INSTALLER-FRONTENDS.md) in tuna-os/tunaOS) |
| `1`  | Config present but the install failed | show the interactive UI, with `/run/bootsahi/install.log` surfaced for diagnosis |

## Ship it in every bootsahi bootstrap image

- main orchestrator → `/usr/libexec/bootsahi-agent`
- policy library → `/usr/libexec/bootsahi-agent-policy.sh`
- recipe adapter library → `/usr/libexec/bootsahi-agent-recipe.sh`
- device resolution library → `/usr/libexec/bootsahi-agent-device.sh`
- unit → `/usr/lib/systemd/system/bootsahi-agent.service` (+ preset enable,
  `WantedBy=multi-user.target`)

Requires `jq` and (for install) the `fisherman` binary reachable on `$PATH`.
`nmcli` and `cosign` are optional — their absence only disables the
corresponding feature (Wi-Fi connect, signature verification) rather than
failing the whole agent, except that a `cosignIdentity` in the config with no
`cosign` binary is treated as a hard failure (refuse to deploy unverified).

## Testing

`./test-agent.sh` exercises the full exit-code contract and the recipe.json
shape using `/bin/true` / `/bin/false` / `cat` as fisherman stand-ins — no
real disks, network, or fisherman/bootc binary required. Run on every change:

```sh
./test-agent.sh
```
