#!/usr/bin/env bash
# test-payload.sh — thorough static verification of an asahi-installer payload.
#
# Validates the three contracts a payload must honor:
#   1. Zip layout the asahi-installer extracts (esp/ tree + root.img)
#   2. Boot chain artifacts inside the ESP (m1n1/boot.bin structure: m1n1 +
#      >=50 Apple DTBs + gzipped U-Boot; EFI fallback path present)
#   3. The root filesystem is actually an asahi-capable OS (16K asahi kernel,
#      hardware modules, dracut firmware flow, boot payload sources, audio)
#   4. installer_data.json consistency with the zip it describes
#
# Usage: test-payload.sh <payload.zip> <installer_data.json>
# Needs root (loop-mounts root.img read-only).
set -euo pipefail

ZIP="${1:?usage: test-payload.sh <payload.zip> <installer_data.json>}"
DATA="${2:?usage: test-payload.sh <payload.zip> <installer_data.json>}"

pass=0 fail=0
ok() { echo "  ok   $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL $*"; fail=$((fail + 1)); }

WORK=$(mktemp -d)
cleanup() {
	umount "$WORK/root" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. zip layout =="
unzip -q "$ZIP" -d "$WORK/payload"
[ -d "$WORK/payload/esp" ] && ok "esp/ tree present" || bad "esp/ missing"
[ -f "$WORK/payload/root.img" ] && ok "root.img present" || bad "root.img missing"

echo "== 2. ESP boot chain =="
ESP="$WORK/payload/esp"
[ -f "$ESP/m1n1/boot.bin" ] && ok "m1n1/boot.bin" || bad "m1n1/boot.bin missing"
[ -f "$ESP/EFI/BOOT/BOOTAA64.EFI" ] && ok "EFI/BOOT/BOOTAA64.EFI (U-Boot fallback path)" \
	|| bad "EFI/BOOT/BOOTAA64.EFI missing — U-Boot's bootmgr fallback will find nothing"
ls "$ESP"/loader/entries/*.conf >/dev/null 2>&1 && ok "BLS loader entries" \
	|| ls "$ESP"/EFI/*/grub.cfg >/dev/null 2>&1 && ok "grub config" \
	|| bad "no BLS entries and no grub.cfg on ESP"

# boot.bin structure: count devicetree magics (d0 0d fe ed) and check for a
# gzip stream (1f 8b) after them — the update-m1n1 concatenation contract.
python3 - "$ESP/m1n1/boot.bin" <<'EOF'
import sys
data = open(sys.argv[1], "rb").read()
dtbs = data.count(b"\xd0\x0d\xfe\xed")
gz = data.rfind(b"\x1f\x8b")
size_mb = len(data) / 1048576
problems = []
if dtbs < 50:
    problems.append(f"only {dtbs} DTB magics (expect >=50 Apple devicetrees)")
if gz < 0:
    problems.append("no gzip stream (U-Boot) found")
if size_mb < 2:
    problems.append(f"suspiciously small ({size_mb:.1f} MB)")
if problems:
    print("  FAIL boot.bin structure: " + "; ".join(problems)); sys.exit(1)
print(f"  ok   boot.bin structure ({dtbs} DTBs, gzip@+{gz}, {size_mb:.1f} MB)")
EOF
case $? in 0) pass=$((pass + 1)) ;; *) fail=$((fail + 1)) ;; esac

echo "== 3. root filesystem is asahi-capable =="
mkdir -p "$WORK/root"
mount -o ro,loop "$WORK/payload/root.img" "$WORK/root"
R="$WORK/root"
# bootc roots put the OS under a deployment; tolerate both plain and ostree layouts
OSROOT="$R"
if [ ! -d "$R/usr/lib/modules" ]; then
	# Locate the deployment by its content, not its directory naming —
	# stateroot/deployment names vary (default/deploy/<hash>.0, staged
	# deployments, composefs backends).
	moddir=$(find "$R/ostree/deploy" -maxdepth 8 -type d -path "*/usr/lib/modules" 2>/dev/null | head -1)
	[ -n "$moddir" ] && OSROOT="${moddir%/usr/lib/modules}"
