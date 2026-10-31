# Bootsahi Legacy — Intel Mac macOS-to-Linux design

Bootsahi Legacy is the Intel-Mac companion to the Apple-Silicon path of
Bootsahi. The two paths have different host limits. The Apple-Silicon app
needs macOS 13. But many Intel Macs stay on macOS High Sierra, Mojave, or
Catalina. Thus Legacy supports **macOS 10.13 High Sierra and newer**. It
uses only Bash 3.2 and POSIX tools, because these are available on that
release.

## Status

At this time, the only part that exists is the preflight script
(`legacy/bootsahi-legacy`). The firmware extraction, the USB writer, and the
legacy installer UI are design only.

## Scope

Legacy accepts all Intel Macs on macOS 10.13 or newer. A recognized T2 Mac
gets the dedicated `t2` image profile. All other Intel Macs get the
`generic-intel` profile, which uses the usual TunaOS images for x86_64.

The recognized T2 set is:

- iMac (2020): `iMac20,1`, `iMac20,2`
- iMac Pro (2017): `iMacPro1,1`
- MacBook Air (2018–2020): `MacBookAir8,1`, `MacBookAir8,2`, `MacBookAir9,1`
- MacBook Pro (2018–2020): `MacBookPro15,1` through `MacBookPro16,4`
- Mac mini (2018): `Macmini8,1`
- Mac Pro (2019): `MacPro7,1`

The installer must not apply the T2 kernel profile to a Mac that is not in
this set.

## Migration flow

```
macOS 10.13+ preflight
  -> select the generic-intel or t2 profile and confirm a backup/recovery plan
  -> t2 only: extract Apple Broadcom firmware locally from the installed macOS volume
  -> write an x86_64 TunaOS installer USB (the T2 installer for the t2 profile)
  -> t2 only: boot it after the user enables external boot in Startup Security Utility
  -> bootc install the selected image and verify the post-install hardware contract
```

This flow uses a USB drive, not an APFS resize as on Asahi. To boot from USB,
a T2 Mac needs a change in Startup Security Utility. The user must make this
change. The preflight must not change partitions or security policy.

## Image contract

Generic Intel images keep their usual hardware gate. Each `*-t2` bootc image
must also pass the T2 hardware gate before it shows in the legacy catalog. The
T2 gate does these checks:

1. x86_64 UEFI boot and the T2 kernel and drivers (keyboard, trackpad, SSD,
   audio, camera, fans, Touch Bar);
2. internal wireless uses `brcmfmac` — **never** `broadcom-wl`;
3. the image installs the local firmware files at `/usr/lib/firmware/brcm`
   before NetworkManager starts;
4. NetworkManager uses iwd as its Wi-Fi backend where necessary; and
5. the image can do an unattended `bootc install` to a T2 target disk.

The image recipe sets the versions of the kernel and its packages. The
installed system does not download them. Thus users get an atomic
hardware stack that bootc manages. The project can change package sources and
keep the same macOS application.

## Firmware is an on-device hand-off

The Apple license does not let us give the Broadcom firmware to other
persons. Thus the firmware is not part of a public TunaOS image, release
asset, or registry layer. On macOS, the legacy flow extracts the firmware from
that Mac. It puts a local hand-off for one installation on the installer
media or EFI partition. The T2 bootstrap reads the hand-off one time,
installs it into the target deployment, and then deletes it.

As an alternative, the user can connect to a network with Ethernet or a
phone. Then the bootstrap can extract the firmware from the recovery image.

Some iMac and iMac Pro models can get the firmware only from an installed
macOS. Thus the legacy UI must tell the user to keep the macOS and recovery
partitions. The user can remove them after the T2 image passes its hardware
check.

## Included preflight

`legacy/bootsahi-legacy` is the preflight script. It does not change the
disk. It runs on the Bash 3.2 of macOS 10.13. The `--json` output is the
stable interface for the UI.

In the JSON output, `status` is `supported` for Intel Macs on
macOS 10.13 or newer. For other Macs, its `status` is `unsupported` and
`reason` tells why. The `profile` is `generic-intel` or `t2`. Without
`--json`, the script prints a result for persons to read. It exits with code 1
if the Mac is not supported.