fi
if [ -d "$OSROOT/usr/lib/modules" ]; then
	# Select the Asahi kernel by the marker the producer uses: presence of
	# Apple devicetrees (dtb/apple/). A newer-version leftover generic
	# kernel without that marker is not the right choice (issue #28).
	KVER=$(for kd in "$OSROOT/usr/lib/modules"/*; do [ -d "$kd/dtb/apple" ] && basename "$kd"; done | sort -V | tail -1)
	if [ -z "$KVER" ]; then
		bad "no Asahi kernel found (no dtb/apple/ in any /usr/lib/modules/*)"
	else
		ok "Asahi kernel selected: $KVER"
	fi
	M="$OSROOT/usr/lib/modules/$KVER"
	[ -f "$M/vmlinuz" ] && ok "vmlinuz staged" || bad "vmlinuz missing"
	[ -f "$M/initramfs.img" ] && ok "initramfs present" || bad "initramfs missing"
	[ "$(ls "$M/dtb/apple/" 2>/dev/null | wc -l)" -ge 50 ] && ok "Apple DTBs in modules dir" || bad "Apple DTBs missing"
	for mod in asahi.ko appledrm.ko nvme-apple.ko hci_bcm4377.ko spi-hid-apple.ko; do
		grep -qE "/${mod}(\.xz|\.zst|\.gz)?:" "$M/modules.dep" 2>/dev/null &&
			ok "module $mod" || bad "module $mod missing"
	done
	[ -x "$OSROOT/usr/bin/update-m1n1" ] && ok "update-m1n1" || bad "update-m1n1 missing"
	ls -d "$OSROOT"/usr/lib/dracut/modules.d/99asahi-firmware >/dev/null 2>&1 &&
		ok "dracut asahi-firmware module" || bad "dracut asahi-firmware module missing"
	[ -x "$OSROOT/usr/bin/speakersafetyd" ] && ok "speakersafetyd" || bad "speakersafetyd missing (speakers stay disabled)"
else
	bad "no /usr/lib/modules found in root.img (unrecognized layout)"
	echo "  -- layout diagnostics --"
	ls -la "$R" 2>/dev/null || true
	find "$R" -maxdepth 3 2>/dev/null | head -40 || true
	df -h "$R" 2>/dev/null || true
fi

# ── 3b. Bootstrap contract (issue #27) ──────────────────────────────────────
# "The payload boots" and "the bootstrap handoff works" are different claims.
# Only the first was ever tested, because the payload was a stock desktop image
# containing none of this. Uses $OSROOT, not $R: on a bootc/ostree image the
# real rootfs is nested under a deployment path, and checking $R would report
# everything missing.
echo "== 3b. bootsahi bootstrap contract =="
if [ -f "$OSROOT/usr/share/bootsahi/bootstrap-release" ]; then
	ok "bootstrap-release marker present"
	sed 's/^/       /' "$OSROOT/usr/share/bootsahi/bootstrap-release"

	[ -x "$OSROOT/usr/libexec/bootsahi-agent" ] &&
		ok "bootsahi-agent installed and executable" ||
		bad "bootsahi-agent missing or not executable"
	[ -r "$OSROOT/usr/libexec/bootsahi-agent-recipe.sh" ] &&
		ok "recipe adapter installed" ||
		bad "recipe adapter missing — bootsahi-agent cannot start"
	[ -r "$OSROOT/usr/libexec/bootsahi-agent-device.sh" ] &&
		ok "device adapter installed" ||
		bad "device adapter missing — bootsahi-agent cannot start"
	[ -x "$OSROOT/usr/libexec/asahi-bootbin-sync" ] &&
		ok "asahi-bootbin-sync installed" || bad "asahi-bootbin-sync missing"
	[ -f "$OSROOT/usr/lib/systemd/system/bootsahi-agent.service" ] &&
		ok "agent unit shipped" || bad "agent unit missing"

	# Shipped is not enabled. An unenabled unit is a silent no-op on first boot,
	# and #23 was exactly that failure mode by a different mechanism, so assert
	# the wants symlink itself rather than the unit file's presence.
	#
	# The bootstrap enables its units under /usr (#105), which is part of the
	# image and so of every deployment; require the link there. This used to
	# be `ls <etc link> <usr link>`, and ls exits non-zero when ANY of its
	# arguments is missing, so the check failed whenever the /etc link was
	# absent, even with the /usr link present.
	if [ -L "$OSROOT/usr/lib/systemd/system/multi-user.target.wants/bootsahi-agent.service" ]; then
		ok "agent unit ENABLED (wants symlink in /usr/lib/systemd/system)"
	else
		bad "agent unit shipped but NOT enabled — it would never run on first boot"
	fi

	# Pin the #23 fix so it cannot silently regress in a rebuilt image.
	if grep -q '^ConditionKernelVersion=asahi$' \
	   "$OSROOT/usr/lib/systemd/system/bootsahi-agent.service" 2>/dev/null; then
		bad "unit still carries literal ConditionKernelVersion=asahi (never matches — #23)"
	else
		ok "unit does not carry the never-matching kernel condition (#23)"
	fi

	for t in fisherman jq cosign nmcli blkid; do
		if [ -x "$OSROOT/usr/bin/$t" ] || [ -x "$OSROOT/usr/sbin/$t" ]; then
			ok "tool present: $t"
		else
			bad "tool MISSING from the bootstrap: $t (agent fails on first boot)"
		fi
	done
else
	echo "  SKIP no /usr/share/bootsahi/bootstrap-release — this payload is NOT a"
	echo "       bootsahi bootstrap, just a repackaged image. It can boot; it"
	echo "       cannot install. (issue #27; REQUIRE_BOOTSTRAP=1 makes this fatal)"
	if [ "${REQUIRE_BOOTSTRAP:-0}" = "1" ]; then
		bad "REQUIRE_BOOTSTRAP=1 but this payload has no bootstrap marker"
	fi
fi

umount "$WORK/root"

echo "== 4. installer_data.json consistency =="
python3 - "$DATA" "$ZIP" <<'EOF'
import json, os, sys, zipfile
data = json.load(open(sys.argv[1]))
zpath = sys.argv[2]
z = zipfile.ZipFile(zpath)
names = set(z.namelist())
failures = []
oses = data.get("os_list", [])
if not oses:
    failures.append("os_list empty")
for os_entry in oses:
    for key in ("name", "boot_object", "next_object", "package", "partitions"):
        if key not in os_entry:
            failures.append(f"missing key: {key}")
    if os_entry.get("boot_object") != "m1n1.bin":
        failures.append(f"boot_object should be m1n1.bin, got {os_entry.get('boot_object')}")
    if os_entry.get("next_object") != "m1n1/boot.bin":
        failures.append(f"next_object should be m1n1/boot.bin, got {os_entry.get('next_object')}")
    if os.path.basename(os_entry.get("package", "")) != os.path.basename(zpath):
        failures.append("package URL basename does not match the zip filename")
    parts = os_entry.get("partitions", [])
    esp = [p for p in parts if p.get("type") == "EFI"]
    linux = [p for p in parts if p.get("type") == "Linux"]

    if not esp or not esp[0].get("copy_firmware") or esp[0].get("source") != "esp":
        failures.append("EFI partition must have source=esp and copy_firmware=true")
    # install-config.json is delivered through this hook; without it the
    # first-boot agent has nothing to read. See docs/UNIFIED-INSTALL-CONTRACT.md.
    if esp and not esp[0].get("copy_installer_data"):
        failures.append("EFI partition must have copy_installer_data=true "
                        "(the install-config.json delivery channel)")

    # Three-partition contract, per docs/adr/0001-bootstrap-partition-layout.md.
    # Identified by ROLE, not by ordinal: this check previously assumed
    # linux[0] was both the image-bearing and the expanding partition, which is
    # exactly the producer-assumption-echoed-by-verifier problem in issue #27.
    bootstrap = [p for p in linux if p.get("image")]
    target = [p for p in linux if not p.get("image")]

    if len(bootstrap) != 1:
        failures.append(f"expected exactly 1 image-bearing bootstrap partition, got {len(bootstrap)}")
    if len(target) != 1:
        failures.append(f"expected exactly 1 image-less target partition, got {len(target)}")

    if bootstrap:
        b = bootstrap[0]
        if b["image"] not in names:
            failures.append(f"bootstrap image {b['image']} not inside the zip")
        else:
            declared, actual = b.get("size", "0B"), z.getinfo(b["image"]).file_size
            if declared != f"{actual}B":
                failures.append(f"bootstrap size {declared} != actual image size {actual}B")
        # The bootstrap must be fixed-size. If it expanded, it would swallow the
        # space the installed OS needs, and the target would be a sliver.
        if b.get("expand"):
            failures.append("bootstrap partition must NOT be expandable")

    if target:
        t = target[0]
        if not t.get("expand"):
            failures.append("target partition must be expandable (it holds the installed OS)")
        # It must arrive raw: fisherman formats it, and the agent must be able to
        # tell it apart from the partition it is itself running from. A format or
        # image here collapses that distinction — see issue #19.
        if t.get("format"):
            failures.append("target partition must have no 'format' (fisherman formats it)")

    # Roles are how the first-boot agent identifies its target (issue #22): it
    # resolves role -> PARTUUID from stub_info.json rather than trusting a
    # device path or an ordinal. A payload missing them degrades the agent to
    # the config's device paths, which is the dev/test path, not a production
    # one — so require them here rather than discovering it on hardware.
    roles = [p.get("role") for p in parts]
    for required in ("esp", "bootstrap", "target"):
        if roles.count(required) != 1:
            failures.append(f"expected exactly 1 partition with role={required!r}, "
                            f"got {roles.count(required)}")
    if bootstrap and bootstrap[0].get("role") != "bootstrap":
        failures.append("the image-bearing partition must have role=bootstrap")
    if target and target[0].get("role") != "target":
        failures.append("the expanding image-less partition must have role=target")
    if esp and esp[0].get("role") != "esp":
        failures.append("the EFI partition must have role=esp")

    # Belt-and-braces on the whole point of the layout: the partition carrying
    # the bootstrap image can never also be the one that expands, because the
    # bootstrap cannot mkfs the filesystem it is running from.
    for p in linux:
        if p.get("image") and p.get("expand"):
            failures.append(f"partition {p.get('name')!r} both carries an image and expands — "
                            "that is the single-partition layout issue #19 rejects")
if failures:
    for f in failures:
        print(f"  FAIL installer_data: {f}")
    sys.exit(1)
print(f"  ok   installer_data.json consistent with {os.path.basename(zpath)}")
EOF
case $? in 0) pass=$((pass + 1)) ;; *) fail=$((fail + 1)) ;; esac

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
